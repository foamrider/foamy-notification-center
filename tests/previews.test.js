const assert = require("node:assert/strict");
const { spawn, spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");
const helper = require("./helper.cjs")

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "notification-previews-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const source = path.join(root, "source");
  const store = path.join(root, "store");
  fs.mkdirSync(path.join(source, "history"), { recursive: true });
  const env = { ...process.env, NC_SRC_DIR: source, NC_SRC_HISTORY: path.join(source, "history"),
    NC_STORE: store, NC_PREVIEWS: "1" };
  let id = 0;
  return {
    root, source, store, env,
    image(name, ...args) {
      const file = path.join(root, name);
      const result = spawnSync("magick", [...args, file], { encoding: "utf8", timeout: 5000 });
      assert.equal(result.status, 0, result.stderr);
      return file;
    },
    send(file = "", fields = {}) {
      const timestamp = Date.now();
      const key = `${timestamp}-${++id}`;
      fs.writeFileSync(path.join(source, `${key}.json`), JSON.stringify({
        app: "Preview test", summary: key, timestamp, execArgv: file ? ["viewer", file] : [], ...fields,
      }));
      return key;
    },
    run(command = "sync") {
      const result = helper.spawnSync([command], { env, encoding: "utf8", timeout: 12000 });
      assert.equal(result.status, 0, result.stderr || String(result.error));
      return result;
    },
    entries() {
      return fs.readFileSync(path.join(store, "archive.jsonl"), "utf8").trim().split("\n").filter(Boolean).map(JSON.parse);
    },
    mockMagick(body) {
      const bin = path.join(root, "bin");
      fs.mkdirSync(bin);
      fs.writeFileSync(path.join(bin, "magick"), `#!/bin/bash\n${body}\n`, { mode: 0o700 });
      env.PATH = `${bin}:${process.env.PATH}`;
    },
  };
}

test("real raster previews become bounded PNGs, including paths with spaces", t => {
  const f = fixture(t);
  for (const extension of ["png", "jpg", "gif", "webp"])
    f.send(f.image(`sample image.${extension}`, "-size", "1440x900", "xc:steelblue"));
  f.run();
  assert.equal(f.entries().length, 4);
  for (const entry of f.entries()) {
    assert.ok(entry.preview.startsWith("file://"));
    const result = spawnSync("magick", ["identify", "-format", "%m %wx%h %n", entry.preview.slice(7)], { encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, "PNG 720x450 1");
  }
});

test("unsupported, corrupt, oversized-dimension and over-5-MiB images leave text intact", t => {
  const f = fixture(t);
  const svg = path.join(f.root, "disguised.png");
  fs.writeFileSync(svg, '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"/>');
  const corrupt = f.image("corrupt.png", "-size", "1x1", "xc:red");
  fs.truncateSync(corrupt, 40);
  const large = f.image("wide.png", "-size", "9000x1", "xc:red");
  const bigFile = f.image("big.png", "-size", "1x1", "xc:red");
  fs.truncateSync(bigFile, 5242881);
  for (const file of [svg, corrupt, large, bigFile]) f.send(file);
  const next = f.send();
  const result = f.run();
  assert.match(result.stderr, /preview_rejected/);
  assert.equal(f.entries().length, 5);
  assert.ok(f.entries().every(row => row.preview === ""));
  assert.ok(f.entries().some(row => row.key === next));
  assert.deepEqual(fs.readdirSync(path.join(f.store, "images")), []);
});

test("a failed converter cannot leave the original or a partial preview", t => {
  const f = fixture(t);
  const image = f.image("valid.png", "-size", "1x1", "xc:red");
  f.mockMagick('output=${!#}; printf partial > "${output#PNG:}"; exit 1');
  f.send(image);
  assert.match(f.run().stderr, /preview_rejected/);
  assert.equal(f.entries()[0].preview, "");
  assert.deepEqual(fs.readdirSync(path.join(f.store, "images")), []);
});

test("missing preview tools preserve notification text without a raw fallback", t => {
  const f = fixture(t);
  const image = f.image("valid.png", "-size", "1x1", "xc:red");
  const bin = path.join(f.root, "tools");
  fs.mkdirSync(bin);
  // Keep the backend's base tools, but deliberately omit optional decoders.
  for (const tool of ["bash", "dirname", "jq", "flock", "mkdir", "chmod", "timeout", "head", "stat",
    "file", "rm", "mv", "date", "grep", "tail", "sort", "comm", "cat", "basename", "sha256sum"])
    fs.symlinkSync(`/usr/bin/${tool}`, path.join(bin, tool));
  f.env.PATH = bin;
  f.send(image);
  assert.match(f.run().stderr, /preview_rejected/);
  fs.unlinkSync(path.join(bin, "file"));
  f.send(image);
  assert.match(f.run().stderr, /preview_rejected/);
  assert.equal(f.entries().length, 2);
  assert.ok(f.entries().every(entry => entry.preview === ""));
  assert.deepEqual(fs.readdirSync(path.join(f.store, "images")), []);
});

test("a stuck converter is forcibly stopped and releases the archive lock", t => {
  const f = fixture(t);
  const image = f.image("valid.png", "-size", "1x1", "xc:red");
  // Ignore TERM to exercise the hard-kill deadline, including child processes.
  f.mockMagick('output=${!#}; printf partial > "${output#PNG:}"; trap "" TERM; sleep 30');
  f.send(image);
  const next = f.send();
  const start = Date.now();
  assert.match(f.run().stderr, /preview_rejected/);
  assert.ok(Date.now() - start < 10000, "conversion exceeded its deadline");
  assert.equal(f.entries().length, 2);
  assert.equal(f.entries()[0].preview, "");
  assert.ok(f.entries().some(row => row.key === next));
  assert.deepEqual(fs.readdirSync(path.join(f.store, "images")), []);
  f.run("seen");
});

test("the real watcher continues after rejecting an image", async t => {
  const f = fixture(t);
  const wide = f.image("wide.png", "-size", "9000x1", "xc:red");
  const initial = f.send();
  const child = helper.spawn(["watch"], { env: f.env, detached: true, stdio: ["ignore", "pipe", "pipe"] });
  t.after(() => {
    try { process.kill(-child.pid, "SIGKILL"); } catch (error) { if (error.code !== "ESRCH") throw error; }
  });
  let output = "";
  let errors = "";
  child.stdout.on("data", chunk => { output += chunk; });
  child.stderr.on("data", chunk => { errors += chunk; });
  async function waitFor(check) {
    const deadline = Date.now() + 5000;
    while (!check() && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 25));
    assert.ok(check(), `watcher did not advance: ${errors}`);
  }
  await waitFor(() => output.includes(initial));
  // Confirm registered watches before writing, without relying on a sleep.
  await waitFor(() => {
    const children = fs.readFileSync(`/proc/${child.pid}/task/${child.pid}/children`, "utf8").trim().split(/\s+/).filter(Boolean);
    return children.some(pid => {
      try {
        return fs.readdirSync(`/proc/${pid}/fd`).some(fd => {
          try { return /^inotify wd:/m.test(fs.readFileSync(`/proc/${pid}/fdinfo/${fd}`, "utf8")); } catch { return false; }
        });
      } catch { return false; }
    });
  });
  const rejected = f.send(wide, {appIcon:wide, image:wide});
  const next = f.send();
  await waitFor(() => output.includes(next));
  const row = f.entries().find(entry => entry.key === rejected);
  assert.equal(row.preview, "");
  assert.equal(row.appIcon, "");
  assert.equal(row.image, "");
  assert.match(errors, /preview_rejected/);
  assert.equal(child.exitCode, null);
});

function inspect(file, format = '%m %wx%h %n') {
  const result = spawnSync('magick', ['identify', '-format', format, file.replace(/^file:\/\//, '')], {encoding:'utf8', timeout:5000});
  assert.equal(result.status, 0, result.stderr);
  return result.stdout;
}

function progressiveBomb(f) {
  const file = f.image('progressive.jpg', '-size', '32x32', 'xc:blue', '-interlace', 'Plane');
  const data = fs.readFileSync(file);
  const frame = data.indexOf(Buffer.from([0xff, 0xc2]));
  assert.ok(frame > 0, 'fixture must be a progressive JPEG');
  // Large declared dimensions with tiny scan data exercise coefficient allocation.
  data.writeUInt16BE(60000, frame + 5);
  data.writeUInt16BE(60000, frame + 7);
  fs.writeFileSync(file, data);
  return file;
}

test('all file-backed image slots are normalized, including valid progressive JPEG icons', t => {
  const f = fixture(t);
  for (const extension of ['png', 'jpg', 'gif', 'webp', 'bmp', 'ico']) {
    const size = extension === 'ico' ? '64x32' : '1440x900';
    const file = f.image(`icon.${extension}`, '-size', size, 'xc:steelblue', ...(extension === 'jpg' ? ['-interlace', 'Plane'] : []));
    f.send('', {appIcon:file, image:file});
  }
  f.send('', {appIcon:'org.gnome.Nautilus'});
  f.run();
  for (const row of f.entries().filter(row => row.appIcon.startsWith('file://'))) {
    for (const slot of ['appIcon', 'image']) {
      assert.match(row[slot], /\.png$/);
      assert.match(inspect(row[slot]), /^PNG (720x450|64x32) 1$/);
    }
  }
  assert.equal(f.entries().filter(row => row.appIcon.startsWith('file://')).length, 6);
  assert.equal(f.entries().at(-1).appIcon, 'org.gnome.Nautilus');
});

test('transparent icons and self-contained SVG icons keep their pixels', t => {
  const f = fixture(t);
  const png = f.image('alpha.png', '-size', '32x32', 'xc:none', '-fill', '#00ff0080', '-draw', 'rectangle 0,0 15,15');
  const svg = path.join(f.root, 'icon.svg');
  fs.writeFileSync(svg, '<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32"><rect width="16" height="16" fill="#00ff00" fill-opacity="0.5"/></svg>');
  f.send('', {appIcon:png});f.send('', {appIcon:svg});f.run();
  for (const row of f.entries()) {
    assert.equal(inspect(row.appIcon), 'PNG 32x32 1');
    assert.equal(inspect(row.appIcon, '%[fx:p{31,31}.a]'), '0');
    assert.ok(Math.abs(Number(inspect(row.appIcon, '%[fx:p{0,0}.a]')) - 0.5) < 0.01);
  }
});

test('SVG icons cannot include neighbouring or absolute external files', t => {
  const f = fixture(t);
  const secret = f.image('private.png', '-size', '32x32', 'xc:red');
  for (const href of ['private.png', `file://${secret}`, secret]) {
    const svg = path.join(f.root, 'linked.svg');
    fs.writeFileSync(svg, `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="32" height="32"><rect width="32" height="32" fill="blue"/><image xlink:href="${href}" width="32" height="32"/></svg>`);
    f.send('', {appIcon:svg});f.run();
    const icon = f.entries().at(-1).appIcon;
    assert.ok(icon, 'normal SVG content should still render');
    assert.equal(inspect(icon, '%[fx:p{0,0}.r] %[fx:p{0,0}.b]'), '0 1');
  }
});

test('progressive JPEG bombs and corrupt icons are rejected without losing notification text', t => {
  const f = fixture(t);
  const bomb = progressiveBomb(f);
  const corrupt = f.image('bad.png', '-size', '1x1', 'xc:red');fs.truncateSync(corrupt, 40);
  for (const file of [bomb, corrupt]) f.send('', {appIcon:file, image:file});
  f.send('', {appIcon:'safe-theme-icon'});
  const start = Date.now(), result = f.run();
  assert.ok(Date.now() - start < 10000);
  assert.match(result.stderr, /appIcon_rejected/);
  assert.match(result.stderr, /image_rejected/);
  assert.equal(f.entries().length, 3);
  for (const row of f.entries().slice(0,2)) {assert.equal(row.appIcon,'');assert.equal(row.image,'');assert.ok(row.summary);}
  assert.deepEqual(fs.readdirSync(path.join(f.store,'images')), []);
});

test('first list migrates retained legacy images before exposing them, without their sources', t => {
  const f = fixture(t);
  f.run('list');
  const timestamp = Date.now(), key = `${timestamp}-41`;
  const original = f.image('old-icon.jpg', '-size', '1200x900', 'xc:green', '-interlace', 'Plane');
  const legacy = path.join(f.store, 'images', `${key}-appIcon`);
  fs.copyFileSync(original, legacy);fs.unlinkSync(original);
  const row = {key,timestamp,app:'Old app',summary:'Retained notification',appIcon:`file://${legacy}`,image:`file://${legacy}`,preview:'',file:'/tmp/original-picture.jpg',sourceHash:'old',assetsHash:'old'};
  fs.writeFileSync(path.join(f.store, 'archive.jsonl'), JSON.stringify(row)+'\n');
  const result = JSON.parse(f.run('list').stdout)[0];
  assert.equal(result.summary, row.summary);assert.equal(result.file,row.file);
  for (const slot of ['appIcon','image']) assert.equal(inspect(result[slot]),'PNG 720x540 1');
  assert.equal(result.imageFormat,1);assert.equal(fs.existsSync(legacy),false);
  const before=fs.statSync(result.appIcon.slice(7),{bigint:true}).mtimeNs;
  f.run('list');f.run();assert.equal(fs.statSync(result.appIcon.slice(7),{bigint:true}).mtimeNs,before);
});

test('legacy rejected images and provider URLs never escape through list', t => {
  const f = fixture(t);f.run('list');
  const bomb=progressiveBomb(f),timestamp=Date.now();
  const rows=[{key:`${timestamp}-1`,timestamp,summary:'Bomb',appIcon:`file://${bomb}`},
    {key:`${timestamp}-2`,timestamp,summary:'Provider',appIcon:'image://icon//tmp/raw.jpg',image:'image://pixmap/1'}];
  fs.writeFileSync(path.join(f.store,'archive.jsonl'),rows.map(JSON.stringify).join('\n')+'\n');
  const result=JSON.parse(f.run('list').stdout);
  assert.equal(result.length,2);
  assert.ok(result.every(row=>row.appIcon==='' && row.image===''));
  assert.ok(fs.existsSync(bomb), 'migration must not delete sender files');
});

test('decoder memory allocations outside its pixel cache remain bounded for app icons', t => {
  const f=fixture(t), image=f.image('valid.png','-size','1x1','xc:red');
  // A worker allocation bypasses ImageMagick settings but must hit RLIMIT_AS.
  f.mockMagick("exec /usr/bin/python3 -c 'x = bytearray(600 * 1024 * 1024)' ");
  f.send('',{appIcon:image});
  const result=f.run();
  assert.match(result.stderr,/appIcon_rejected/);
  assert.equal(f.entries()[0].appIcon,'');
  assert.deepEqual(fs.readdirSync(path.join(f.store,'images')),[]);
});

test('concurrent first loads migrate once and retain valid images after source cleanup', async t => {
  const f=fixture(t);f.run('list');
  const timestamp=Date.now(),key=`${timestamp}-44`;
  const image=f.image('legacy.jpg','-size','128x64','xc:red','-interlace','Plane');
  fs.writeFileSync(path.join(f.store,'archive.jsonl'),JSON.stringify({key,timestamp,summary:'Keep',appIcon:image})+'\n');
  function list() {
    return new Promise((resolve,reject)=>{
      const child=helper.spawn(['list'],{env:f.env});let output='',errors='';
      child.stdout.on('data',data=>output+=data);child.stderr.on('data',data=>errors+=data);
      child.on('error',reject);child.on('exit',code=>{if(code!==0)reject(new Error(errors));else resolve(JSON.parse(output));});
    });
  }
  const [a,b]=await Promise.all([list(),list()]);assert.deepEqual(a,b);
  assert.equal(inspect(a[0].appIcon),'PNG 128x64 1');
  assert.equal(f.entries().length,1);
});

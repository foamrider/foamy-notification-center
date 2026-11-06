//! Retained copies of sender images, normalized to one PNG before the shell
//! ever decodes them (compressed byte limits alone do not bound a decoder).
//!
//! A copy is at most 5 MiB read from the sender file (5 s), its type comes
//! from `file -bL --mime-type` (2 s), and ImageMagick converts it under the
//! plugin's `bin/policy.xml` (`MAGICK_CONFIGURE_PATH`) with no core dumps,
//! 512 MiB of address space, 10 MiB files, a 5 s deadline and a kill of its
//! whole process group. SVG is rendered by librsvg from standard input in an
//! empty working directory, so it cannot reach neighbouring files.

use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::Path;
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use foamy_helper::child::Bounded;
use foamy_helper::process::Resource;
use rustix::fs::{FileType, OFlags};

use crate::text;

/// Largest sender file and largest converted PNG.
pub const MAX_IMAGE_BYTES: u64 = 5 * 1024 * 1024;
const READ_DEADLINE: Duration = Duration::from_secs(5);
const MIME_DEADLINE: Duration = Duration::from_secs(2);
const CONVERT_DEADLINE: Duration = Duration::from_secs(5);
/// `ulimit -v 524288` (KiB) and `ulimit -f 10240` (KiB).
const ADDRESS_SPACE: u64 = 524_288 * 1024;
const FILE_SIZE: u64 = 10_240 * 1024;

pub struct Images<'a> {
    /// `$store/images`.
    pub dir: &'a str,
    /// The plugin's `bin/`, which holds `policy.xml`.
    pub policy_dir: &'a str,
}

/// `[[ -f path ]]`: a regular file, following symlinks.
fn regular(path: &str) -> bool {
    fs::metadata(path).is_ok_and(|m| m.is_file())
}

/// Reads at most `limit` bytes of a regular file (symlinks followed, as
/// `head` did; FIFOs and devices refused instead of blocking), within the
/// deadline. A read that does not finish in time is abandoned.
fn read_sender(path: &str, limit: u64) -> Option<Vec<u8>> {
    let (send, receive) = mpsc::channel();
    let path = path.to_string();
    thread::spawn(move || {
        let read = || -> std::io::Result<Vec<u8>> {
            let file = OpenOptions::new()
                .read(true)
                .custom_flags((OFlags::NONBLOCK | OFlags::NOCTTY).bits() as i32)
                .open(&path)?;
            let stat = rustix::fs::fstat(&file)?;
            if FileType::from_raw_mode(stat.st_mode) != FileType::RegularFile {
                return Err(std::io::ErrorKind::InvalidInput.into());
            }
            let mut data = Vec::new();
            file.take(limit).read_to_end(&mut data)?;
            Ok(data)
        };
        let _ = send.send(read());
    });
    receive.recv_timeout(READ_DEADLINE).ok()?.ok()
}

fn write_private(path: &str, data: &[u8]) -> std::io::Result<()> {
    let mut file = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .custom_flags(OFlags::NOFOLLOW.bits() as i32)
        .open(path)?;
    file.write_all(data)
}

fn size(path: &str) -> Option<u64> {
    fs::metadata(path).ok().map(|m| m.len())
}

/// An empty private directory for librsvg (`mktemp -d`).
fn scratch_dir() -> Option<String> {
    let base = std::env::temp_dir();
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.subsec_nanos());
    for attempt in 0..32u32 {
        let name = format!("tmp.nc{}-{:08x}{attempt}", std::process::id(), nanos);
        let path = base.join(name);
        if fs::DirBuilder::new().mode(0o700).create(&path).is_ok() {
            return Some(path.to_string_lossy().into_owned());
        }
    }
    None
}

fn which(program: &str) -> bool {
    std::env::var_os("PATH").is_some_and(|paths| {
        std::env::split_paths(&paths).any(|dir| {
            let candidate = dir.join(program);
            fs::metadata(&candidate).is_ok_and(|m| {
                m.is_file()
                    && std::os::unix::fs::PermissionsExt::mode(&m.permissions()) & 0o111 != 0
            })
        })
    })
}

impl Images<'_> {
    /// `resize_preview`: converts `source` (a private copy) into the PNG `dest`.
    fn convert(&self, coder: &str, source: &str, dest: &str) -> bool {
        if !which("magick") {
            return false;
        }
        let policy = Path::new(self.policy_dir).join("policy.xml");
        if File::open(&policy).is_err() {
            return false;
        }
        let output = format!("PNG:{dest}");
        let command = Bounded::new("magick")
            .env("MAGICK_CONFIGURE_PATH", self.policy_dir)
            .timeout(CONVERT_DEADLINE)
            .rlimit(Resource::Core, 0)
            .rlimit(Resource::As, ADDRESS_SPACE)
            .rlimit(Resource::Fsize, FILE_SIZE);
        let ran = if coder == "RSVG" {
            let Some(scratch) = scratch_dir() else {
                return false;
            };
            let ran = match fs::read(source) {
                Ok(svg) => command
                    .current_dir(&scratch)
                    .stdin(svg)
                    .args([
                        "-background",
                        "none",
                        "RSVG:-[0]",
                        "-auto-orient",
                        "-resize",
                        "720x720>",
                        "-strip",
                        &output,
                    ])
                    .run(),
                Err(error) => Err(error),
            };
            let _ = fs::remove_dir(&scratch);
            ran
        } else {
            command
                .args([
                    &format!("{coder}:{source}[0]"),
                    "-auto-orient",
                    "-resize",
                    "720x720>",
                    "-strip",
                    &output,
                ])
                .run()
        };
        ran.is_ok_and(|out| out.success())
            && size(dest).is_some_and(|n| n > 0 && n <= MAX_IMAGE_BYTES)
    }

    /// `copy_image`: a normalized private copy of a sender file, as a
    /// `file://` URL, or "" (with a note on standard error when the file
    /// exists but cannot be used).
    pub fn copy(&self, source: &str, key: &str, slot: &str) -> String {
        let source = text::strip_file_url(source);
        if !regular(source) {
            return String::new();
        }
        let dest = format!("{}/{key}-{slot}.png", self.dir);
        let temp = format!("{dest}.tmp");
        let resized = format!("{dest}.resized");
        let copied = read_sender(source, MAX_IMAGE_BYTES + 1)
            .filter(|data| data.len() as u64 <= MAX_IMAGE_BYTES)
            .is_some_and(|data| write_private(&temp, &data).is_ok());
        if copied {
            let mime = Bounded::new("file")
                .args(["-bL", "--mime-type", "--", &temp])
                .timeout(MIME_DEADLINE)
                .run()
                .ok()
                .filter(|out| out.success())
                .map(|out| text::cmdsub(&out.stdout_lossy()))
                .unwrap_or_default();
            let coder = match mime.as_str() {
                "image/png" => "PNG",
                "image/jpeg" => "JPEG",
                "image/gif" => "GIF",
                "image/webp" => "WEBP",
                "image/bmp" | "image/x-ms-bmp" => "BMP",
                "image/vnd.microsoft.icon" | "image/x-icon" => "ICO",
                "image/svg+xml" if slot != "preview" => "RSVG",
                _ => "",
            };
            if !coder.is_empty()
                && self.convert(coder, &temp, &resized)
                && fs::rename(&resized, &dest).is_ok()
            {
                let _ = fs::remove_file(&temp);
                return format!("file://{dest}");
            }
        }
        eprintln!(
            "notification-center: {slot}_rejected: unsupported image, decoder unavailable, or conversion limit reached; keeping notification text"
        );
        let _ = fs::remove_file(&temp);
        let _ = fs::remove_file(&resized);
        String::new()
    }

    /// `archive_image`: sender files are normalized; only plain theme names
    /// pass through, and only for the app icon.
    pub fn archive(&self, source: &str, key: &str, slot: &str) -> String {
        if text::is_path(source) {
            self.copy(source, key, slot)
        } else if slot == "appIcon" && text::theme_name(source) {
            source.to_string()
        } else {
            String::new()
        }
    }
}

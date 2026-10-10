"""Read and update only the Foamy Notifications controls exposed by the center."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
import tempfile

FIELDS = {"groupDuplicates": True, "useBrowserFavicons": True, "compact": True,
          "showImages": True, "normalTimeoutSec": 8}


def valid(key, value):
    if key not in FIELDS:
        return False
    if key == "normalTimeoutSec":
        return type(value) is int and 1 <= value <= 120
    return type(value) is bool


def read_config(path):
    # Resolve the Stow link and replace its source, never the link in ~/.config.
    target = path.resolve(strict=True)
    before = target.stat()
    if not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid() or before.st_size > 1024 * 1024:
        raise ValueError("Unsupported notification configuration file")
    config = json.loads(target.read_text())
    if not isinstance(config, dict) or not isinstance(config.get("plugins", []), list):
        raise ValueError("Invalid notification configuration")
    # Omarchy accepts configs that omit plugins when no services are enabled.
    entries = [entry for entry in config.get("plugins", []) if isinstance(entry, dict) and entry.get("id") == "foamy.notifications"]
    if len(entries) > 1:
        raise ValueError("Duplicate Foamy Notifications entries")
    return target, before, config, entries[0] if entries else None


def settings(config, entry):
    if entry is None or "foamy.notifications" in config.get("disabledPlugins", []):
        return {"available": False, "settings": {}}
    values = {}
    for key, default in FIELDS.items():
        value = entry.get(key, default)
        if not valid(key, value):
            raise ValueError("Invalid notification setting: " + key)
        values[key] = value
    # The legacy browser override can disable grouping independently of duplicates.
    if entry.get("browserGrouping") == "none":
        values["groupDuplicates"] = False
    return {"available": True, "settings": values}


def signature(info):
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns


def save(path, key, value):
    if not valid(key, value):
        raise ValueError("Invalid notification setting")
    target, _, _, _ = read_config(path)
    # Serialize our edits across monitors and re-read after obtaining the lock.
    flags = os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK
    lock_dir = Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache"))) / "foamy/notification-settings"
    lock_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock_name = hashlib.sha256(os.fsencode(target)).hexdigest() + ".lock"
    fd = os.open(lock_dir / lock_name, flags, 0o600)
    with os.fdopen(fd, "r+") as lock:
        info = os.fstat(lock.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            raise ValueError("Unsafe notification settings lock")
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        current_target, before, config, entry = read_config(path)
        if current_target != target:
            raise ValueError("Notification configuration moved; try again")
        if not settings(config, entry)["available"]:
            raise ValueError("Foamy Notifications is not enabled")
        entry[key] = value
        if key == "groupDuplicates" and value and entry.get("browserGrouping") == "none":
            entry["browserGrouping"] = "browser"
        payload = json.dumps(config, ensure_ascii=False, indent=2) + "\n"
        temporary = None
        try:
            fd, temporary = tempfile.mkstemp(prefix=".foamy-notifications-", dir=target.parent)
            with os.fdopen(fd, "w") as output:
                os.fchmod(output.fileno(), stat.S_IMODE(before.st_mode))
                output.write(payload)
                output.flush()
                os.fsync(output.fileno())
            # Refuse to overwrite a concurrent editor or an Omarchy widget write.
            if path.resolve(strict=True) != target or signature(target.stat()) != signature(before):
                raise ValueError("Notification configuration changed; try again")
            os.replace(temporary, target)
            temporary = None
        finally:
            if temporary is not None:
                os.unlink(temporary)
        return settings(config, entry)


def main():
    path = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "omarchy/shell.json"
    try:
        if len(sys.argv) == 2 and sys.argv[1] == "read":
            _, _, config, entry = read_config(path)
            result = settings(config, entry)
        elif len(sys.argv) == 4 and sys.argv[1] == "save":
            result = save(path, sys.argv[2], json.loads(sys.argv[3]))
        else:
            raise ValueError("Invalid notification settings command")
        print(json.dumps({"ok": True, **result}))
    except (OSError, ValueError, TypeError) as error:
        print(json.dumps({"ok": False, "error": str(error)}))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

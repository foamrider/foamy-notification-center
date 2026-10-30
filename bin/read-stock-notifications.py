#!/usr/bin/env python3
"""Read Omarchy 4.5 arrays and emit only changed rows for the existing archive."""
import hashlib
import json
import os
from pathlib import Path
import re
import sys

LIMIT = 8 * 1024 * 1024
ROW_LIMIT = 128 * 1024
KEY = re.compile(r"[A-Za-z0-9_-]{1,120}\Z")


def changed_rows(source, archive):
    with source.open('rb') as stream:
        raw = stream.read(LIMIT + 1)
    if not raw.strip():
        return []
    if len(raw) > LIMIT:
        raise ValueError('stock notification file exceeds 8 MiB')
    rows = json.loads(raw)
    if not isinstance(rows, list) or len(rows) > 100:
        raise ValueError('invalid stock notification array')
    wanted = {"stock-" + row["key"] for row in rows if isinstance(row, dict) and isinstance(row.get("key"), str) and KEY.fullmatch(row["key"])}
    previous = {}
    # Stream the archive once per batch. A full array is rewritten on every
    # arrival; spawning image workers for each unchanged row would fall behind.
    if archive.exists():
        with archive.open('rb') as stream:
            while line := stream.readline(ROW_LIMIT + 1):
                if len(line) > ROW_LIMIT:
                    while line and not line.endswith(b'\n'):
                        line = stream.readline(ROW_LIMIT + 1)
                    continue
                try:
                    old = json.loads(line)
                    if isinstance(old, dict) and old.get('key') in wanted:
                        previous[old['key']] = (old.get('stockHash'), old.get('timestamp'))
                except (ValueError, UnicodeError):
                    continue
    result = []
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get('key'), str) or not KEY.fullmatch(row['key']):
            continue
        ts = row.get('ts')
        if type(ts) not in (int, float) or not 0 < ts < 100000000000 or row.get('transient') is True:
            continue
        if not all(isinstance(row.get(k), str) for k in ('app', 'summary', 'body')):
            continue
        encoded = json.dumps(row, ensure_ascii=True, sort_keys=True).encode()
        if len(encoded) > ROW_LIMIT:
            continue
        digest = hashlib.sha256(encoded)
        paths = [row.get('appIcon'), row.get('image')]
        argv = row.get('execArgv', [])
        if isinstance(argv, str):
            try:
                argv = json.loads(argv)
            except ValueError:
                argv = []
        if isinstance(argv, list):
            paths.extend(argv[:32])
        for name in paths:
            if not isinstance(name, str):
                continue
            name = name.removeprefix('file://')
            if not name.startswith('/') or len(name) > 4096 or '\0' in name:
                continue
            try:
                info = os.stat(name)
                digest.update(str((info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)).encode())
            except OSError:
                digest.update(b'missing')
        key = 'stock-' + row['key']
        fingerprint = digest.hexdigest()
        old_hash, old_timestamp = previous.get(key, (None, None))
        if old_hash == fingerprint:
            continue
        row = dict(row, key=key, stockHash=fingerprint,
                   timestamp=old_timestamp if type(old_timestamp) is int else int(ts * 1000))
        if isinstance(row.get('rawBody'), str) and row['rawBody']:
            row['body'] = row['rawBody']
        result.append(row)
    return sorted(result, key=lambda row: row['timestamp'])


def present_keys(source):
    """Every archive key the stock file still holds (for tombstone trimming)."""
    with source.open('rb') as stream:
        raw = stream.read(LIMIT + 1)
    if not raw.strip():
        return []
    if len(raw) > LIMIT:
        raise ValueError('stock notification file exceeds 8 MiB')
    rows = json.loads(raw)
    if not isinstance(rows, list):
        raise ValueError('invalid stock notification array')
    return ['stock-' + row['key'] for row in rows
            if isinstance(row, dict) and isinstance(row.get('key'), str) and KEY.fullmatch(row['key'])]


def main():
    try:
        if sys.argv[1] == '--keys':
            for key in present_keys(Path(sys.argv[2])):
                print(key)
            return 0
        for row in changed_rows(Path(sys.argv[1]), Path(sys.argv[2])):
            print(json.dumps(row, ensure_ascii=True, separators=(',', ':')))
    except (OSError, ValueError) as error:
        # Never include JSON parser excerpts: these files contain private messages.
        print('notification-center: cannot read stock notification array (' + type(error).__name__ + ')', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

#!/usr/bin/env python3
"""Resolve a favicon from local Chromium caches without website requests."""
from contextlib import closing
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import struct
import sys
import tempfile
import time

ROOTS = {
    'vivaldi': ['vivaldi', 'vivaldi-snapshot'],
    'brave': ['BraveSoftware/Brave-Browser'],
    'microsoft-edge': ['microsoft-edge', 'microsoft-edge-beta', 'microsoft-edge-dev'],
    'msedge': ['microsoft-edge', 'microsoft-edge-beta', 'microsoft-edge-dev'],
    'chromium': ['chromium'],
    'google-chrome': ['google-chrome', 'google-chrome-beta', 'google-chrome-unstable'],
    'chrome': ['google-chrome', 'google-chrome-beta', 'google-chrome-unstable'],
    'opera': ['opera', 'opera-developer'],
}
HOST = re.compile(r'(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?')
MAX_BYTES = 65536


def valid_png(data):
    if not isinstance(data, bytes) or not 24 <= len(data) <= MAX_BYTES:
        return False
    if data[:8] != b'\x89PNG\r\n\x1a\n' or data[12:16] != b'IHDR':
        return False
    width, height = struct.unpack('>II', data[16:24])
    return 0 < width <= 256 and 0 < height <= 256


def favicon(browser, host, config):
    deadline = time.monotonic() + 2
    for name in ROOTS.get(browser, []):
        root = config / name
        # Inspect fixed browser roots and at most sixteen ordinary profiles.
        databases = [root / 'Favicons', root / 'Default/Favicons']
        if root.is_dir():
            databases.extend(sorted(root.glob('Profile */Favicons'))[:15])
        for database in databases:
            if time.monotonic() >= deadline:
                return b''
            if not database.is_file() or database.is_symlink():
                continue
            try:
                with closing(sqlite3.connect(database.as_uri() + '?mode=ro', uri=True, timeout=0.1)) as connection:
                    connection.set_progress_handler(lambda: time.monotonic() >= deadline, 1000)
                    for scheme in ['https://', 'http://']:
                        prefix = scheme + host + '/'
                        rows = connection.execute('''
                            SELECT b.image_data FROM icon_mapping m
                            JOIN favicon_bitmaps b ON m.icon_id = b.icon_id
                            WHERE m.page_url >= ? AND m.page_url < ?
                              AND b.width BETWEEN 1 AND 256 AND b.height BETWEEN 1 AND 256
                              AND length(b.image_data) BETWEEN 24 AND ?
                            ORDER BY abs(b.width - 32), b.last_updated DESC LIMIT 8
                        ''', (prefix, prefix[:-1] + '0', MAX_BYTES))
                        for (data,) in rows:
                            if valid_png(data):
                                return data
            except (sqlite3.Error, OSError):
                # Locked, absent or changed browser databases leave the app icon intact.
                continue
    return b''


def resolve(request):
    browser, host = request.get('browser'), request.get('hostname')
    if browser not in ROOTS:
        return {'source': '', 'status': 'unsupported-browser'}
    if not isinstance(host, str) or not HOST.fullmatch(host):
        raise ValueError('Invalid website hostname')
    config = Path(os.environ.get('XDG_CONFIG_HOME', str(Path.home() / '.config')))
    cache = Path(os.environ.get('XDG_CACHE_HOME', str(Path.home() / '.cache'))) / 'foamy/browser-favicons'
    target = cache / (hashlib.sha256((browser + '\n' + host).encode()).hexdigest() + '.png')
    try:
        if not target.is_symlink() and target.is_file() and time.time() - target.stat().st_mtime < 86400:
            with target.open('rb') as stream:
                if valid_png(stream.read(MAX_BYTES + 1)):
                    return {'source': target.as_uri(), 'status': 'cached'}
    except OSError:
        pass
    data = favicon(browser, host, config)
    if not data:
        return {'source': '', 'status': 'not-found'}
    cache.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary = tempfile.mkstemp(prefix='.favicon-', dir=cache)
    try:
        with os.fdopen(descriptor, 'wb') as stream:
            stream.write(data)
        os.replace(temporary, target)
    finally:
        Path(temporary).unlink(missing_ok=True)
    # Bound the shared cache; each plugin falls back if an older displayed file expires.
    files = []
    for path in cache.glob('*.png'):
        try:
            files.append((path.stat().st_mtime, path))
        except FileNotFoundError:
            continue
    for _, path in sorted(files, reverse=True)[256:]:
        path.unlink(missing_ok=True)
    return {'source': target.as_uri(), 'status': 'found'}


if __name__ == '__main__':
    os.umask(0o077)
    try:
        raw = sys.stdin.buffer.read(4097)
        if len(raw) > 4096:
            raise ValueError('Favicon request exceeds the size limit')
        request = json.loads(raw)
        if not isinstance(request, dict):
            raise ValueError('Expected a favicon request object')
        print(json.dumps(resolve(request)))
    except Exception as error:
        print(json.dumps({'source': '', 'status': 'error'}))
        print('Favicon lookup failed: ' + type(error).__name__, file=sys.stderr)
        sys.exit(1)

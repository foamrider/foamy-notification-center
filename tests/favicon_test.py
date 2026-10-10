from contextlib import closing
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zlib

SCRIPT = Path(__file__).resolve().parents[1] / 'bin/browser-favicon.py'
spec = importlib.util.spec_from_file_location('favicon', SCRIPT)
favicon = importlib.util.module_from_spec(spec)
spec.loader.exec_module(favicon)


def png():
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(b'\0\x50\x80\xF0\xFF')) + chunk(b'IEND', b'')


class FaviconTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = self.root / 'config'
        self.env = {'XDG_CONFIG_HOME': str(self.config), 'XDG_CACHE_HOME': str(self.root / 'cache')}

    def database(self, rows):
        path = self.config / 'vivaldi/Profile 1/Favicons'
        path.parent.mkdir(parents=True)
        with closing(sqlite3.connect(path)) as db:
            db.executescript('CREATE TABLE icon_mapping (page_url TEXT, icon_id INTEGER); CREATE INDEX urls ON icon_mapping(page_url); CREATE TABLE favicon_bitmaps (icon_id INTEGER, image_data BLOB, width INTEGER, height INTEGER, last_updated INTEGER);')
            for i, (url, data) in enumerate(rows):
                db.execute('INSERT INTO icon_mapping VALUES (?, ?)', (url, i))
                db.execute('INSERT INTO favicon_bitmaps VALUES (?, ?, 32, 32, 100)', (i, data))
            db.commit()
        return path

    def test_real_helper_extracts_private_png_and_reuses_cache(self):
        database = self.database([('https://teams.microsoft.com/chat', png())])
        env = {**os.environ, **self.env}
        result = subprocess.run(['python3', str(SCRIPT)], input=json.dumps({'browser':'vivaldi','hostname':'teams.microsoft.com'}), capture_output=True, text=True, env=env, timeout=4)
        self.assertEqual(result.returncode, 0, result.stderr)
        response = json.loads(result.stdout)
        self.assertEqual(response['status'], 'found')
        icon = Path(response['source'].removeprefix('file://'))
        self.assertEqual(icon.read_bytes(), png())
        self.assertEqual(icon.stat().st_mode & 0o777, 0o600)
        self.assertEqual(database.stat().st_size > 0, True)
        database.unlink()
        with patch.dict(os.environ, self.env):
            self.assertEqual(favicon.resolve({'browser':'vivaldi','hostname':'teams.microsoft.com'})['status'], 'cached')

    def test_hostname_bounds_do_not_match_other_sites_or_remote_icons(self):
        self.database([('https://teams.microsoft.com.evil.invalid/chat', png()), ('https://other.example.com/', png())])
        with patch.dict(os.environ, self.env):
            self.assertEqual(favicon.resolve({'browser':'vivaldi','hostname':'teams.microsoft.com'})['source'], '')
            for host in ['../secret','https://example.com','example.com:443','example.com\nother.com']:
                with self.assertRaises(ValueError):
                    favicon.resolve({'browser':'vivaldi','hostname':host})
            self.assertEqual(favicon.resolve({'browser':'firefox','hostname':'example.com'})['status'], 'unsupported-browser')

    def test_missing_corrupt_and_oversized_icons_fall_back(self):
        with patch.dict(os.environ, self.env):
            self.assertEqual(favicon.resolve({'browser':'vivaldi','hostname':'example.com'})['source'], '')
            path = self.database([('https://example.com/', b'x'*65537), ('http://example.com/', b'not a PNG')])
            self.assertEqual(favicon.resolve({'browser':'vivaldi','hostname':'example.com'})['source'], '')
            path.write_bytes(b'corrupt database')
            self.assertEqual(favicon.resolve({'browser':'vivaldi','hostname':'example.com'})['source'], '')
        data = bytearray(png())
        data[16:20] = struct.pack('>I', 99999)
        self.assertFalse(favicon.valid_png(bytes(data)))


if __name__ == '__main__':
    unittest.main()

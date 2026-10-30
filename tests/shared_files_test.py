"""Files shared verbatim with foamy-notification-center (the other half of the contract).

Both repositories carry the same tests/shared-files.sha256. Change a shared file in
both repositories and refresh the list in both (sha256sum ... > tests/shared-files.sha256).
"""
import hashlib
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SharedFiles(unittest.TestCase):
    def test_shared_files_match_the_common_manifest(self):
        for line in (ROOT / 'tests/shared-files.sha256').read_text().splitlines():
            digest, name = line.split(maxsplit=1)
            self.assertEqual(hashlib.sha256((ROOT / name).read_bytes()).hexdigest(), digest, name)


if __name__ == '__main__':
    unittest.main()

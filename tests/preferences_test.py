import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("preferences", Path(__file__).parents[1] / "bin/notification-preferences.py")
preferences = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preferences)


class PreferencesTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.base = Path(self.directory.name)
        self.source = self.base / "source.json"
        self.path = self.base / "shell.json"
        self.path.symlink_to(self.source)
        self.config = {"version": 1, "unrelated": {"value": "keep"}, "bar": {"layout": {"right": [{"id": "foamy.notification-center", "compact": False}]}},
                       "plugins": [{"id": "other.service", "value": 7}, {"id": "foamy.notifications", "browserGrouping": "hostname", "custom": "preserve"}]}
        self.source.write_text(json.dumps(self.config))
        self.source.chmod(0o640)
        self.environment = patch.dict(os.environ, {"XDG_CACHE_HOME": str(self.base / "cache")})
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def test_save_preserves_stow_link_permissions_and_unrelated_settings(self):
        result = preferences.save(self.path, "compact", False)
        expected = json.loads(json.dumps(self.config))
        expected["plugins"][1]["compact"] = False
        self.assertEqual(json.loads(self.source.read_text()), expected)
        self.assertTrue(self.path.is_symlink())
        self.assertEqual(self.source.stat().st_mode & 0o777, 0o640)
        self.assertFalse(result["settings"]["compact"])

    def test_repeated_saves_re_read_other_changes(self):
        preferences.save(self.path, "showImages", False)
        config = json.loads(self.source.read_text())
        config["bar"]["layout"]["right"][0]["compact"] = True
        self.source.write_text(json.dumps(config))
        preferences.save(self.path, "normalTimeoutSec", 12)
        config = json.loads(self.source.read_text())
        self.assertFalse(config["plugins"][1]["showImages"])
        self.assertEqual(config["plugins"][1]["normalTimeoutSec"], 12)
        self.assertTrue(config["bar"]["layout"]["right"][0]["compact"])

    def test_invalid_values_and_unknown_keys_do_not_write(self):
        before = self.source.read_bytes()
        for key, value in [("normalTimeoutSec", 0), ("normalTimeoutSec", True), ("normalTimeoutSec", 121), ("normalTimeoutSec", 1.5), ("compact", 1), ("compact", "false"), ("browserGrouping", "hostname")]:
            with self.assertRaises(ValueError):
                preferences.save(self.path, key, value)
        self.assertEqual(self.source.read_bytes(), before)

    def test_disabled_or_missing_service_is_not_enabled_by_saving(self):
        for config in [{**self.config, "disabledPlugins": ["foamy.notifications"]}, {"plugins": []}]:
            self.source.write_text(json.dumps(config))
            before = self.source.read_bytes()
            with self.assertRaises(ValueError):
                preferences.save(self.path, "compact", False)
            self.assertEqual(self.source.read_bytes(), before)
            self.assertFalse(preferences.settings(config, config["plugins"][-1] if config["plugins"] else None)["available"])

    def test_invalid_config_is_preserved(self):
        for text in ["broken", "[]", '{"plugins": {}}', json.dumps({"plugins": [self.config["plugins"][1]] * 2})]:
            self.source.write_text(text)
            with self.assertRaises(ValueError):
                preferences.save(self.path, "compact", False)
            self.assertEqual(self.source.read_text(), text)

    def test_missing_plugins_field_means_service_is_unavailable(self):
        config = {"version": 1, "bar": self.config["bar"]}
        self.source.write_text(json.dumps(config))
        before = self.source.read_bytes()
        _, _, loaded, entry = preferences.read_config(self.path)
        self.assertFalse(preferences.settings(loaded, entry)["available"])
        with self.assertRaisesRegex(ValueError, "not enabled"):
            preferences.save(self.path, "compact", False)
        self.assertEqual(self.source.read_bytes(), before)

    def test_legacy_none_override_can_be_enabled_through_duplicate_toggle(self):
        self.config["plugins"][1]["browserGrouping"] = "none"
        self.source.write_text(json.dumps(self.config))
        self.assertFalse(preferences.settings(self.config, self.config["plugins"][1])["settings"]["groupDuplicates"])
        result = preferences.save(self.path, "groupDuplicates", True)
        self.assertTrue(result["settings"]["groupDuplicates"])
        self.assertEqual(json.loads(self.source.read_text())["plugins"][1]["browserGrouping"], "browser")

    def test_concurrent_editor_change_is_not_overwritten(self):
        real_fsync = os.fsync
        def edit_after_flush(fd):
            real_fsync(fd)
            self.source.write_text(json.dumps({**self.config, "editor": True}))
        with patch.object(preferences.os, "fsync", side_effect=edit_after_flush):
            with self.assertRaisesRegex(ValueError, "changed"):
                preferences.save(self.path, "compact", False)
        self.assertTrue(json.loads(self.source.read_text())["editor"])
        self.assertNotIn("compact", json.loads(self.source.read_text())["plugins"][1])
        self.assertEqual(list(self.base.glob(".foamy-notifications-*")), [])


if __name__ == "__main__":
    unittest.main()

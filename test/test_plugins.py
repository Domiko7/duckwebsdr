import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HTDOCS = ROOT / "htdocs"
RECEIVER = HTDOCS / "plugins" / "receiver"


class LocalPluginTest(unittest.TestCase):
    def test_loader_loads_no_remote_plugins(self):
        loader = (HTDOCS / "plugins.js").read_text(encoding="utf-8")
        self.assertNotIn("0xaf.github.io", loader)

    def test_loader_does_not_use_top_level_await(self):
        # plugins.js is loaded as a classic script, top-level await is a syntax error
        loader = (HTDOCS / "plugins.js").read_text(encoding="utf-8")
        self.assertNotIn("await Plugins.load", loader)

    def test_far_frequency_plugin_is_vendored(self):
        self.assertTrue((RECEIVER / "frequency_far_jump" / "frequency_far_jump.js").is_file())
        self.assertTrue((RECEIVER / "utils" / "utils.js").is_file())

    def test_far_frequency_plugin_loads_utils_locally(self):
        plugin = (RECEIVER / "frequency_far_jump" / "frequency_far_jump.js").read_text(encoding="utf-8")
        self.assertNotIn("0xaf.github.io", plugin)
        self.assertIn("Plugins.load('utils')", plugin)


if __name__ == "__main__":
    unittest.main()

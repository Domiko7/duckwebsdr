import unittest

from owrx.version_compat import LooseVersion, StrictVersion


class VersionCompatTest(unittest.TestCase):
    def test_loose_version_ordering(self):
        self.assertGreaterEqual(LooseVersion("0.18.40"), LooseVersion("0.18.0"))
        self.assertLess(LooseVersion("0.5"), LooseVersion("0.6"))
        self.assertEqual(LooseVersion("4"), LooseVersion("4"))

    def test_strict_version_ordering(self):
        self.assertEqual(StrictVersion("0.1"), StrictVersion("0.1"))
        self.assertLess(StrictVersion("0.1"), StrictVersion("0.2"))

    def test_version_module_imports(self):
        import owrx.version

        self.assertRegex(owrx.version.openwebrx_version, r"^v\d+\.\d+")


if __name__ == "__main__":
    unittest.main()

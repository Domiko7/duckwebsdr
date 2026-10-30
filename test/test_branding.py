import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HTDOCS = ROOT / "htdocs"


class BrandingTest(unittest.TestCase):
    def test_duck_logo_asset_exists(self):
        self.assertTrue((HTDOCS / "gfx" / "ducksdr-logo.png").is_file())

    def test_header_uses_duck_logo(self):
        header = (HTDOCS / "include" / "header.include.html").read_text(encoding="utf-8")
        self.assertIn("ducksdr-logo.png", header)
        self.assertNotIn("svg-defs.svg#top-logo", header)

    def test_index_title_is_ducksdr(self):
        index = (HTDOCS / "index.html").read_text(encoding="utf-8")
        self.assertIn("<title>DuckSdr", index)

    def test_page_titles_do_not_use_old_brand(self):
        for page in HTDOCS.rglob("*.html"):
            for line in page.read_text(encoding="utf-8", errors="ignore").splitlines():
                if "<title>" in line.lower():
                    self.assertNotIn("OpenWebRX", line, str(page))

    def test_policy_page_uses_new_brand(self):
        policy = (HTDOCS / "policy.html").read_text(encoding="utf-8")
        self.assertIn("DuckSdr Usage Policy", policy)


if __name__ == "__main__":
    unittest.main()

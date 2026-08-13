import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from update_altstore_source import load_source, update_source


ROOT = Path(__file__).resolve().parents[1]


class AltStoreSourceTests(unittest.TestCase):
    def test_repository_source_is_valid(self) -> None:
        source = load_source(ROOT / "altstore-source.json")
        self.assertEqual(source["apps"][0]["bundleIdentifier"], "com.orangewoker.edui")

    def test_update_prepends_and_replaces_the_same_version(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source_path = Path(directory) / "source.json"
            source_path.write_text(
                (ROOT / "altstore-source.json").read_text(encoding="utf-8"),
                encoding="utf-8",
            )
            ipa_path = Path(directory) / "EDUI.ipa"
            ipa_path.write_bytes(b"fixture ipa")
            for description in ("first", "replacement"):
                update_source(
                    source_path,
                    ipa_path,
                    "9.9.9",
                    "999",
                    "https://example.test/EDUI.ipa",
                    description,
                    "2026-08-13T16:00:00Z",
                )
            source = json.loads(source_path.read_text(encoding="utf-8"))
            versions = source["apps"][0]["versions"]
            self.assertEqual(versions[0]["version"], "9.9.9")
            self.assertEqual(versions[0]["localizedDescription"], "replacement")
            self.assertEqual(len([item for item in versions if item["version"] == "9.9.9"]), 1)
            self.assertEqual(versions[0]["size"], len(b"fixture ipa"))


if __name__ == "__main__":
    unittest.main()

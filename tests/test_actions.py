import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from logitech_receiver.diversion import KeyPress
import yaml

CLI = Path(__file__).resolve().parents[1] / "bin" / "omaoptions"


class PrintScreenActionTest(unittest.TestCase):
    def test_print_is_offered_only_for_keyboard_keys(self):
        root = CLI.parents[1]
        catalog = json.loads((root / "actions.json").read_text())["actions"]
        self.assertEqual(sum(a["id"] == "print-screen" for a in catalog), 1)
        options = {scope: [a["id"] for a in catalog if scope in a.get("scopes", [])]
                   for scope in ("key", "button", "gesture", "thumb", "thumbextra")}
        self.assertIn("print-screen", options["key"])
        self.assertEqual(options["key"].index("print-screen"), options["key"].index("screenshot") + 1)
        for scope in ("button", "gesture", "thumb", "thumbextra"):
            self.assertNotIn("print-screen", options[scope])

    def test_apply_maps_a_keyboard_key_to_print(self):
        keyboard = {
            "name": "MX Keys Mini",
            "kind": "keyboard",
            "keys": [{"name": "Screen Capture", "cid": 266, "divertable": True}],
            "settings": ["divert-keys"],
        }
        config = {"version": 4, "devices": {"MX Keys Mini": {"slots": {"key.0x10a": "print-screen"}}}}
        with tempfile.TemporaryDirectory() as home:
            conf = Path(home, ".config/omarchy/omaoptions")
            conf.mkdir(parents=True)
            (conf / "devices.json").write_text(json.dumps({"devices": [keyboard]}))

            result = subprocess.run(
                [sys.executable, CLI, "apply", "--no-restart", "--json", json.dumps(config)],
                env=os.environ | {"HOME": home},
                capture_output=True,
                text=True,
                check=True,
            )
            rules = list(yaml.safe_load_all(Path(home, ".config/solaar/rules.yaml").read_text()))

        self.assertEqual(json.loads(result.stdout)["warnings"], [])
        self.assertEqual(
            rules,
            [[{"Device": "MX Keys Mini"}, {"Key": ["Screen Capture", "pressed"]}, {"KeyPress": ["Print"]}]],
        )
        self.assertTrue(KeyPress(rules[0][-1]["KeyPress"]).key_symbols)


if __name__ == "__main__":
    unittest.main()

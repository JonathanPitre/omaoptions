import importlib.machinery
import importlib.util
import json
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest

ROOT = Path(__file__).resolve().parents[1]
INVALID_NAMES = ("", "   ", "\x00\x01garbled", None)


def record(name, serial=""):
    return {"name": name, "kind": "mouse", "serial": serial, "keys": [], "settings": []}


def hardware(name, serial=""):
    return SimpleNamespace(name=name, serial=serial, kind="mouse", online=True, keys=[], settings=[])


class InventoryTestCase(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name)
        self.state = self.home / ".config" / "omarchy" / "omaoptions"
        self.state.mkdir(parents=True)
        (self.home / "bin").mkdir()
        self.stub("systemctl", "echo active")

    def stub(self, command, script):
        path = self.home / "bin" / command
        path.write_text(f"#!/bin/sh\n{script}\n")
        path.chmod(0o755)

    def write_inventory(self, *records):
        (self.state / "devices.json").write_text(json.dumps({"devices": list(records)}))

    def cli(self, command):
        return subprocess.run([sys.executable, str(ROOT / "bin" / "omaoptions"), command], capture_output=True,
                              text=True, env={"HOME": str(self.home), "PATH": str(self.home / "bin")})

    def listed(self, command):
        result = self.cli(command)
        self.assertEqual(result.returncode, 0, result.stderr)
        return [(d["name"], d["serial"]) for d in json.loads(result.stdout)["devices"]]


class CliInventoryTests(InventoryTestCase):
    def assert_listed(self, expected):
        for command in ("get", "discover"):
            with self.subTest(command=command):
                self.assertEqual(self.listed(command), expected)

    def test_invalid_names_are_not_listed(self):
        self.write_inventory(*map(record, INVALID_NAMES), record("MX Keys Mini", "kbd"))
        self.assert_listed([("MX Keys Mini", "kbd")])

    def test_discover_treats_an_inventory_of_invalid_names_as_empty(self):
        self.write_inventory(*map(record, INVALID_NAMES))
        result = self.cli("discover")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stdout)["devices"], [])

    def test_discover_probe_results_get_the_same_cleanup(self):
        probed = [*map(record, INVALID_NAMES), record("Mouse", ""), record("Mouse", "one")]
        self.stub("systemctl", "echo inactive")
        self.stub("solaar", "")
        self.stub("python3", f"printf '%s\\n' {shlex.quote(json.dumps(probed))}")
        self.assertEqual(self.listed("discover"), [("Mouse", "one")])

    def test_get_skips_invalid_names_saved_in_config(self):
        self.write_inventory(record("MX Keys Mini", "kbd"))
        devices = {name: {} for name in ("", "   ", "\x00\x01garbled", "Saved Mouse")}
        (self.state / "config.json").write_text(json.dumps({"version": 4, "devices": devices}))
        self.assertEqual(self.listed("get"), [("MX Keys Mini", "kbd"), ("Saved Mouse", "")])

    def test_same_name_with_different_serials_has_one_panel_target(self):
        self.write_inventory(record("MX Anywhere 3S", "one"), record("MX Anywhere 3S", "two"))
        self.assert_listed([("MX Anywhere 3S", "two")])

    def test_transport_duplicates_have_one_panel_target(self):
        self.write_inventory(record("Mouse"), record("Mouse", "one"))
        self.assert_listed([("Mouse", "one")])

    def test_status_filters_invalid_names(self):
        import time
        (self.state / "status.json").write_text(json.dumps({"at": time.time(), "devices": [*map(record, INVALID_NAMES), record("Mouse", "one")]}))
        self.assertEqual([d["name"] for d in json.loads(self.cli("status").stdout)["devices"]], ["Mouse"])

    def test_empty_sighting_does_not_hide_discovered_controls(self):
        known = record("Mouse", "one") | {"settings": ["dpi"]}
        for rows in ((known, record("Mouse")), (record("Mouse"), known)):
            self.write_inventory(*rows)
            self.assert_listed([("Mouse", "one")])

    def test_name_identifies_records_without_a_serial(self):
        self.write_inventory(record("MX Keys Mini"), record("MX Keys Mini"))
        self.assert_listed([("MX Keys Mini", "")])


class DaemonInventoryTests(InventoryTestCase):
    def setUp(self):
        super().setUp()
        loader = importlib.machinery.SourceFileLoader("omaoptions_daemon", str(ROOT / "bin" / "omaoptions-daemon"))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        self.daemon = importlib.util.module_from_spec(spec)
        loader.exec_module(self.daemon)
        self.daemon.STATE_DIR = str(self.state)
        self.daemon.DEVICES_PATH = str(self.state / "devices.json")

    def recorded(self):
        return [(d["name"], d["serial"]) for d in json.loads((self.state / "devices.json").read_text())["devices"]]

    def test_devices_sharing_a_name_have_one_panel_target(self):
        self.daemon.record_keys(hardware("MX Anywhere 3S", "one"))
        self.daemon.record_keys(hardware("MX Anywhere 3S", "two"))
        self.assertEqual(self.listed("get"), [("MX Anywhere 3S", "two")])

    def test_invalid_name_is_not_recorded_until_the_real_name_arrives(self):
        for name in INVALID_NAMES:
            with self.subTest(name=name):
                device = hardware(name, "one")
                self.daemon.record_keys(device)
                self.assertFalse((self.state / "devices.json").exists())
        device.name = "MX Keys Mini"
        self.daemon.record_keys(device)
        self.assertEqual(self.recorded(), [("MX Keys Mini", "one")])

    def test_empty_sighting_does_not_overwrite_discovered_controls(self):
        known = record("Mouse", "one") | {"settings": ["dpi"]}
        self.write_inventory(known)
        self.daemon.record_keys(hardware("Mouse"))
        self.assertEqual(self.recorded(), [("Mouse", "one")])
        self.assertEqual(json.loads((self.state / "devices.json").read_text())["devices"][0]["settings"], ["dpi"])

    def test_snapshot_skips_invalid_names(self):
        devices = [*map(hardware, INVALID_NAMES), hardware("Mouse", "one")]
        self.daemon._devices = dict(enumerate(devices))
        self.assertEqual([d["name"] for d in self.daemon._snapshot()], ["Mouse"])

    def test_recording_drops_invalid_rows(self):
        self.write_inventory(*map(record, INVALID_NAMES), record("MX Keys Mini", "kbd"))
        self.daemon.record_keys(hardware("MX Anywhere 3S", "one"))
        self.assertEqual(self.recorded(), [("MX Keys Mini", "kbd"), ("MX Anywhere 3S", "one")])


if __name__ == "__main__":
    unittest.main()

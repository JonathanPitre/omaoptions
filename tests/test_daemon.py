import heapq
import importlib.machinery
import importlib.util
import itertools
import json
from pathlib import Path
import struct
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from logitech_receiver.device import Device as SolaarDevice
from logitech_receiver.hidpp20 import KeyFlag, KeysArrayV4, MappingFlag
from logitech_receiver.hidpp20_constants import SupportedFeature as Feature
from logitech_receiver.settings import apply_all_settings
from logitech_receiver.settings_templates import FnSwap


class Clock:
    def __init__(self):
        self.now = 0
        self.ids = itertools.count(1)
        self.queue = []
        self.cancelled = set()

    def idle_add(self, callback, *args):
        return self.timeout_add(0, callback, *args)

    def timeout_add(self, delay, callback, *args):
        source = next(self.ids)
        heapq.heappush(self.queue, (self.now + delay, source, delay, callback, args))
        return source

    def source_remove(self, source):
        self.cancelled.add(source)

    def advance(self, milliseconds):
        end = self.now + milliseconds
        calls = 0
        while self.queue and self.queue[0][0] <= end:
            self.now, source, delay, callback, args = heapq.heappop(self.queue)
            if source in self.cancelled:
                continue
            calls += 1
            if calls > 100:
                raise AssertionError("recovery callbacks did not back off")
            if callback(*args):
                heapq.heappush(self.queue, (self.now + delay, source, delay, callback, args))
        self.now = end


class Features(set):
    def get_feature_version(self, feature):
        return 0

    def get_hidden(self, feature):
        return False


class Device:
    name = "MX Keys Mini"
    serial = "test-keyboard"
    kind = "keyboard"
    path = "/test/keyboard"
    protocol = 2.0
    receiver = None
    bluetooth = True
    battery_info = None
    descriptor = None
    settings = SolaarDevice.settings

    def __init__(self):
        self.online = True
        self.ready = False
        self.features = Features({Feature.FN_INVERSION, Feature.REPROG_CONTROLS_V4})
        self.persister = {"fn-swap": False, "divert-keys": {266: 1}}
        self._settings = []
        self._settings_lock = threading.Lock()
        self._feature_settings_checked = True
        self._keys = KeysArrayV4(self, 1)
        self.writes = []
        self.fn_value = True
        self.diversion_flags = MappingFlag(0)
        self.fail_fn = False
        self.fail_diversion = False
        self.fail_key_info = False
        self.drop_diversion_write = False
        self.fail_diversion_read = False
        self.ignore_fn_write = False
        self.fail_fn_read = False

    @property
    def keys(self):
        return self._keys if self.ready else []

    @property
    def key(self):
        return self._keys[0]

    def feature_request(self, feature, function=0, *data, **kwargs):
        payload = b"".join(bytes([v]) if isinstance(v, int) else v for v in data)
        if feature == Feature.FN_INVERSION:
            if function == 0:
                return None if self.fail_fn_read else bytes([self.fn_value])
            value = bool(payload[0])
            self.writes.append(("fn-swap", value))
            if self.fail_fn:
                return None
            if not self.ignore_fn_write:
                self.fn_value = value
            return b"\x01"
        if feature == Feature.REPROG_CONTROLS_V4:
            if function == 0:
                return b"\x01"
            if function == 0x10:
                return None if self.fail_key_info else struct.pack("!HHBBBBB", 266, 266, KeyFlag.DIVERTABLE.value, 0, 0, 0, 0)
            if function == 0x20:
                return None if self.fail_diversion_read else struct.pack("!HBH", 266, self.diversion_flags.value, 266)
            if function == 0x30:
                value = bool(payload[2] & MappingFlag.DIVERTED.value)
                self.writes.append(("divert-keys", {266: int(value)}))
                if self.fail_diversion:
                    raise OSError("temporary transport failure")
                if self.drop_diversion_write:
                    return None
                if value:
                    self.diversion_flags |= MappingFlag.DIVERTED
                else:
                    self.diversion_flags &= ~MappingFlag.DIVERTED
                return payload
        raise AssertionError(f"unexpected transport request {feature} {function}")


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        path = Path(__file__).resolve().parents[1] / "bin" / "omaoptions-daemon"
        loader = importlib.machinery.SourceFileLoader("omaoptions_daemon", str(path))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        self.daemon = importlib.util.module_from_spec(spec)
        loader.exec_module(self.daemon)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.daemon.STATE_DIR = self.temp.name
        for name, filename in (("DEVICES_PATH", "devices.json"), ("STATUS_PATH", "status.json"),
                               ("PENDING_PATH", "pending.json")):
            setattr(self.daemon, name, str(Path(self.temp.name) / filename))
        self.clock = Clock()
        self.daemon.GLib = self.clock
        self.device = Device()

    def notify(self, count=1):
        for _ in range(count):
            self.daemon.status_changed(self.device)
        self.clock.advance(0)

    def inventory(self):
        return json.loads(Path(self.daemon.DEVICES_PATH).read_text())

    def test_empty_discovery_preserves_inventory_and_recovers_without_another_notification(self):
        previous = {"devices": [{"name": "MX Keys Mini", "keys": [{"cid": 266}]}]}
        Path(self.daemon.DEVICES_PATH).write_text(json.dumps(previous))
        self.notify()
        self.clock.advance(2000)
        self.assertEqual(self.inventory(), previous)
        self.device.ready = True
        self.clock.advance(60000)
        self.assertEqual(self.inventory()["devices"][0]["keys"][0]["cid"], 266)
        self.assertEqual(self.device.writes, [("fn-swap", False), ("divert-keys", {266: 1})])

    def test_latched_settings_are_rediscovered_and_saved_values_override_live_cache(self):
        self.device.ready = True
        setting = FnSwap.build(self.device)
        setting.read(cached=False)
        self.device._settings = [setting]
        Path(self.temp.name, "config.json").write_text(json.dumps({"devices": {"MX Keys Mini": {
            "settings": {"topRow": "media"}, "slots": {"key.0x10a": "default"}}}}))
        self.notify(5)
        self.clock.advance(60000)
        self.assertEqual(self.device.writes, [("fn-swap", False), ("divert-keys", {266: 1})])
        self.assertIn("divert-keys", self.inventory()["devices"][0]["settings"])
        self.assertEqual(self.device.persister["fn-swap"], False)
        self.assertEqual(self.device.persister["divert-keys"], {266: 1})
        self.device.fn_value = True
        self.device.diversion_flags = MappingFlag(0)
        self.device.writes.clear()
        apply_all_settings(self.device)
        self.assertEqual(self.device.writes, [("fn-swap", False), ("divert-keys", {266: 1})])
        self.assertFalse(self.device.fn_value)
        self.assertIn(MappingFlag.DIVERTED, self.device.diversion_flags)

    def test_duplicate_notifications_do_not_replay_until_reconnect(self):
        self.device.ready = True
        self.notify(5)
        self.clock.advance(60000)
        self.notify(5)
        self.clock.advance(60000)
        self.assertEqual(len(self.device.writes), 2)
        self.device.online = False
        self.notify()
        self.device.online = True
        self.device.diversion_flags = MappingFlag(0)
        self.notify(3)
        self.clock.advance(60000)
        self.assertEqual(self.device.writes, [("fn-swap", False), ("divert-keys", {266: 1})] * 2)

    def test_failed_write_is_retried_without_repeating_successful_settings(self):
        self.device.ready = True
        self.device.fail_diversion = True
        self.notify()
        self.clock.advance(2000)
        self.device.fail_diversion = False
        self.clock.advance(60000)
        self.assertEqual(self.device.writes.count(("fn-swap", False)), 1)
        self.assertGreaterEqual(self.device.writes.count(("divert-keys", {266: 1})), 2)
        self.assertEqual(self.device.diversion_flags, MappingFlag.DIVERTED)

    def test_late_device_still_recovers_after_minutes_online(self):
        self.notify()
        self.clock.advance(300000)
        self.assertFalse(Path(self.daemon.DEVICES_PATH).exists())
        self.device.ready = True
        self.clock.advance(30000)
        self.assertEqual(self.device.writes, [("fn-swap", False), ("divert-keys", {266: 1})])

    def test_offline_device_stops_recovery(self):
        self.notify()
        self.device.online = False
        self.notify()
        self.device.ready = True
        self.clock.advance(60000)
        self.assertEqual(self.device.writes, [])
        self.assertFalse(Path(self.daemon.DEVICES_PATH).exists())

    def test_queued_offline_online_edge_starts_a_new_recovery(self):
        self.device.ready = True
        self.notify()
        self.clock.advance(60000)
        self.device.online = False
        self.daemon.status_changed(self.device)
        self.device.online = True
        self.daemon.status_changed(self.device)
        self.clock.advance(60000)
        self.assertEqual(len(self.device.writes), 4)

    def test_replaced_device_cancels_the_old_recovery(self):
        old = self.device
        self.notify()
        self.device = Device()
        self.device.ready = True
        self.notify()
        old.ready = True
        self.clock.advance(60000)
        self.assertEqual(old.writes, [])
        self.assertEqual(self.device.writes, [("fn-swap", False), ("divert-keys", {266: 1})])

    def test_partial_keys_are_not_saved(self):
        self.device.ready = True
        self.device.fail_key_info = True
        self.notify()
        self.clock.advance(2000)
        self.assertFalse(Path(self.daemon.DEVICES_PATH).exists())
        self.device.fail_key_info = False
        self.clock.advance(60000)
        self.assertEqual(self.device.diversion_flags, MappingFlag.DIVERTED)

    def test_keyboard_without_remappable_keys_still_restores_fn_swap(self):
        self.device.features = Features({Feature.FN_INVERSION})
        self.device.persister = {"fn-swap": True}
        self.notify()
        self.clock.advance(60000)
        self.assertEqual(self.device.writes, [("fn-swap", True)])
        self.assertFalse(Path(self.daemon.DEVICES_PATH).exists())

    def test_valid_keys_without_solaar_settings_are_recorded(self):
        self.device.ready = True
        self.device.features = Features({Feature.REPROG_CONTROLS_V2})
        self.device.persister = {}
        self.notify()
        self.clock.advance(2000)
        self.assertTrue(Path(self.daemon.DEVICES_PATH).exists())
        inventory = self.inventory()["devices"][0]
        self.assertEqual(inventory["keys"], [{"cid": 266, "name": "Screen Capture", "divertable": True}])
        self.assertEqual(inventory["settings"], [])
        self.assertEqual(self.device.writes, [])

    def test_false_write_result_is_success_but_none_is_retried(self):
        self.device.ready = True
        self.device.fail_fn = True
        self.notify()
        self.clock.advance(2000)
        self.device.fail_fn = False
        self.clock.advance(60000)
        self.assertEqual(self.device.writes.count(("fn-swap", False)), 2)
        self.assertEqual(self.device.writes.count(("divert-keys", {266: 1})), 1)

    def test_ignored_saved_settings_are_not_replayed(self):
        self.device.ready = True
        self.device.persister["_sensitive"] = {"fn-swap": "ignore", "divert-keys": "ignore"}
        self.notify()
        self.clock.advance(60000)
        self.assertEqual(self.device.writes, [])

    def test_pending_settings_apply_after_saved_snapshot(self):
        self.device.ready = True
        pending = [{"device": "MX Keys Mini", "setting": "fn-swap", "values": ["true"]}]
        Path(self.daemon.PENDING_PATH).write_text(json.dumps(pending))
        self.notify()
        self.clock.advance(60000)
        self.assertEqual(self.device.writes, [("fn-swap", False), ("divert-keys", {266: 1}), ("fn-swap", True)])
        self.assertEqual(json.loads(Path(self.daemon.PENDING_PATH).read_text()), [])

    def test_pending_setting_missing_during_discovery_is_not_dropped(self):
        self.device.ready = True
        pending = [{"device": "MX Keys Mini", "setting": "not-ready", "values": ["true"]}]
        Path(self.daemon.PENDING_PATH).write_text(json.dumps(pending))
        self.notify()
        self.clock.advance(2000)
        self.assertEqual(json.loads(Path(self.daemon.PENDING_PATH).read_text()), pending)

    def test_receiver_notifications_are_ignored_without_online_attribute(self):
        self.daemon.status_changed(SimpleNamespace(kind=None))
        self.clock.advance(60000)
        self.assertEqual(self.device.writes, [])

    def test_reconnect_recovers_after_an_offline_timer_without_notification(self):
        self.notify()
        self.device.online = False
        self.clock.advance(2000)
        self.device.online = True
        self.device.ready = True
        self.notify()
        self.clock.advance(60000)
        self.assertEqual(self.device.writes, [("fn-swap", False), ("divert-keys", {266: 1})])

    def test_snapshot_copy_does_not_rewrite_saved_setting_values(self):
        self.device.ready = True
        writes = []

        class Entry(self.daemon.configuration._DeviceEntry):
            def __setitem__(self, name, value):
                writes.append(name)
                super().__setitem__(name, value)

        entry = Entry()
        dict.update(entry, self.device.persister)
        self.device.persister = entry
        with patch.object(self.daemon.configuration, "save"):
            self.notify()
            self.clock.advance(60000)
        self.assertNotIn("fn-swap", writes)
        self.assertNotIn("divert-keys", writes)

    def test_pending_setting_discovery_is_retried_after_inventory_is_recorded(self):
        self.device.ready = True
        self.device.features.remove(Feature.FN_INVERSION)
        del self.device.persister["fn-swap"]
        pending = [{"device": "MX Keys Mini", "setting": "fn-swap", "values": ["true"]}]
        Path(self.daemon.PENDING_PATH).write_text(json.dumps(pending))
        self.notify()
        self.clock.advance(2000)
        self.assertTrue(Path(self.daemon.DEVICES_PATH).exists())
        self.assertEqual(json.loads(Path(self.daemon.PENDING_PATH).read_text()), pending)
        self.device.features.add(Feature.FN_INVERSION)
        self.clock.advance(60000)
        self.assertEqual(self.device.writes, [("divert-keys", {266: 1}), ("fn-swap", True)])
        self.assertEqual(json.loads(Path(self.daemon.PENDING_PATH).read_text()), [])

    def test_failed_pending_write_is_kept_until_successful_retry(self):
        self.device.ready = True
        del self.device.persister["fn-swap"]
        self.device.fail_fn = True
        pending = [{"device": "MX Keys Mini", "setting": "fn-swap", "values": ["true"]}]
        Path(self.daemon.PENDING_PATH).write_text(json.dumps(pending))
        self.notify()
        self.clock.advance(2000)
        self.assertEqual(json.loads(Path(self.daemon.PENDING_PATH).read_text()), pending)
        self.device.fail_fn = False
        self.clock.advance(60000)
        self.assertEqual(self.device.writes, [("divert-keys", {266: 1}), ("fn-swap", True), ("fn-swap", True)])
        self.assertEqual(json.loads(Path(self.daemon.PENDING_PATH).read_text()), [])

    def test_lost_diversion_write_retries_despite_optimistic_cached_flags(self):
        self.device.ready = True
        self.device.diversion_flags = MappingFlag.PERSISTENTLY_DIVERTED
        self.assertEqual(self.device.key.mapping_flags, MappingFlag.PERSISTENTLY_DIVERTED)
        self.device.drop_diversion_write = True
        self.notify()
        self.clock.advance(2000)
        self.assertIn(MappingFlag.DIVERTED, self.device.key.mapping_flags)
        self.assertNotIn(MappingFlag.DIVERTED, self.device.diversion_flags)
        self.device.drop_diversion_write = False
        self.clock.advance(60000)
        self.assertIn(MappingFlag.DIVERTED, self.device.diversion_flags)
        self.assertEqual(self.device.writes.count(("divert-keys", {266: 1})), 2)

    def test_diversion_confirmation_timeout_retries_both_regular_and_diverted(self):
        for desired in (0, 1):
            with self.subTest(desired=desired):
                self.device = Device()
                self.device.ready = True
                self.device.persister["divert-keys"] = {266: desired}
                self.device.fail_diversion_read = True
                self.notify()
                self.clock.advance(2000)
                self.device.fail_diversion_read = False
                self.clock.advance(60000)
                self.assertEqual(self.device.writes.count(("divert-keys", {266: desired})), 2)

    def test_fn_swap_acknowledgement_without_state_change_retries(self):
        self.device.ready = True
        self.device.ignore_fn_write = True
        self.notify()
        self.clock.advance(2000)
        self.assertTrue(self.device.fn_value)
        self.device.ignore_fn_write = False
        self.clock.advance(60000)
        self.assertFalse(self.device.fn_value)
        self.assertEqual(self.device.writes.count(("fn-swap", False)), 2)

    def test_fn_swap_confirmation_timeout_does_not_fall_back_to_saved_value(self):
        self.device.ready = True
        self.device.fail_fn_read = True
        self.notify()
        self.clock.advance(2000)
        self.device.fail_fn_read = False
        self.clock.advance(60000)
        self.assertEqual(self.device.writes.count(("fn-swap", False)), 2)

    def test_pending_diversion_is_kept_until_fresh_confirmation(self):
        self.device.ready = True
        del self.device.persister["divert-keys"]
        self.device.drop_diversion_write = True
        pending = [{"device": "MX Keys Mini", "setting": "divert-keys", "values": ["266", "Diverted"]}]
        Path(self.daemon.PENDING_PATH).write_text(json.dumps(pending))
        self.notify()
        self.clock.advance(2000)
        self.assertEqual(json.loads(Path(self.daemon.PENDING_PATH).read_text()), pending)
        self.device.drop_diversion_write = False
        self.clock.advance(60000)
        self.assertIn(MappingFlag.DIVERTED, self.device.diversion_flags)
        self.assertEqual(json.loads(Path(self.daemon.PENDING_PATH).read_text()), [])


if __name__ == "__main__":
    unittest.main()

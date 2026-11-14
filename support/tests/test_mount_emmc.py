#!/usr/bin/env python3
"""Host-side mock tests for kvmcomm/scripts/mount_emmc.py (R16).

Run: python3 support/tests/test_mount_emmc.py
No device, dbus or root needed.
"""
import importlib.util
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "packages/kvmcomm/kvmcomm/scripts/mount_emmc.py"


class FakeManager:
    def __init__(self):
        self.calls = []

    def __getattr__(self, name):
        return lambda *a: self.calls.append((name, a))


def load(mgr):
    dbus = types.ModuleType("dbus")
    dbus.SystemBus = lambda: types.SimpleNamespace(get_object=lambda *a: None)
    dbus.Interface = lambda obj, iface: mgr
    sys.modules["dbus"] = dbus
    spec = importlib.util.spec_from_file_location("mount_emmc", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class MountEmmcTests(unittest.TestCase):
    def setUp(self):
        self.mgr = FakeManager()
        self.mod = load(self.mgr)
        self.tmp = tempfile.mkdtemp()
        self.img = os.path.join(self.tmp, "exfat.img")
        open(self.img, "w").close()
        self.mod.DEFAULT_IMAGE = self.img
        self.mod.DATA_DIR = os.path.join(self.tmp, "data")
        self.cmds = []
        self.mod.run = lambda cmd, check=True, timeout=None: self.cmds.append(cmd) or 0

    def export(self, backing):
        lun = os.path.join(self.tmp, "g0/functions/mass_storage.disk1/lun.0")
        os.makedirs(lun, exist_ok=True)
        with open(os.path.join(lun, "file"), "w") as f:
            f.write(backing + "\n")
        real_glob = self.mod.glob.glob
        self.mod.glob = types.SimpleNamespace(
            glob=lambda pat: real_glob(os.path.join(self.tmp, "g0/functions/mass_storage.*/lun.*/file")))

    def main(self, *argv):
        with mock.patch.object(sys, "argv", ["mount_emmc.py", *argv]):
            self.mod.main()

    def test_stop_does_not_check_free_space(self):
        with mock.patch.object(self.mod.subprocess, "run", side_effect=AssertionError("df called")):
            self.main("stop")
        self.assertIn(("StopUnit", ("data.mount", "replace")), self.mgr.calls)

    def test_start_when_exported_mounts_read_only(self):
        self.export(self.img)
        self.main("start", "--file", self.img)
        self.assertNotIn("StartUnit", [c[0] for c in self.mgr.calls])
        self.assertTrue(any(" -o ro," in c for c in self.cmds), self.cmds)

    def test_start_when_not_exported_uses_unit(self):
        self.main("start", "--file", self.img)
        self.assertIn(("StartUnit", ("data.mount", "replace")), self.mgr.calls)

    def test_remove_refuses_while_exported(self):
        self.export(self.img)
        with self.assertRaises(SystemExit) as cm:
            self.main("remove", "--file", self.img)
        self.assertEqual(cm.exception.code, 1)
        self.assertTrue(os.path.exists(self.img))

    def test_remove_when_not_exported(self):
        self.main("remove", "--file", self.img)
        self.assertFalse(os.path.exists(self.img))


if __name__ == "__main__":
    unittest.main()

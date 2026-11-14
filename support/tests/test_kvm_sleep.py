#!/usr/bin/env python3
"""Host-side mock tests for kvmcomm/scripts/kvm_sleep.py (R9, R10).

Run: python3 support/tests/test_kvm_sleep.py
Needs no device and no aiofiles; the proc files are a dict.
"""
import asyncio
import importlib.util
import os
import signal
import sys
import tempfile
import types
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "packages/kvmcomm/kvmcomm/scripts/kvm_sleep.py"

# Stub aiofiles before import; the tests replace the helpers that use it.
sys.modules.setdefault("aiofiles", types.ModuleType("aiofiles"))


def load():
    argv = sys.argv
    sys.argv = ["kvm_sleep.py", "--idle-timeout", "0"]
    try:
        spec = importlib.util.spec_from_file_location("kvm_sleep", SCRIPT)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
    finally:
        sys.argv = argv
    return mod


class FakeHw:
    def __init__(self, mod, **flags):
        self.flags = {"power": False, "hdmi_power": False, "loopout_power": False}
        self.flags.update(flags)
        self.fail = set()
        self.writes = []
        mod._read_flag = self.read
        mod._write_flag = self.write
        mod._read_on = lambda p: self.read(p)
        mod.wait_for_lt6911_ready = self.noop
        mod.wait_for_capture_signal = self.noop_true

    async def noop(self, *a):
        return True

    async def noop_true(self, *a):
        return True

    async def read(self, path):
        return self.flags.get(os.path.basename(path))

    async def write(self, path, on):
        name = os.path.basename(path)
        if name in self.fail:
            raise OSError(5, "I/O error", path)
        self.writes.append((name, on))
        self.flags[name] = on


class ControllerTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.mod = load()
        self.pc = self.mod.PowerController()

    async def asyncTearDown(self):
        await self.pc.stop()

    async def test_stale_cache_does_not_skip(self):
        hw = FakeHw(self.mod, power=False, hdmi_power=False)
        await self.pc.start(initial_state=True)  # cache says on, hardware is off
        await self.pc.set(True)
        self.assertTrue(hw.flags["power"])
        self.assertTrue(hw.flags["hdmi_power"])

    async def test_redundant_request_writes_nothing(self):
        hw = FakeHw(self.mod, power=True, hdmi_power=True)
        await self.pc.start()
        await self.pc.set(True)
        self.assertEqual(hw.writes, [])

    async def test_splitter_dropped_externally_is_raised(self):
        hw = FakeHw(self.mod, power=True, hdmi_power=False)
        await self.pc.start()
        await self.pc.set(True)
        self.assertEqual(hw.writes, [("hdmi_power", True)])

    async def test_write_error_propagates_and_is_retried(self):
        hw = FakeHw(self.mod, power=True, hdmi_power=True)
        hw.fail.add("power")
        await self.pc.start()
        with self.assertRaises(OSError):
            await self.pc.set(False)
        self.assertIs(self.pc.failed_target, False)
        self.assertIsNone(self.pc._current_state)
        hw.fail.clear()
        await self.pc.set(False)
        self.assertIsNone(self.pc.failed_target)
        self.assertFalse(hw.flags["power"])

    async def test_off_keeps_splitter_with_passthrough(self):
        hw = FakeHw(self.mod, power=True, hdmi_power=True, loopout_power=True)
        await self.pc.start()
        await self.pc.set(False)
        self.assertFalse(hw.flags["power"])
        self.assertTrue(hw.flags["hdmi_power"])


class SigtermTests(unittest.TestCase):
    def test_sigterm_while_asleep_powers_on(self):
        mod = load()
        hw = FakeHw(mod, power=True, hdmi_power=True)
        tmp = tempfile.mkdtemp()
        mod.SOCKET_PATH = os.path.join(tmp, "sock")

        async def no_wait(*a, **k):
            return True

        async def idle():
            return False

        mod.wait_for_driver_ready = no_wait
        mod.is_venc_working = idle
        mod.is_strip_working = idle

        async def scenario():
            task = asyncio.ensure_future(mod.main())
            for _ in range(50):
                await asyncio.sleep(0.01)
                if os.path.exists(mod.SOCKET_PATH):
                    break
            await mod.set_power(False)  # device goes to sleep
            self.assertFalse(hw.flags["power"])
            os.kill(os.getpid(), signal.SIGTERM)
            await asyncio.wait_for(task, 5)

        asyncio.run(scenario())
        self.assertTrue(hw.flags["power"])
        self.assertTrue(hw.flags["hdmi_power"])
        self.assertFalse(os.path.exists(mod.SOCKET_PATH))


if __name__ == "__main__":
    unittest.main()

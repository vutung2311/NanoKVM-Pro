#!/usr/bin/env python3
import os
import signal
import time
import fcntl
import asyncio
import aiofiles
import argparse
import logging
from typing import List, Tuple

parser = argparse.ArgumentParser()
parser.add_argument("--log-level", default="WARNING")
parser.add_argument(
    "--idle-timeout",
    type=float,
    default=30.0,
    help="Idle timeout in seconds before powering off HDMI (default: 30.0)",
)
args = parser.parse_args()

logging.basicConfig(
    level=getattr(logging, args.log_level.upper()),
    format='%(asctime)s [%(levelname)s] %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)
logger = logging.getLogger(__name__)

SOCKET_PATH = "/run/kvm/kvm_sleep_sock"

gstate = {
    "venc_act": False,
    "ui_ivps_act": False,
}
gstate_lock = asyncio.Lock()
_power_off_task: asyncio.Task | None = None


class SleepMsgType:
    venc_idle = 0
    venc_active = 1
    ui_ivps_idle = 2
    ui_ivps_active = 3


async def _write_flag(path: str, on: bool):
    # Errors propagate: the caller must not record a state the hardware never
    # reached. A proc write the driver rejects fails on close, which aiofiles
    # surfaces here as an OSError.
    async with aiofiles.open(path, "w") as f:
        await f.write("1" if on else "0")


async def set_lt86102_power(on: bool):
    path = "/proc/lt6911_info/hdmi_power"
    try:
        await _write_flag(path, on)
    except FileNotFoundError:
        # Older lt6911_manage builds have no splitter control.
        logger.warning(f"{path} does not exist")


async def set_lt6911_power(on: bool):
    await _write_flag("/proc/lt6911_info/power", on)


I2C_SLAVE_FORCE = 0x0706
I2C_DEV = "/dev/i2c-0"
LT6911_ADDR = 0x2b


async def wait_for_lt6911_ready(timeout_sec: float = 2.0) -> bool:
    """Poll LT6911 over I2C until its internal MCU ACKs and EDID RAM is ready."""
    loop = asyncio.get_running_loop()
    start = time.time()

    def probe_i2c() -> bool:
        try:
            fd = os.open(I2C_DEV, os.O_RDWR)
            try:
                fcntl.ioctl(fd, I2C_SLAVE_FORCE, LT6911_ADDR)
                os.write(fd, b"\x00")
                os.read(fd, 1)
                return True
            finally:
                os.close(fd)
        except OSError:
            return False

    while time.time() - start < timeout_sec:
        ready = await loop.run_in_executor(None, probe_i2c)
        if ready:
            # Allow internal MCU and EDID RAM to stabilize after power-on reset
            await asyncio.sleep(0.2)
            logger.info(f"LT6911 I2C and EDID ready in {(time.time() - start)*1000:.1f}ms")
            return True
        await asyncio.sleep(0.015)

    logger.warning("Timed out waiting for LT6911 I2C readiness")
    return False


async def wait_for_driver_ready(timeout_sec: float = 30.0) -> bool:
    """Wait for lt6911_manage kernel module to be fully loaded and operational."""
    start = time.time()
    initstate_path = "/sys/module/lt6911_manage/initstate"
    power_proc_path = "/proc/lt6911_info/power"

    logger.info("Waiting for lt6911_manage driver to be ready...")
    while time.time() - start < timeout_sec:
        try:
            if os.path.exists(initstate_path) and os.path.exists(power_proc_path):
                async with aiofiles.open(initstate_path, "r") as f:
                    content = (await f.read()).strip()
                    if content == "live":
                        logger.info("lt6911_manage driver is live and ready")
                        return True
        except Exception:
            pass
        await asyncio.sleep(0.5)

    logger.warning("Timed out waiting for lt6911_manage driver; proceeding anyway")
    return False


async def _read_flag(path: str) -> bool | None:
    """Read an on/off proc flag; None when it cannot be read."""
    try:
        async with aiofiles.open(path, "r") as f:
            content = await f.read()
        return content.strip() == "on"
    except Exception as e:
        logger.error(f"Failed to read {path}: {e}")
        return None


async def _read_on(path: str) -> bool:
    return bool(await _read_flag(path))


async def get_lt6911_power() -> bool:
    return await _read_on("/proc/lt6911_info/power")


async def get_lt86102_power() -> bool:
    return await _read_on("/proc/lt6911_info/hdmi_power")


async def is_passthrough_on() -> bool:
    """HDMI loop-out enabled: a monitor may be fed through the LT86102 splitter."""
    return await _read_on("/proc/lt6911_info/loopout_power")


async def wait_for_capture_signal(timeout_sec: float) -> bool:
    """Wait until the capture chip reports a locked input (non-zero width)."""
    start = time.time()
    while time.time() - start < timeout_sec:
        try:
            async with aiofiles.open("/proc/lt6911_info/width", "r") as f:
                if int((await f.read()).strip() or "0") > 0:
                    return True
        except (OSError, ValueError):
            pass
        await asyncio.sleep(0.1)
    return False


# How long a wake that keeps the splitter powered waits for the capture chip to
# lock before falling back to an HPD cycle (which makes the source re-train).
SOFT_WAKE_LOCK_TIMEOUT = 3.0

class PowerController:
    """
    管理对底层上/下电操作的请求队列，单个 worker 串行执行实际操作。
    set(on) 为调用者提供 await 语义：直到请求被处理（已应用或判定为冗余）才返回。
    """

    def __init__(self):
        self._queue: asyncio.Queue[Tuple[bool, asyncio.Future]] = asyncio.Queue()
        self._task: asyncio.Task | None = None
        self._current_state: bool | None = None  # None 表示未知（未初始化）
        self._stopping = False
        # Last target whose hardware write failed; None once one succeeds.
        self.failed_target: bool | None = None

    async def start(self, initial_state: bool | None = None):
        """启动 worker，可传入初始状态（如果已知）"""
        if initial_state is not None:
            self._current_state = initial_state
        if self._task is None:
            self._stopping = False
            self._task = asyncio.create_task(self._worker())
            logger.info(f"PowerController started (initial_state={initial_state})")

    async def stop(self):
        """优雅停止 worker"""
        self._stopping = True
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
            self._task = None
        # 使队列里未处理的 futures 失败返回，避免挂起 await
        while not self._queue.empty():
            try:
                _, fut = self._queue.get_nowait()
            except asyncio.QueueEmpty:
                break
            if not fut.done():
                fut.set_exception(
                    RuntimeError("PowerController stopped before handling request")
                )
        logger.info("PowerController stopped")

    async def set(self, on: bool):
        """
        请求设置电源到 on（True/False），等待直到该请求被 worker 处理（应用或跳过）。
        - 如果当前状态已等于 on，则立即返回（不会触发实际硬件操作）。
        - 如果队列中已有相同目标的未完成请求，则合并（共享结果）。
        """
        loop = asyncio.get_running_loop()
        fut = loop.create_future()
        await self._queue.put((on, fut))
        return await fut  # 等待 worker 完成该请求

    # 内部 worker：取出一个请求后，drain 队列以取最新目标并合并 futures，随后执行一次真实的设置操作。
    async def _worker(self):
        try:
            while True:
                desired, fut = await self._queue.get()  # 等待至少一个请求
                futures: List[asyncio.Future] = [fut]

                # Drain queue，合并成最后一个 desired，并收集所有 futures
                while not self._queue.empty():
                    try:
                        d, f = self._queue.get_nowait()
                    except asyncio.QueueEmpty:
                        break
                    desired = d
                    futures.append(f)
                # No short-circuit on _current_state: the Go server and
                # kvmcomm.sh write the same proc files, so the cache can be
                # stale. _do_set reads the hardware and skips redundant work.
                # 执行真实的上/下电操作（在这里调用你的硬件操作函数）
                try:
                    logger.info(f"Setting power={'ON' if desired else 'OFF'}")
                    # 调用实际的硬件接口函数：把原先的 set_power 的实现放到 _do_set 中
                    await self._do_set(desired)
                    self._current_state = desired
                    self.failed_target = None
                    for f in futures:
                        if not f.done():
                            f.set_result(None)
                except Exception as e:
                    # Remember the target so monitor_activity_loop retries it.
                    self._current_state = None
                    self.failed_target = desired
                    # 任何异常都要通知等待者
                    for f in futures:
                        if not f.done():
                            f.set_exception(e)
                    # 也记录错误然后继续循环
                    logger.error(f"Failed to set power: {e}")
                finally:
                    # mark queue tasks done if you used task_done elsewhere; here we don't call task_done
                    pass
                if self._stopping:
                    break
        except asyncio.CancelledError:
            # worker 被取消：把未完成 futures 都失败返回
            while not self._queue.empty():
                try:
                    _, fut = self._queue.get_nowait()
                except asyncio.QueueEmpty:
                    break
                if not fut.done():
                    fut.set_exception(RuntimeError("PowerController worker cancelled"))
            raise

    async def _do_set(self, on: bool):
        capture = await _read_flag("/proc/lt6911_info/power")
        splitter = await _read_flag("/proc/lt6911_info/hdmi_power")
        if on:
            if capture is True and splitter is not False:
                return
            if capture is True:
                # Capture chip is up but the splitter (HPD) was dropped by
                # another writer: raise it so the source drives the link.
                await set_lt86102_power(True)
                return
            if await get_lt86102_power():
                # Splitter stayed up for passthrough: power only the capture
                # chip so the loop-out monitor keeps its picture.
                await set_lt6911_power(True)
                await wait_for_lt6911_ready()
                if await wait_for_capture_signal(SOFT_WAKE_LOCK_TIMEOUT):
                    return
                logger.info("No capture lock after soft wake; cycling HPD")
            # HPD low while the capture chip comes up, then high so the source
            # re-reads EDID and re-trains the link.
            await set_lt86102_power(False)
            await set_lt6911_power(True)
            await wait_for_lt6911_ready()
            await set_lt86102_power(True)
        else:
            passthrough = await is_passthrough_on()
            if capture is False and (passthrough or splitter is not True):
                return
            if passthrough:
                # Keep the splitter (and the loop-out monitor) running; only
                # the capture chip and the SoC video-in pipeline go idle.
                await set_lt6911_power(False)
            else:
                await set_lt86102_power(False)
                await set_lt6911_power(False)
        return


_power_controller = PowerController()


async def set_power(on: bool):
    return await _power_controller.set(on)


async def try_set_power(on: bool):
    """set_power for event paths: a failure is logged, and the monitor loop
    retries it (PowerController.failed_target)."""
    try:
        await set_power(on)
    except Exception as e:
        logger.error(f"Power {'ON' if on else 'OFF'} failed, will retry: {e}")


async def is_venc_working() -> bool:
    path = "/proc/ax_proc/venc"
    try:
        async with aiofiles.open(path, "r") as f:
            content = await f.read()
        return "VENC CHN ATTR 1" in content
    except Exception:
        return False

async def is_strip_working() -> bool:
    path = "/etc/kvm/kvm_ui.toml"
    try:
        async with aiofiles.open(path, "r") as f:
            text = await f.read()
    except Exception as e:
        return False

    in_strip = False
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        if line.startswith('[') and line.endswith(']'):
            in_strip = line[1:-1].strip().lower() == 'strip'
            continue
        if not in_strip:
            continue
        if '=' not in line:
            continue
        key, val = line.split('=', 1)
        key = key.strip().lower()
        val = val.strip()
        if key == 'state':
            if (val.startswith('"') and val.endswith('"')) or (val.startswith("'") and val.endswith("'")):
                val = val[1:-1].strip()
            v = val.lower()
            if v == 'true':
                return True
            else:
                return False
    return False

async def _delayed_power_off(delay: float):
    global _power_off_task
    try:
        logger.info(f"Idle detected, power-off scheduled in {delay:.1f}s")
        await asyncio.sleep(delay)
        should_power_off = False
        async with gstate_lock:
            if not any(gstate.values()):
                should_power_off = True
                logger.info("Idle timeout expired, turning power OFF")
            else:
                logger.info("Activity resumed before idle timeout expired; power-off aborted")
        if should_power_off:
            await try_set_power(False)
    except asyncio.CancelledError:
        logger.info("Power-off cancelled due to resumed activity")
    finally:
        async with gstate_lock:
            if _power_off_task is asyncio.current_task():
                _power_off_task = None


async def update_state(key: str, value: bool):
    global _power_off_task
    action = None  # None, "power_on", "power_off", or ("schedule_off", delay)
    async with gstate_lock:
        if gstate[key] == value:
            return
        gstate[key] = value
        need_active = any(gstate.values())
        logger.info(f"State changed: {key}={value}, need_power={'ON' if need_active else 'OFF'}")

        if need_active:
            if _power_off_task and not _power_off_task.done():
                _power_off_task.cancel()
                _power_off_task = None
            action = "power_on"
        else:
            if _power_off_task is None or _power_off_task.done():
                if args.idle_timeout > 0:
                    action = ("schedule_off", args.idle_timeout)
                else:
                    action = "power_off"

    if action == "power_on":
        await try_set_power(True)
    elif action == "power_off":
        await try_set_power(False)
    elif isinstance(action, tuple) and action[0] == "schedule_off":
        _power_off_task = asyncio.create_task(_delayed_power_off(action[1]))


async def handle_client(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
    data = await reader.read(1024)
    if not data:
        writer.close()
        await writer.wait_closed()
        return

    for b in data:
        if b == SleepMsgType.venc_idle:
            await update_state("venc_act", False)
        elif b == SleepMsgType.venc_active:
            await update_state("venc_act", True)
        elif b == SleepMsgType.ui_ivps_idle:
            await update_state("ui_ivps_act", False)
        elif b == SleepMsgType.ui_ivps_active:
            await update_state("ui_ivps_act", True)
        else:
            logger.warning(f"Received unknown message: {b}")

    writer.close()
    await writer.wait_closed()


async def monitor_activity_loop():
    """
    Periodically check video encoding pipeline (venc) and UI state.
    Provides a 60-second grace period on boot to allow host display negotiation.
    """
    global _power_off_task
    await asyncio.sleep(60)
    # The idle timer is otherwise armed only on an active->idle transition, so
    # a device nobody has viewed since boot would stay powered forever.
    async with gstate_lock:
        if not any(gstate.values()) and (_power_off_task is None or _power_off_task.done()):
            _power_off_task = asyncio.create_task(_delayed_power_off(max(args.idle_timeout, 0)))
    while True:
        try:
            if _power_controller.failed_target is not None:
                target = _power_controller.failed_target
                logger.info(f"Retrying failed power={'ON' if target else 'OFF'}")
                async with gstate_lock:
                    # Skip a stale OFF retry once activity has resumed.
                    stale = (not target) and any(gstate.values())
                if stale:
                    _power_controller.failed_target = None
                else:
                    await set_power(target)
            venc = await is_venc_working()
            ui = await is_strip_working()
            if venc != gstate["venc_act"]:
                await update_state("venc_act", venc)
            if ui != gstate["ui_ivps_act"]:
                await update_state("ui_ivps_act", ui)
        except asyncio.CancelledError:
            break
        except Exception as e:
            logger.debug(f"Error in monitor_activity_loop: {e}")
        await asyncio.sleep(3)


# Upper bound for the power-on on exit; systemd's stop timeout is longer, and
# kvm-sleep.service's ExecStopPost is the backstop if this is cut short.
EXIT_POWER_ON_TIMEOUT = 10.0


def _install_signal_handlers(main_task: asyncio.Task):
    """Turn SIGTERM/SIGINT into a cancel of main() so its finally runs.

    Without this, `systemctl stop kvm-sleep` while asleep killed Python
    before the power-on in finally, leaving the capture chip off.
    """
    loop = asyncio.get_running_loop()

    def _on_signal(signame: str):
        logger.info(f"Received {signame}, shutting down")
        main_task.cancel()

    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, _on_signal, sig.name)


async def main():
    _install_signal_handlers(asyncio.current_task())

    server = None
    monitor_task = None
    try:
        os.makedirs(os.path.dirname(SOCKET_PATH), exist_ok=True)
        if os.path.exists(SOCKET_PATH):
            os.remove(SOCKET_PATH)

        server = await asyncio.start_unix_server(handle_client, path=SOCKET_PATH)
        logger.info(f"Server started on {SOCKET_PATH}")

        # Ensure lt6911_manage kernel module has completed initialization
        await wait_for_driver_ready()

        gstate["venc_act"] = await is_venc_working()
        gstate["ui_ivps_act"] = await is_strip_working()
        logger.info(f"Initial state: venc_act={gstate['venc_act']}, ui_ivps_act={gstate['ui_ivps_act']}")

        await _power_controller.start(initial_state=await _read_flag("/proc/lt6911_info/power"))

        # Keep HDMI powered on at startup so host GPU detects monitor and establishes link
        try:
            await set_power(True)
        except Exception as e:
            logger.error(f"Initial power-on failed: {e}")

        monitor_task = asyncio.create_task(monitor_activity_loop())

        async with server:
            await server.serve_forever()
    except asyncio.CancelledError:
        pass
    finally:
        if monitor_task:
            monitor_task.cancel()
        if _power_off_task and not _power_off_task.done():
            _power_off_task.cancel()
            try:
                await _power_off_task
            except asyncio.CancelledError:
                pass
        if monitor_task:
            try:
                await monitor_task
            except asyncio.CancelledError:
                pass
        if server is not None:
            server.close()

        # Bypass the queue: the worker may never have started (signal during
        # startup) or may be mid-request.
        await _power_controller.stop()
        try:
            await asyncio.wait_for(_power_controller._do_set(True), EXIT_POWER_ON_TIMEOUT)
        except Exception as e:
            logger.error(f"Power-on at exit failed: {e}")

        if os.path.exists(SOCKET_PATH):
            os.remove(SOCKET_PATH)

        logger.info("Server stopped, socket cleaned")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass

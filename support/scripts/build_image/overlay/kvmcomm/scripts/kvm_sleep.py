#!/usr/bin/env python3
import os
import asyncio
import aiofiles
import argparse
import logging
from typing import List, Tuple

parser = argparse.ArgumentParser()
parser.add_argument("--log-level", default="WARNING")
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


class SleepMsgType:
    venc_idle = 0
    venc_active = 1
    ui_ivps_idle = 2
    ui_ivps_active = 3


async def set_lt86102_power(on: bool):
    path = "/proc/lt6911_info/hdmi_power"
    try:
        async with aiofiles.open(path, "w") as f:
            await f.write("1" if on else "0")
    except FileNotFoundError:
        logger.warning(f"{path} does not exist")
    except Exception as e:
        logger.error(f"Failed to write {path}: {e}")


async def set_lt6911_power(on: bool):
    path = "/proc/lt6911_info/power"
    try:
        async with aiofiles.open(path, "w") as f:
            await f.write("1" if on else "0")
    except Exception as e:
        logger.error(f"Failed to write {path}: {e}")


async def get_lt6911_power() -> bool:
    path = "/proc/lt6911_info/power"
    try:
        async with aiofiles.open(path, "r") as f:
            content = await f.read()
        return content.strip() == "on"
    except Exception as e:
        logger.error(f"Failed to read {path}: {e}")
        return False

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
                # 如果当前已知状态等于 desired，则直接完成所有 futures
                if self._current_state is not None and self._current_state == desired:
                    for f in futures:
                        if not f.done():
                            f.set_result(None)
                    continue

                # 执行真实的上/下电操作（在这里调用你的硬件操作函数）
                try:
                    logger.info(f"Setting power={'ON' if desired else 'OFF'}")
                    # 调用实际的硬件接口函数：把原先的 set_power 的实现放到 _do_set 中
                    await self._do_set(desired)
                    self._current_state = desired
                    for f in futures:
                        if not f.done():
                            f.set_result(None)
                except Exception as e:
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
        if (await get_lt6911_power()) == on:
            return
        await (set_lt6911_power(True) if on else set_lt86102_power(False))
        await (set_lt86102_power(False) if on else set_lt6911_power(False))
        await asyncio.sleep(0.1)
        await set_lt86102_power(True)
        return


_power_controller = PowerController()


async def set_power(on: bool):
    return await _power_controller.set(on)


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

async def update_state(key: str, value: bool):
    need_active = False
    async with gstate_lock:
        if gstate[key] == value:
            return
        gstate[key] = value
        need_active = any(gstate.values())
        logger.info(f"State changed: {key}={value}, need_power={'ON' if need_active else 'OFF'}")

    await set_power(need_active)


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


async def main():
    os.makedirs(os.path.dirname(SOCKET_PATH), exist_ok=True)
    if os.path.exists(SOCKET_PATH):
        os.remove(SOCKET_PATH)

    server = await asyncio.start_unix_server(handle_client, path=SOCKET_PATH)
    logger.info(f"Server started on {SOCKET_PATH}")

    gstate["venc_act"] = await is_venc_working()
    gstate["ui_ivps_act"] = await is_strip_working()
    need_power_on = any(gstate.values())
    logger.info(f"Initial state: venc_act={gstate['venc_act']}, ui_ivps_act={gstate['ui_ivps_act']}")

    await _power_controller.start(initial_state=await get_lt6911_power())

    if not need_power_on:
        logger.info("No activity detected, setting power to OFF")
        await set_power(False)

    try:
        async with server:
            await server.serve_forever()
    except asyncio.CancelledError:
        pass
    except KeyboardInterrupt:
        logger.info("Exit requested by user")
    finally:
        await set_power(True)

        if os.path.exists(SOCKET_PATH):
            os.remove(SOCKET_PATH)

        logger.info("Server stopped, socket cleaned")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass

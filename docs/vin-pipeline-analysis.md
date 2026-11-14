# VIN → IVPS → VENC pipeline: per-frame work analysis

Static reverse engineering of the two closed binaries that drive the AX630C video
pipeline, aimed at finding per-frame SoC work that can be cut without lowering
stream quality.

| Binary | SHA-256 | Notes |
|---|---|---|
| `support/packages/kvmcomm/kvmcomm/vin/kvm_vin` | `aa38eb22…bee618` | aarch64 ET_EXEC, stripped, base `0x400000`. **C++** (toml++, spdlog/fmt, nlohmann::json), not Rust. |
| `support/packages/nanokvmpro/kvmapp/server/dl_lib/libkvm.so.0.1.0` | `306a9ec5…3ddd0c` | aarch64 DSO, **not stripped** (local symbols such as `us_ax_set_fps` and `lt6911_thread_func`). Built from `…/libkvm/source/exlib/ax/src/encoder.c` plus a C++ `kvmimpl.cpp`. |

**Method and limits.** REA's deep providers were unavailable on this host.
Ghidra 12.2 with JDK 21 is installed, but REA requires 12.1.x with JDK 25+.
Hopper, IDA and Kuna are not configured. The analysis therefore uses
`llvm-objdump` disassembly, with a small script that resolves `adrp`/`add`
string references, cross-checked by hand. Struct offsets are decoded against the
SDK headers in `support/sdk/msp/out/arm64_glibc/include` and the SDK samples.
Everything below is static: nothing was run on a device. Where a claim depends
on driver behaviour that the binaries cannot show, it is marked **(inference)**.

---

## Pipeline as built

```
LT6911 ──MIPI CSI (DT 0x1E YUV422-8)──► MIPI RX ──► VIN dev0 (ONLINE, FRC 1:1)
   ──► VIN pipe0 (ISP_BYPASS_MODE, FRC off) ──► VIN chn0 (NV12, W×H, FRC off)
          ├──AX_SYS_Link (kvm_vin)──► IVPS grp0 ─ filter TDP ─► chn0 320×172 RGB565 @ input fps ──► kvm_ui (LCD)
          └──AX_SYS_Link (libkvm) ──► VENC chn {MJPEG|H264|H265}  (RC src=input fps, dst=user fps)
```

libkvm does **not** use IVPS. It links VIN chn0 straight to VENC. IVPS exists
only to feed the on-device 320×172 LCD preview.

---

## Q1: Where `fSrcFrameRate` / `fDstFrameRate` are set

**kvm_vin.** The main VIN setup function starts near `0x4275fc`. All three
VIN-level rate controllers are "no drop":

| Object | Evidence | Value |
|---|---|---|
| `AX_VIN_DEV_ATTR_T.tFrameRateCtrl` (offset `0x7c`) | `0x4278a8 mov x0,#0x3f8000003f80; stur x0,[sp+0x23e]` writes `0x3f800000` at `sp+0x23c` and `sp+0x240` | `{1.0, 1.0}`, the same as SDK `common_config.h:57` (ratio 1:1). This is the struct printed by the `tFrameRateCtrl.fSrcFrameRate:` log line at `0x4279d4`. |
| `AX_VIN_PIPE_ATTR_T.tFrameRateCtrl` (offset `0x50`) | `0x427c84` memsets the 0x68 bytes after the first field. Only `ePipeWorkMode`, the region, the stride, the Bayer pattern, `ePixelFmt` and `eSnsMode` are written afterwards. | `{0, 0}` = `AX_INVALID_FRMRATE` (FRC off) |
| `AX_VIN_CHN_ATTR_T.tFrameRateCtrl` (offset `0x24`) | `0x427f38 stp xzr,xzr,[sp+0xdc]` zeroes `tCompressInfo` and `tFrameRateCtrl` | `{0, 0}` (FRC off) |
| IVPS `tFilter[0][0].tFRC` | `0x424354 ldr s0,[x19,#0x38]; scvtf; 0x424378 stp s0,s0,[sp+0x70]` | `{fps, fps}`, where `fps` is the input rate from LT6911 (no reduction) |

`x19+0x38` is the global VIN context at `0x4d0d68`. Its `+0x30/+0x34/+0x38`
fields hold width, height and fps. They default to 1920×1080@60
(`0x409118`–`0x409128`) and are rewritten on a resolution change
(`0x416c38`–`0x416c40`) before a full deinit and reinit:
`0x425f58` deinit → `0x4277e4` VIN init → `0x42427c` IVPS init → `0x424518` link.

**libkvm.** Frame rate control happens only in VENC:

- `us_ax_set_fps(enc, chn, src, dst)` at `0x6ad00` calls
  `AX_VENC_GetRcParam(chn, &rc)`, then sets `rc.stFrameRate.fSrcFrameRate = src`
  (`sp+0x78` = struct offset `0x18`) and
  `rc.stFrameRate.fDstFrameRate = min(dst, src)` (offset `0x1c`), then calls
  `AX_VENC_SetRcParam`. Those offsets match `AX_VENC_RC_PARAM_T` in
  `ax_venc_rc.h:421`.
- `kvmv_set_fps(fps)` at `0x5c130` calls `us_ax_set_fps(enc, ch, 0, fps)` for
  all three channel ids (`enc+0x14`/`+0x18`/`+0x1c`). With `src=0` the existing
  source rate is kept.
- At channel creation, src comes from `/proc/lt6911_info/fps` (default 30) and
  dst is the user fps (`0x64680`–`0x647a8`: `param+0xc = src`,
  `param+0x10 = dst ?: src`). Both are written into the channel attributes as a
  float pair at `0x65098`.
- On a vin_sock `res_change` message (`lt6911_thread_func` at `0x62f24`–`0x62f80`),
  libkvm calls `us_ax_set_resolution` and `us_ax_set_fps(chn, msg.fps, user_fps)`
  for each of the three channels.

**Answer.** The destination rate is tied to the input fps at VIN and IVPS, so
nothing is dropped there. It equals the user fps only at VENC. Neither vin_sock
(one-way, see Q5) nor libkvm can change the VIN or IVPS rates.

## Q2: HDMI at 60 Hz with `kvmv_set_fps(30)`: where frames are dropped

**Only at VENC.** All of the following run at the full input rate (60 fps):

1. MIPI RX and VIN dev, with FRC 1:1.
2. VIN pipe0 in ISP_BYPASS mode, which converts YUV422 to NV12 and writes a
   1080p NV12 frame (~3.1 MB) to DDR every frame. That is about
   **187 MB/s of DDR writes**.
3. IVPS grp0 TDP. It reads every 1080p NV12 frame (~187 MB/s) and scales it to
   320×172 RGB565, with FRC src=dst=input fps.
4. The VENC link delivers 60 frames per second to the one enabled channel. The
   VENC rate control drops every second frame before encoding **(inference: the
   drop happens before the encoder fetches the frame, so the dropped frames cost
   only link and queue work)**.

## Q3: Is the ISP doing real work?

The ISP is configured as close to bypass as the SDK allows:

- `AX_VIN_PIPE_ATTR_T.ePipeWorkMode = 12` (`0x427c94 mov w0,#0xc; str w0,[sp+0x150]`),
  which is `AX_VIN_PIPE_ISP_BYPASS_MODE` ("bypass ISP iq module").
  `ePixelFmt = 0x84` (`AX_FORMAT_BAYER_RAW_16BPP`, YUYV carried as 16-bit raw),
  `eBayerPattern = 3`, `eSnsMode = 5`. The dev attributes match:
  `bImgDataEnable = 1`, `ePixelFmt = 0x84`, MIPI `szImgDt[0] = 0x1E`
  (YUV422 8-bit, `0x4278b8`), `eDevMode = ONLINE`, and
  `nConvYuv422To420En = 0` (the 422→420 conversion is done by the channel, not
  the dev).
- The ISP still goes through its full lifecycle against a dummy sensor:
  `dlopen("/opt/lib/libsns_dummy.so")` → `dlsym("gSnsdummyObj")` →
  `AX_ISP_RegisterSensor` → `AX_ISP_SetSnsAttr` (W×H, `fFrameRate = 60.0`
  (`0x42700000`), `eSnsMode = 5`, raw type `0x10`, Bayer 3; see `0x427e30`) →
  `AX_ISP_Create` / `AX_ISP_Open` / `AX_ISP_Start` / `AX_ISP_StreamOn`.
- **No 3A algorithm is registered.** Neither binary imports any
  `AX_ISP_ALGO_*Register`, `AX_ISP_Set*Attr` IQ calls, or anything from
  `libax_ae`, `libax_awb` or `libax_af`. Those libraries are pulled in only by
  `DT_NEEDED`, so they cost load time and RSS, not per-frame work.
- The channel output is NV12 (`AX_VIN_CHN_ATTR_T.eImgFormat = 3`,
  `nDepth = 1`, `0x427f20`). The 422→420 conversion and the DDR write are real
  per-frame work, and VENC needs NV12 anyway.

**Answer.** No camera IQ processing is done, apart from whatever per-frame
bookkeeping the ISP driver does in bypass mode once `AX_ISP_Start` has been
called **(inference; not measurable statically)**. The only ISP-side lever is
dropping frames before the pipe, which is covered under Q2 and in change 2.

## Q4: IVPS resolutions, formats, channels, and client dependence

From `0x42427c` (`AX_IVPS_PIPELINE_ATTR_T` at `sp+0x58`):

- Group 0 (`AX_IVPS_CreateGrp` with `nInFifoDepth = 1`, `ePipeline = DEFAULT`) has
  `nOutChnNum = 1` and `nOutFifoDepth[0] = 1`.
- `tFilter[0][0]` (pipe-0 filter at `+0x10`): `bEngage = 1`, `eEngine = 1`
  (`AX_IVPS_ENGINE_TDP`), `tFRC = {fps, fps}`, no crop,
  `nDstPicWidth = 320`, `nDstPicHeight = 172`, `nDstPicStride = 320`,
  `eDstPicFormat = 0xA0` (`AX_FORMAT_RGB565`). See `0x424344`–`0x424368`.
- The group pool comes from a user pool (`ePoolSrc = 2`, `PoolId = ctx+0x3c`,
  the `"ivps_pool"` created at `0x425060`), as does channel 0.
- One channel only, enabled once (`0x42445c`). `AX_IVPS_DisableChn` is called
  only from the teardown paths (`0x4246c0`, `0x424718`).
- The consumer is `kvmcomm/ui/kvm_ui`, which imports only
  `AX_IVPS_GetChnFrame` / `AX_IVPS_ReleaseChnFrame` (strings:
  `WindowLivePreview`, `ScreenOff`, `oled.sleep`).

**Answer.** The IVPS channel runs at the full input fps whether or not anyone
watches the LCD preview, whether the LCD is asleep, and whether a stream client
is connected. kvm_vin has no input that would tell it otherwise. When the FIFO
is full (depth 1) **(inference)** the newest frame overwrites the oldest after
the TDP has already done the scaling.

## Q5: The vin_sock protocol

- **kvm_vin is the server.** It binds `/run/kvm/vin_sock` and runs an
  `epoll_wait(…, 10, 200 ms)` loop (`0x4137fc`) that only `accept()`s
  (`0x413778`, "Accepted new connection"). kvm_vin imports no `recv`, and its
  only `read()` calls outside libc++/fmt are on `/proc/lt6911_info/status`
  (`0x416404`, `0x416598`). **Nothing coming from clients is parsed.**
- It sends exactly one message type (`send_json_message`, `send()` at `0x4293c8`):
  `{"type":"res_change","width":W,"height":H,"fps":F}`, which is built at
  `0x4299ac` and `0x416cac`. It sends this after every resolution change once
  the full pipeline restart has finished.
- **libkvm is a client** (`lt6911_thread_func`, `0x6272c`). It runs
  `connect("/run/kvm/vin_sock")` with a 1 s retry (`0x62a40`), an
  `epoll_wait(…, -1)` (`0x62c24`, blocking), an exit eventfd, `recv` and
  nlohmann JSON parsing. For `res_change` it calls `us_ax_set_resolution` and
  `us_ax_set_fps` on each of the three VENC channels, then re-enables the
  selected stream.

**Answer.** The protocol only carries notifications from kvm_vin to libkvm.
libkvm cannot use it to start or stop the pipeline or to change its rates.

## Q6: Polling and busy loops

| Where | Mechanism | Wakeups |
|---|---|---|
| kvm_vin socket server | `epoll_wait(200 ms)` (`0x4137fc`) | 5/s, always |
| kvm_vin LT6911 thread | `epoll_wait(2000 ms)` on `/proc/lt6911_info/status`, then `lseek`+`read` (`0x416504`–`0x416598`); `sleep_for(500 ms)` and `sleep_for(1 s)` while settling | ≤0.5/s when idle |
| kvm_vin `AX_VIN_GetYuvFrame` | Called only from the CLI "Dump one YUYV422 frame" path (`0x409454` → `0x426ec0`); `SetChnFrameMode(OFF)` at `0x427f98` | none in normal operation |
| libkvm `start_kvm_monitor` | `sleep_for(1 s)` loop (`0x4db34`). If more than 5000 ms pass without `kvmv_read_img`, it calls `us_ax_disable_all_stream` and `us_ax_encoder_destroy` (UnLink, StopRecv, DestroyChn, `AX_VENC_Deinit`, `AX_SYS_Deinit`), then sends `sleep_msg 0` to `/run/kvm/kvm_sleep_sock` | 1/s |
| libkvm `us_ax_get_{h264,h265,mjpeg}_frame` | Blocking `AX_VENC_GetStream`; the timeout is 1000 ms if `1000/fps > 300`, otherwise 300 ms (`0x6836c`–`0x68390`) | event-driven |
| libkvm vin_sock client | `epoll_wait(-1)` | event-driven |
| libkvm `sleep_notifier` | condvar wait; `sleep_for` only on reconnect backoff | event-driven |
| `us_ax_encoder_destroy` | `usleep` retry loop on `AX_ERR_VENC_BUSY` around `AX_VENC_DestroyChn` (`0x6c0d4`, …) | teardown only |

There are no busy loops. Idle wakeups add up to about 6 per second, which is
negligible next to the per-frame hardware work.

### Encoder lifecycle (libkvm)

The encoder is created lazily on the first `kvmv_read_img` (`0x5c388`). All
three VENC channels (MJPEG, H264, H265) are created and linked VIN→VENC
(`0x6588c`, `0x65a38`, `0x65b7c`). Then `us_ax_disable_all_stream` runs, and
only the requested codec is re-enabled with `AX_VENC_StartRecvFrame`
(`0x5c434`–`0x5c44c`), so one encoder is active. Switching codec repeats
disable-all followed by enabling the new codec. Five seconds after the last read
the whole VENC side is torn down. **VIN and IVPS are never stopped.**

---

## Ranked changes (most SoC work saved first, none lower stream quality)

1. **Cut the LCD-preview IVPS rate, and stop it when it isn't shown.**
   The TDP reads a full 1080p NV12 frame at 60 fps (about 187 MB/s of DDR
   reads, plus TDP engine time) to feed a 320×172 panel. That runs even with
   the screen asleep, on another page, or with no one near the device.
   - Quick fix: set `tFilter[0][0].tFRC.fDstFrameRate` to 10–15 (or the
     channel's `AX_IVPS_CHN_ATTR_T.tFRC`) while leaving `fSrcFrameRate` at the
     input fps. This takes the cost from 60 to 10–15 TDP passes per second.
     - How: rebuild kvm_vin against the SDK, which is the cleanest option, or
       binary-patch the `stp s0,s0,[sp,#0x70]` at `0x424378` so that `dst` gets
       a constant.
   - Full fix: let kvm_ui gate the channel with
     `AX_IVPS_DisableChn/EnableChn(0,0)` or `AX_IVPS_StopGrp/StartGrp`
     whenever `WindowLivePreview` is not visible or `ScreenOff` is active.
     - How: kvm_ui already links `libax_ivps`, so it could make the calls
       itself **(inference: MSP objects are driver-global and may be
       controlled cross-process; verify on a bench)**. Alternatively, kvm_vin
       could accept a command on `vin_sock`, which needs a kvm_vin rebuild
       because the current binary never reads from clients.
   - **Expected gain:** large. Of the per-frame work that has no effect on the
     stream, this is the biggest share.

2. **Drop frames at VIN when the stream fps is below the input fps.**
   Set the frame rate on `AX_VIN_PIPE_ATTR_T.tFrameRateCtrl` (pipe-level, as
   the SDK `uvc_gadget.c:1456` sample does) or on
   `AX_VIN_CHN_ATTR_T.tFrameRateCtrl` to `{src: input fps, dst: stream fps}`.
   With a 60 Hz input and a 30 fps stream, this halves the ISP-bypass,
   422→420 and NV12 DDR writes (about 93 MB/s saved), the link and queue
   traffic, and the IVPS input. VENC then receives exactly the frames it would
   have encoded anyway, so the encoded stream is the same.
   - Constraints: VIN output fans out to both VENC and IVPS, so this only
     works if the LCD preview rate is at or below the stream rate, which
     change 1 provides. A stream fps change must also reach kvm_vin, and today
     no channel exists for that.
   - How: one route is for a replacement libkvm `kvmv_set_fps` to call
     `AX_VIN_GetChnAttr/SetChnAttr(0, 0, …)` itself **(inference: allowed
     cross-process; the same caveat as change 1)**. The other is for kvm_vin
     to accept a "set_fps" JSON on vin_sock, which needs a rebuild.
     `/proc/lt6911_info/fps` must stay the true input rate, because both
     binaries treat it as the source fps.
   - **Expected gain:** large when the stream fps is below the input fps; zero
     when they match.

3. **Idle downshift when no stream client is connected.**
   After libkvm tears down VENC (5 s with no reads), VIN and IVPS keep running
   at 60 fps solely for the LCD. If the LCD is also off or not showing the
   preview, VIN can be stopped entirely: `AX_VIN_DisableChn` or `StopPipe`, or
   a pipe FRC of about 1 fps for change detection.
   - How: libkvm already emits `sleep_msg 0/1` on `/run/kvm/kvm_sleep_sock`
     when VENC is destroyed or created. The sleep manager (`kvm_sleep.py`)
     could forward that, together with the kvm_ui screen state, to kvm_vin.
     That requires a kvm_vin rebuild, since there is no inbound path today.
   - **Expected gain:** all VIN and IVPS work while idle and the screen is off.

4. **Skip the unused VENC channels at init.** libkvm creates all three VENC
   channels and starts receiving on all of them, then immediately disables
   two. Creating only the requested codec saves VENC memory (bitstream
   buffers) and a short startup burst. There is no steady-state per-frame
   gain, because only one channel receives frames.
   - How: requires a replacement libkvm. `kvmimpl.cpp` is a stub, and the
     binary has symbols, which makes it a practical base to reimplement.

5. **Minor items.**
   - Use the input fps rather than a hard-coded 60.0 for
     `AX_ISP_SetSnsAttr.fFrameRate`.
   - Consider `AX_VIN_PIPE_SUB_YUV_MODE` (10) instead of ISP_BYPASS (12),
     which the SDK documents as "bypass IFE, bypass ITP Raw/RGB domain".
     Treat this as a bench experiment: the SDK samples use BYPASS for YUV
     sources, and the gain is unproven.
   - Raise the kvm_vin accept-loop `epoll_wait` from 200 ms to `-1`. It only
     waits on the listen fd and the stop flag.
   - Drop the `libax_ae/af/awb` `DT_NEEDED` entries, which saves RSS only.

### What is already efficient

- No CPU frame copies: all paths are hardware links (`AX_SYS_Link`) or
  blocking `GetStream`/`GetChnFrame` calls.
- No 3A algorithms run.
- Only one VENC encoder is active at a time, and VENC is fully released 5 s
  after the last client read.
- The VENC rate control drop means the encoder engine does exactly
  stream-fps work.

## Open items (need a bench, not more static work)

- Measure the actual savings from changes 1 and 2 with per-engine load
  counters: `/proc/ax_proc/` IVPS, VIN and VENC status and DDR bandwidth.
- Confirm that a second process may call `AX_IVPS_*Chn` and
  `AX_VIN_SetChnAttr` on objects created by kvm_vin.
- Confirm what `AX_ISP_Start` does per frame in ISP_BYPASS mode with a dummy
  sensor.

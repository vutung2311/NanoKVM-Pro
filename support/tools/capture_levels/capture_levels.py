#!/usr/bin/env python3
"""Measure the luma levels the KVM captures of a grey test pattern.

1. On the target machine, open pattern.html full screen (F11).
2. In the NanoKVM web UI, switch the video mode to MJPEG and save one frame
   (right-click the picture -> Save image).
3. On this machine (needs ffmpeg):

       python3 capture_levels.py frame.jpg

Do not use `kvm_vin --dump-raw` while the kvm_vin service runs: a second
instance taking the capture hardware can reboot the device.

For each of the pattern's nine grey bands the script prints the captured Y
next to what a full-range (0-255) and a limited-range (16-235) capture give.
The shape of a mismatch tells the cause apart:

  - matches "limited" or "full": the capture is right
  - every band low by the same ratio, white well under 235: the target dims
    its output (e.g. KDE's software dimming on an output without backlight)
  - black and the first bands all equal: shadows clipped (range expanded twice)
"""
import subprocess
import sys

LEVELS = [0, 32, 64, 96, 128, 160, 192, 224, 255]


def luma_plane(path):
    """Decode the JPEG's Y plane as is, without any range conversion."""
    probe = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0",
         "-show_entries", "stream=width,height", "-of", "csv=p=0", path],
        check=True, capture_output=True, text=True)
    w, h = (int(v) for v in probe.stdout.strip().split(","))
    y = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", path, "-vf", "extractplanes=y",
         "-f", "rawvideo", "-pix_fmt", "gray", "-"],
        check=True, capture_output=True).stdout
    if len(y) != w * h:
        sys.exit(f"decoded {len(y)} bytes, expected {w}x{h}")
    return y, w, h


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    y, w, h = luma_plane(sys.argv[1])
    band = w / len(LEVELS)
    print(f"{w}x{h}")
    print(" grey | captured Y (min..max) | full | limited")
    for i, v in enumerate(LEVELS):
        # Middle 40% of each band, middle third of the rows: clear of edges.
        x0, x1 = int(band * (i + 0.3)), int(band * (i + 0.7))
        vals = sorted(y[r * w + x] for r in range(h // 3, 2 * h // 3, 8)
                      for x in range(x0, x1, 4))
        med = vals[len(vals) // 2]
        lim = round(16 + v * 219 / 255)
        print(f" {v:4d} | {med:4d} ({vals[0]:3d}..{vals[-1]:3d})      | {v:4d} | {lim:4d}")


if __name__ == "__main__":
    main()

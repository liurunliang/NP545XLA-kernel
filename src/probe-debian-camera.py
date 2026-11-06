#!/usr/bin/env python3
"""Decode a timed 720p stream from the internal Samsung USB camera without saving images."""
import argparse
import json
import re
import subprocess
from fractions import Fraction
from pathlib import Path


def capture_node():
    for node in sorted(Path("/sys/class/video4linux").glob("video*")):
        for parent in node.resolve().parents:
            if not (parent / "idVendor").is_file():
                continue
            if ((parent / "idVendor").read_text().strip(),
                (parent / "idProduct").read_text().strip()) != ("04f2", "b72f"):
                break
            path = "/dev/" + node.name
            modes = subprocess.check_output(["v4l2-ctl", "-d", path, "--list-formats-ext"], text=True)
            # Ignore metadata interfaces and only request a mode advertised at native 720p.
            for fourcc, fmt in (("MJPG", "mjpeg"), ("YUYV", "yuyv422")):
                part = re.search(rf"'{fourcc}'.*?(?=\n\s*\[\d+\]:|\Z)", modes, re.S)
                if not part:
                    continue
                size = re.search(r"Size: Discrete 1280x720\s*\n((?:\s*Interval:[^\n]+\n?)+)", part[0])
                if size:
                    rates = re.findall(r"\(([\d.]+) fps\)", size[1])
                    if rates:
                        return path, fmt, max(map(Fraction, rates))
            break
    raise SystemExit("No 04f2:b72f video capture node advertises a discrete 1280x720 mode")


def capture(seconds):
    device, fmt, fps = capture_node()
    frames = round(fps * seconds)
    command = ["ffmpeg", "-hide_banner", "-nostdin", "-loglevel", "error", "-xerror",
               "-err_detect", "explode", "-f", "v4l2", "-input_format", fmt, "-video_size",
               "1280x720", "-framerate", str(fps), "-i", device, "-an", "-frames:v", str(frames),
               "-fps_mode", "passthrough", "-enc_time_base", "1:1000000",
               "-threads:v", "1", "-c:v", "rawvideo", "-pix_fmt", "yuv420p", "-f", "framehash", "-"]
    stream = subprocess.run(command, capture_output=True, text=True, timeout=seconds * 2 + 20)
    if stream.returncode or stream.stderr.strip():
        raise SystemExit(f"Camera stream error: {stream.stderr.strip()} (exit {stream.returncode})")
    if not re.search(r"^#dimensions 0:\s*1280x720$", stream.stdout, re.M):
        raise SystemExit("Decoder did not produce native 720p")
    if not re.search(r"^#tb 0:\s*1/1000000$", stream.stdout, re.M):
        raise SystemExit("Unexpected timestamp unit")
    rows = [line.split(",") for line in stream.stdout.splitlines() if line and not line.startswith("#")]
    if len(rows) != frames or any(int(row[4]) != 1280 * 720 * 3 // 2 for row in rows):
        raise SystemExit("Incomplete decoded frame sequence")
    pts = [int(row[2]) for row in rows]
    gaps = [b - a for a, b in zip(pts, pts[1:])]
    actual_fps = (frames - 1) * 1_000_000 / (pts[-1] - pts[0]) if pts[-1] > pts[0] else 0
    result = dict(device=device, format=fmt, resolution="1280x720", nominal_fps=float(fps),
                  frames=frames, span_seconds=(pts[-1]-pts[0])/1e6, measured_fps=round(actual_fps, 2),
                  max_gap_ms=round(max(gaps)/1000, 2), distinct_frames=len({row[5] for row in rows}))
    print(json.dumps(result), flush=True)
    if (min(gaps) <= 0 or max(gaps) > 2.5e6 / fps or actual_fps < float(fps) * .95
            or result["distinct_frames"] < 2):
        raise SystemExit("Frame timing or changing-pixel check failed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=int, default=60)
    args = parser.parse_args()
    if args.seconds < 2:
        parser.error("at least two seconds of video are required")
    if "np545.camera=1" not in Path("/proc/cmdline").read_text().split():
        parser.error("boot the optional Samsung camera test entry first")
    capture(args.seconds)

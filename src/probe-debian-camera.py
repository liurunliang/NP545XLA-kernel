#!/usr/bin/env python3
"""Decode a timed 720p stream from the internal Samsung USB camera without saving images."""
import argparse
import json
import re
import subprocess
from fractions import Fraction
from pathlib import Path

import gi

gi.require_version("Gst", "1.0")
from gi.repository import Gst


def capture_node(preferred):
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
            for fourcc in ("MJPG", "YUYV"):
                if preferred and fourcc != preferred:
                    continue
                part = re.search(rf"'{fourcc}'.*?(?=\n\s*\[\d+\]:|\Z)", modes, re.S)
                if not part:
                    continue
                size = re.search(r"Size: Discrete 1280x720\s*\n((?:\s*Interval:[^\n]+\n?)+)", part[0])
                if size:
                    rates = re.findall(r"\(([\d.]+) fps\)", size[1])
                    if rates:
                        return path, fourcc, max(map(Fraction, rates))
            break
    raise SystemExit("No 04f2:b72f video capture node advertises a discrete 1280x720 mode")


def capture(seconds, preferred):
    device, fmt, fps = capture_node(preferred)
    frames = round(fps * seconds)
    caps = "image/jpeg" if fmt == "MJPG" else "video/x-raw,format=YUY2"
    decode = "jpegdec ! " if fmt == "MJPG" else ""
    pipeline = Gst.parse_launch(
        f"v4l2src name=camera device={device} num-buffers={frames + 1} ! "
        f"{caps},width=1280,height=720,framerate={fps.numerator}/{fps.denominator} ! "
        f"{decode}videoconvert ! video/x-raw,format=I420 ! "
        "fakesink name=discard sync=false signal-handoffs=true"
    )
    timestamps = []
    sequences = []
    invalid_frames = 0

    def record_input(pad, info):
        buffer = info.get_buffer()
        if buffer.offset != Gst.BUFFER_OFFSET_NONE:
            sequences.append(buffer.offset)
        return Gst.PadProbeReturn.OK

    def record_output(sink, buffer, pad):
        nonlocal invalid_frames
        caps = pad.get_current_caps().get_structure(0)
        if (caps.get_value("width") != 1280 or caps.get_value("height") != 720
                or buffer.get_size() != 1280 * 720 * 3 // 2 or buffer.pts == Gst.CLOCK_TIME_NONE
                or buffer.has_flags(Gst.BufferFlags.CORRUPTED)):
            invalid_frames += 1
        timestamps.append(buffer.pts)

    pipeline.get_by_name("camera").get_static_pad("src").add_probe(
        Gst.PadProbeType.BUFFER, record_input)
    pipeline.get_by_name("discard").connect("handoff", record_output)
    bus = pipeline.get_bus()
    try:
        if pipeline.set_state(Gst.State.PLAYING) == Gst.StateChangeReturn.FAILURE:
            raise SystemExit("Could not start the camera")
        message = bus.timed_pop_filtered((seconds * 2 + 20) * Gst.SECOND,
                                         Gst.MessageType.ERROR | Gst.MessageType.WARNING | Gst.MessageType.EOS)
        if message is None:
            raise SystemExit("Camera stream timed out")
        if message.type != Gst.MessageType.EOS:
            detail, debug = (message.parse_error() if message.type == Gst.MessageType.ERROR
                             else message.parse_warning())
            raise SystemExit(f"Camera stream error: {detail.message} ({debug})")
    finally:
        pipeline.set_state(Gst.State.NULL)

    if len(timestamps) != frames + 1 or invalid_frames:
        raise SystemExit(f"Expected {frames + 1} decoded 720p frames, got {len(timestamps)}, invalid {invalid_frames}")
    # Report the camera's first-frame startup interval separately from continuous streaming.
    startup_gap = timestamps[1] - timestamps[0]
    steady_pts = timestamps[1:]
    gaps = [b - a for a, b in zip(steady_pts, steady_pts[1:])]
    span = (steady_pts[-1] - steady_pts[0]) / Gst.SECOND
    measured = (frames - 1) / span if span > 0 else 0
    if len(sequences) != len(timestamps):
        raise SystemExit("V4L2 did not supply a sequence number for every frame")
    startup_missing = sequences[1] - sequences[0] - 1
    sequence_breaks = sum(b != a + 1 for a, b in zip(sequences[1:], sequences[2:]))
    result = dict(device=device, format=fmt, resolution="1280x720", nominal_fps=float(fps),
                  startup_gap_ms=round(startup_gap / 1e6, 2), startup_missing=startup_missing,
                  steady_frames=frames, span_seconds=round(span, 3), measured_fps=round(measured, 2),
                  max_gap_ms=round(max(gaps) / 1e6, 2), steady_sequence_breaks=sequence_breaks)
    print(json.dumps(result), flush=True)
    if (not 0 < startup_gap <= 2 * Gst.SECOND or startup_missing < 0 or
            min(gaps) <= 0 or max(gaps) > 2.5 * Gst.SECOND / fps or
            measured < float(fps) * .95 or sequence_breaks):
        raise SystemExit("Frame timing or capture sequence check failed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=int, default=60)
    parser.add_argument("--format", choices=("MJPG", "YUYV"))
    args = parser.parse_args()
    if args.seconds < 2:
        parser.error("at least two seconds of video are required")
    if "np545.camera=1" not in Path("/proc/cmdline").read_text().split():
        parser.error("boot the optional Samsung camera test entry first")
    Gst.init(None)
    capture(args.seconds, args.format)

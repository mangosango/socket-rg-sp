#!/usr/bin/env python3
"""Summarize a RetroArch pacing log from tools/pacing-probe.c.

Usage: python3 tools/pacing-report.py socket-pacing.csv [--expect-hz 59.7275]

The report gives facts only. It does not say that the device matches Slot.
"""
import argparse
import statistics


def report(lines, expect_hz):
    panel = 0.0
    swaps, writes, errors = [], [], []
    for line in lines:
        part = line.split()
        if not part:
            continue
        if part[0] == "F":
            panel = float(part[1])
        elif part[0] == "S":
            swaps.append(int(part[1]))
        elif part[0] == "W" and len(part) == 5:
            writes.append((int(part[1]), int(part[2]), int(part[3]), int(part[4])))
        elif part[0] == "U":
            errors.append((int(part[1]), int(part[2])))
    out = {"panel_hz_from_fb0": round(panel, 4), "frames": len(swaps)}
    if len(swaps) > 2:
        gaps = [(b - a) / 1e6 for a, b in zip(swaps, swaps[1:])]
        median = statistics.median(gaps)
        seconds = (swaps[-1] - swaps[0]) / 1e9
        out.update({
            "seconds": round(seconds, 2),
            "presented_fps": round((len(swaps) - 1) / seconds, 3),
            "median_frame_ms": round(median, 3),
            "measured_panel_hz": round(1000 / median, 3),
            "p99_frame_ms": round(sorted(gaps)[int(len(gaps) * 0.99)], 3),
            "worst_frame_ms": round(max(gaps), 3),
            # A late frame takes at least 1.5 normal periods.
            "late_frames": sum(gap > median * 1.5 for gap in gaps),
            "late_per_minute": round(sum(gap > median * 1.5 for gap in gaps) / seconds * 60, 2),
        })
        if expect_hz:
            out["core_vs_panel_percent"] = round((expect_hz - out["measured_panel_hz"]) / out["measured_panel_hz"] * 100, 3)
    if writes:
        size = writes[-1][3]
        filled = [(size - avail) / size * 100 for _, _, avail, _ in writes if size and avail >= 0]
        out.update({
            "alsa_buffer_frames": size,
            "alsa_fill_min_percent": round(min(filled), 1) if filled else None,
            "alsa_fill_median_percent": round(statistics.median(filled), 1) if filled else None,
            "alsa_writes_below_25_percent": sum(value < 25 for value in filled),
        })
    out["alsa_underruns"] = sum(error == -32 for _, error in errors)
    out["alsa_other_errors"] = sum(error != -32 for _, error in errors)
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log")
    parser.add_argument("--expect-hz", type=float, default=0.0, help="core frame rate, 59.7275 for GBA")
    args = parser.parse_args()
    with open(args.log, encoding="utf-8") as file:
        for key, value in report(file, args.expect_hz).items():
            print(f"{key}: {value}")


if __name__ == "__main__":
    main()

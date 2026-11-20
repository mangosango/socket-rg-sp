"""Summarize a render benchmark run.

Usage: python3 tests/app/bench_report.py <results.jsonl or results-directory>
Times are the median of the round statistics. Legacy `delta` is relative to `base`.
A split request that fell back is not an effective split measurement.
"""
import collections
import json
from pathlib import Path
import statistics
import sys

LABEL_MODES = ("native_single", "single_075", "single_060", "split_060")


def read_rows(path):
    with path.open() as source:
        return [json.loads(line) for line in source if line.startswith("{")]


def renderer(run):
    print(f"renderer: {run['renderer']} ({run['api']}), vsync {'on' if run.get('vsync') else 'off'}, {run['frames']} frames x {run['rounds']} rounds")


def size(target):
    return "x".join(map(str, target)) if target else "-"


def report_label(trials):
    renderer(trials[0][0])
    print(f"{trials[0][0].get('fixture', 'opaque_gba')}: median steady frame time and median navigation p95 per round (six carousel steps)")
    print(f"{'requested':14} {'scale':>5} {'frame ms':>9} {'nav p95':>9} {'draws':>7} {'prims':>7}  effective body/label")
    notes = []
    for run, *rows in trials:
        name = run["requested_mode"]
        median = lambda key: statistics.median(row[key] for row in rows)
        states = sorted({
            f"{size(row['viewport_3d'])}/{size(row['viewport_label'])} "
            f"({'fallback' if row['split_label_fallback'] else 'split' if row['split_label_active'] else 'single'})"
            for row in rows
        })
        print(f"{name:14} {run['requested_body_scale']:5.2f} {median('median_ms'):9.2f} {median('nav_p95_ms'):9.2f} "
              f"{median('draw_calls'):7.0f} {median('primitives'):7.0f}  {', '.join(states)}")
        scale = run["requested_body_scale"]
        target = [round(pixels * scale) for pixels in run["window"]]
        if run["window"] == [720, 480]:
            unit = round(240 * scale)
            target = [3 * unit, 2 * unit]
        if any(row["viewport_3d"] != target for row in rows):
            notes.append(f"{name}: actual body target differs from requested {size(target)}")
        if run["requested_split_label"]:
            if any(row["split_label_active"] and row["viewport_label"] != row.get("label_region_px", run["window"]) for row in rows):
                notes.append(f"{name}: label texels do not match displayed panel pixels")
            nav_frames = sum(row["nav_frames"] for row in rows)
            nav_split = sum(row["nav_split_active_frames"] for row in rows)
            steady_frames = run["frames"] * len(rows)
            steady_split = sum(row["steady_split_active_frames"] for row in rows)
            note = f"{name}: fallback in {steady_frames - steady_split}/{steady_frames} steady and {nav_frames - nav_split}/{nav_frames} navigation frames"
            if steady_frames != steady_split or nav_frames != nav_split or any(row["split_label_fallback"] for row in rows):
                note += "; not a clean split measurement"
            notes.append(note)
    for note in notes:
        print(note)
    print("Per-pass draw counts and body/label/window CPU/GPU timings are in each results.jsonl (unsupported timers read zero).")


def report_legacy(rows):
    renderer(rows[0])
    times, quality = collections.defaultdict(list), collections.defaultdict(list)
    for row in rows[1:]:
        (times if row["type"] == "time" else quality)[row["variant"]].append(row)
    if times and "median_ms" in next(iter(times.values()))[0]:
        base = statistics.median(row["median_ms"] for row in times["base"]) if "base" in times else None
        print(f"{'variant':26} {'ms':>7} {'delta':>7} {'min':>7} {'max':>7} {'3D px':>9} {'3D draws':>8} {'2D draws':>8} {'prims':>6}")
        for name, group in times.items():
            medians = [row["median_ms"] for row in group]
            last = group[-1]
            median = statistics.median(medians)
            delta = f"{median - base:+.2f}" if base is not None else "n/a"
            print(f"{name:26} {median:7.2f} {delta:>7} {min(medians):7.2f} {max(medians):7.2f} "
                  f"{size(last['viewport_3d']):>9} {last['3d_draw_calls']:8} {last['canvas_draw_calls']:8} {last['primitives']:6.0f}")
    if quality:
        print(f"\n{'variant':26} {'edge error':>10} {'mean error':>10} {'PSNR dB':>8} {'contrast':>8}   (reference: 16 samples for each panel pixel)")
        for name, group in quality.items():
            mean = lambda key: statistics.mean(row[key] for row in group)
            print(f"{name:26} {mean('edge_error'):10.2f} {mean('mean_error'):10.3f} {mean('psnr_db'):8.2f} {mean('edge_contrast'):8.3f}")


if __name__ == "__main__":
    path = Path(sys.argv[1])
    if path.is_dir():
        if not (path / "results.jsonl").is_file():
            modes = ("single_066", "split_066_off", "split_066_msaa2", "split_066_auto") if (path / "single_066").is_dir() else LABEL_MODES
            report_label([read_rows(path / mode / "results.jsonl") for mode in modes])
            sys.exit(0)
        path /= "results.jsonl"
    rows = read_rows(path)
    if "requested_mode" in rows[0]:
        report_label([rows])
    else:
        report_legacy(rows)

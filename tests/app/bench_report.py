"""Summarize a results.jsonl of tests/app/bench_render.gd.

Usage: python3 tests/app/bench_report.py <results.jsonl>
Times are the median of the round medians. `delta` is the difference from `base`.
The renderer line shows if the times are from Mesa (software) or from Mali.
"""
import collections
import json
import statistics
import sys

rows = [json.loads(line) for line in open(sys.argv[1]) if line.startswith("{")]
run = rows[0]
print(f"renderer: {run['renderer']} ({run['api']}), vsync {'on' if run.get('vsync') else 'off'}, {run['frames']} frames x {run['rounds']} rounds")
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
              f"{'x'.join(map(str, last['viewport_3d'])):>9} {last['3d_draw_calls']:8} {last['canvas_draw_calls']:8} {last['primitives']:6.0f}")
if quality:
    print(f"\n{'variant':26} {'edge error':>10} {'mean error':>10} {'PSNR dB':>8} {'contrast':>8}   (reference: 16 samples for each panel pixel)")
    for name, group in quality.items():
        mean = lambda key: statistics.mean(row[key] for row in group)
        print(f"{name:26} {mean('edge_error'):10.2f} {mean('mean_error'):10.3f} {mean('psnr_db'):8.2f} {mean('edge_contrast'):8.3f}")

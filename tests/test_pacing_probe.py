"""Check the RetroArch pacing probe and its report."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("pacing_report", ROOT / "tools/pacing-report.py")
pacing_report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pacing_report)


class PacingReportTests(unittest.TestCase):
    def test_counts_late_frames_fill_and_underruns(self):
        period = 16_666_667
        swaps = [i * period for i in range(600)]
        swaps[300:] = [t + period for t in swaps[300:]]  # one frame shown twice
        lines = ["F 60.0000"] + [f"S {t}" for t in swaps]
        lines += [f"W {i * period} 800 {2900 if i == 100 else 1000} 3072" for i in range(600)]
        lines += ["U 5000000000 -32"]
        result = pacing_report.report(lines, 59.7275)
        self.assertEqual(result["late_frames"], 1)
        self.assertAlmostEqual(result["measured_panel_hz"], 60.0, places=2)
        self.assertEqual(result["alsa_underruns"], 1)
        self.assertEqual(result["alsa_writes_below_25_percent"], 1)
        self.assertAlmostEqual(result["core_vs_panel_percent"], -0.454, places=2)


@unittest.skipUnless(os.environ.get("RETROARCH_PACING_SMOKE") == "1",
                     "Set RETROARCH_PACING_SMOKE=1 for the ARM64 RetroArch check")
class PacingProbeRuntimeTests(unittest.TestCase):
    def test_probe_records_real_retroarch(self):
        with tempfile.TemporaryDirectory(prefix="ra-pacing-") as directory:
            output = Path(directory)
            (output / "probe.bin").write_bytes(bytes(16))
            (output / "ra.cfg").write_text('video_driver = "gl"\nvideo_context_driver = "mali_fbdev"\n'
                'audio_driver = "alsa"\naudio_device = "null"\ninput_driver = "null"\n'
                'input_joypad_driver = "null"\nmenu_driver = "null"\nconfig_save_on_exit = "false"\n')
            script = '''set -eu
cc -shared -fPIC /repo/tests/retroarch_headless_egl.c -o /output/headless.so -ldl -lEGL
cc -O2 -Wall -Wextra -Werror -shared -fPIC /repo/tools/pacing-probe.c -o /output/pacing.so -ldl -lasound
cc -shared -fPIC -I/repo/work/RetroArch/libretro-common/include /repo/tests/retroarch_controls_core.c -o /output/core.so
EGL_PLATFORM=surfaceless LD_PRELOAD=/output/headless.so:/output/pacing.so SOCKET_PACING_LOG=/output/pacing.csv \
	/repo/work/RetroArch/retroarch --config /output/ra.cfg --max-frames 240 -L /output/core.so /output/probe.bin > /output/ra.log 2>&1
'''
            result = subprocess.run(["docker", "run", "--rm", "--platform", "linux/arm64",
                "-v", f"{ROOT}:/repo:ro", "-v", f"{output}:/output", "socket-baseos-godot", "sh", "-c", script],
                capture_output=True, text=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            with open(output / "pacing.csv", encoding="utf-8") as file:
                data = pacing_report.report(file, 60.0)
            print(data)
            self.assertGreater(data["frames"], 200, data)
            self.assertGreater(data["alsa_buffer_frames"], 0, data)


if __name__ == "__main__":
    unittest.main()

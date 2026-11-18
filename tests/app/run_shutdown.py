"""Quit the packed launcher with five games on Mesa GLES and check the exit.

Usage: python3 tests/app/run_shutdown.py <pack.pck> <evidence-directory>
This runs tests/app/test_shutdown_render.gd with tests/app/run_render.py. The
engine reports a texture leak or a crash after the test script stops, so this
file reads the log. Mali can show other messages: check Logs/socket.log on the
device after a power-off.
"""
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
result = subprocess.run([sys.executable, str(HERE / "run_render.py"), sys.argv[1], str(HERE / "test_shutdown_render.gd"), sys.argv[2]],
                        capture_output=True, text=True)
log = Path(sys.argv[2], "godot.log")
text = log.read_text(errors="replace") if log.exists() else ""
bad = [line for line in text.splitlines() if "leaked" in line and "Texture" in line or "Segmentation fault" in line]
print("\n".join(line for line in text.splitlines() if line.startswith(("PASS:", "FAIL:", "ERROR:", "WARNING:")) or line in bad))
if bad or result.returncode != 0:
    raise SystemExit("FAIL: launcher exit is not clean (run_render.py status %d)" % result.returncode)
print("PASS: launcher exit with five games has no texture leak and no crash")

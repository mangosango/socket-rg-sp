"""Check the RetroArch patches without Docker or a source checkout."""

from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class RetroArchBuildTests(unittest.TestCase):
    def test_patch_is_applied_once_and_rejects_unknown_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tools = root / "tools"
            tools.mkdir()
            for patch in (ROOT / "tools").glob("retroarch-*.patch"):
                shutil.copy(patch, tools)
            for name in ("retroarch-controls.h", "retroarch-control-icons.h", "retroarch-quick-menu.h"):
                shutil.copy(ROOT / "tools" / name, tools)
            # Keep references to original lines while applying each patch in order.
            # Later patch context can fill lines that earlier patches did not use.
            patch_names = re.search(r'PATCHES="([^"]+)"',
                                    (ROOT / "tools/build-retroarch.sh").read_text())[1].split()
            originals, current = {}, {}
            for name in patch_names:
                target, hunks, hunk = None, [], None
                def apply_hunks():
                    if target is None:
                        return
                    original = originals.setdefault(target, [[None] for _ in range(18000)])
                    lines = current.setdefault(target, original.copy())
                    offset = 0
                    for position, body in hunks:
                        old = [line[1:] for line in body if line.startswith((" ", "-"))]
                        position += offset
                        refs = lines[position:position + len(old)]
                        for ref, text in zip(refs, old):
                            if ref[0] is not None:
                                self.assertEqual(ref[0], text, name)
                            ref[0] = text
                        replacement, index = [], 0
                        for line in body:
                            if line.startswith(" "):
                                replacement.append(refs[index])
                                index += 1
                            elif line.startswith("-"):
                                index += 1
                            elif line.startswith("+"):
                                replacement.append([line[1:]])
                        lines[position:position + len(old)] = replacement
                        offset += len(replacement) - len(old)
                for line in (tools / name).read_text().splitlines(True):
                    if line.startswith("--- a/"):
                        apply_hunks()
                        target, hunks = line[6:].strip(), []
                    elif line.startswith("@@"):
                        hunk = []
                        hunks.append((int(re.match(r"@@ -(\d+)", line)[1]) - 1, hunk))
                    elif hunk is not None and line.startswith((" ", "+", "-")) and not line.startswith("+++ "):
                        hunk.append(line)
                apply_hunks()
            for name, lines in originals.items():
                target = root / "work/RetroArch" / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text("".join(line[0] if line[0] is not None else "\n" for line in lines))
            # Run the real build prelude, before it invokes Docker.
            prelude = (ROOT / "tools/build-retroarch.sh").read_text().split("docker build", 1)[0]
            script = tools / "build-retroarch.sh"
            script.write_text(prelude)
            source = root / "work/RetroArch/gfx/drivers_context/mali_fbdev_ctx.c"
            source.parent.mkdir(parents=True, exist_ok=True)
            original = """      EGL_BLUE_SIZE, 8,
      EGL_GREEN_SIZE, 8,
      EGL_RED_SIZE, 8,
      EGL_ALPHA_SIZE, 8,
      EGL_NONE
   };
   EGLint attribs_create[] = {
"""
            source.write_text(original)
            pristine = {path: path.read_bytes() for path in (root / "work/RetroArch").rglob("*") if path.is_file()}
            first = subprocess.run(["sh", str(script)], capture_output=True, text=True)
            self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
            for name, installed in (("retroarch-controls.h", "socket_controls.h"),
                                    ("retroarch-control-icons.h", "socket_control_icons.h"),
                                    ("retroarch-quick-menu.h", "socket_quick_menu.h")):
                self.assertEqual((root / "work/RetroArch" / installed).read_bytes(),
                                 (tools / name).read_bytes())
            patched = source.read_text()
            self.assertEqual(patched, original.replace("EGL_ALPHA_SIZE, 8", "EGL_ALPHA_SIZE, 0"))
            (root / "work/RetroArch/socket_controls.h").write_text("stale header")
            second = subprocess.run(["sh", str(script)], capture_output=True, text=True)
            self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
            self.assertEqual((root / "work/RetroArch/socket_controls.h").read_bytes(),
                             (tools / "retroarch-controls.h").read_bytes())
            self.assertEqual(source.read_text(), patched)
            final = {path: path.read_bytes() for path in pristine}
            self.assertFalse(list((root / "work/RetroArch").rglob("*.rej")))
            # Upgrade a checkout that already has the previous MENU patch.
            for path, content in pristine.items():
                path.write_bytes(content)
            for name in ("retroarch-mali-rgb.patch", "retroarch-menu-hold.patch"):
                result = subprocess.run(["patch", "-d", str(root / "work/RetroArch"), "-p1", "--force"],
                                        input=(tools / name).read_text(), capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            for _ in range(2):
                upgraded = subprocess.run(["sh", str(script)], capture_output=True, text=True)
                self.assertEqual(upgraded.returncode, 0, upgraded.stdout + upgraded.stderr)
                self.assertEqual({path: path.read_bytes() for path in pristine}, final)
                self.assertFalse(list((root / "work/RetroArch").rglob("*.rej")))
            source.write_text("incompatible source\n")
            invalid = subprocess.run(["sh", str(script)], capture_output=True, text=True)
            self.assertNotEqual(invalid.returncode, 0)
            self.assertEqual(source.read_text(), "incompatible source\n")


if __name__ == "__main__":
    unittest.main()

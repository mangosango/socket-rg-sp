"""Test the RetroArch side of the shared Device Settings scene on the host.

The test takes the role of the launcher: it reads menu.input and writes
menu.frame and menu.event.
"""

import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
build = None


def setUpModule():
    """Compile the harness with the header names that the RetroArch build uses."""
    global build
    build = tempfile.TemporaryDirectory()
    unittest.addModuleCleanup(build.cleanup)
    include = Path(build.name)
    (include / "features").mkdir()
    (include / "features/features_cpu.h").write_text(
        "#pragma once\n#include <stdint.h>\ntypedef int64_t retro_time_t;\nretro_time_t cpu_features_get_time_usec(void);\n")
    shutil.copy(ROOT / "tools/retroarch-menu-overlay.h", include / "socket_menu_overlay.h")
    subprocess.run(["cc", "-std=gnu99", "-Wall", "-Wextra", "-Werror", f"-I{include}",
                    str(ROOT / "tests/retroarch_menu_overlay_harness.c"), "-o", str(include / "harness")], check=True)


class OverlayTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.run_dir = Path(directory.name)
        self.environment = dict(os.environ, SOCKET_RUN=directory.name, SOCKET_GAME_OVERLAY_EGL="1")
        self.environment.pop("SOCKET_FRONTEND_PID", None)
        self.process = None

    def start(self):
        self.process = subprocess.Popen([str(Path(build.name) / "harness")], env=self.environment,
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        self.addCleanup(self.process.wait)
        self.addCleanup(self.process.kill)
        self.addCleanup(self.process.stdout.close)
        self.addCleanup(self.process.stdin.close)

    def send(self, command):
        if self.process is None:
            self.start()
        self.process.stdin.write(command + "\n")
        self.process.stdin.flush()
        lines = []
        while True:
            line = self.process.stdout.readline()
            self.assertTrue(line, "the harness stopped")
            if line == "end\n":
                return lines
            lines.append(line.rstrip("\n"))

    def put(self, name, data):
        temporary = self.run_dir / (name + ".new")
        temporary.write_bytes(data)
        os.replace(temporary, self.run_dir / name)

    def frame(self, identifier, number, width=4, height=2, flags=1, fill=7, size=None, magic=b"SKMF", version=1):
        pixels = bytes([fill]) * (width * height * 4 if size is None else size)
        self.put("menu.frame", magic + struct.pack("<6I", version, identifier, number, width, height, flags) + pixels)

    def lines(self):
        return (self.run_dir / "menu.input").read_text().splitlines()

    def test_open_frames_events_and_close(self):
        (self.run_dir / "menu.frame").write_bytes(b"old")
        (self.run_dir / "menu.event").write_text("1 1 close\n")
        self.assertEqual(self.send("open"), ["open 1"])
        # The files of an earlier game are gone, so its event cannot close this menu.
        self.assertFalse((self.run_dir / "menu.frame").exists())
        self.assertEqual(self.send("tick"), ["event none"])
        lines = self.lines()
        self.assertRegex(lines[0], r"^session \d+-\d+ 2$")
        self.assertEqual(lines[1:], ["open 1"])
        self.assertEqual(os.stat(self.run_dir / "menu.input").st_mode & 0o777, 0o600)
        self.frame(1, 1)
        self.assertEqual(self.send("tick"), ["event none", "frame 4 2 1 1 7 7"])
        # The same frame number is not a new frame.
        self.frame(1, 1, fill=9)
        self.assertEqual(self.send("tick"), ["event none", "frame 4 2 1 1 7 7"])
        self.frame(1, 2, width=720, height=480, flags=0, fill=9)
        self.assertEqual(self.send("tick"), ["event none", "frame 720 480 0 2 9 9"])
        # Each event number has an effect one time. Other open requests have none.
        for text, event in (("1 1 game\n", "game"), ("1 1 game\n", "none"), ("2 2 close\n", "none"),
                            ("1 2 cheats\n", "cheats"), ("1 3 close\n", "close"), ("1 4 close", "none"),
                            ("1 5 other\n", "none")):
            self.put("menu.event", text.encode())
            self.assertEqual(self.send("tick")[0], "event " + event, text)
        self.assertEqual(self.send("close"), [])
        self.assertEqual(self.send("close"), [])
        self.assertEqual(self.lines()[1:], ["open 1", "close 1"])
        # A frame of the closed menu is not for the next one.
        self.assertEqual(self.send("open"), ["open 1"])
        self.assertEqual(self.send("tick"), ["event none"])
        self.frame(2, 1, fill=3)
        self.assertEqual(self.send("tick"), ["event none", "frame 4 2 1 3 3 3"])
        self.assertEqual(self.lines()[3], "open 2")

    def test_theme_is_read_with_the_game_and_cheats_events(self):
        self.send("open")
        self.put("menu.theme", b"1 1a2b3c D0e0f0 137 67 446 346 18\n")
        # The scene still has the pad: no native page needs the colors.
        self.assertEqual(self.send("tick"), ["event none"])
        self.put("menu.event", b"1 1 game\n")
        self.assertEqual(self.send("tick"), ["event game", "theme 1a2b3c d0e0f0"])
        for number, text in enumerate(("3 1a2b3c d0e0f0 1 1 1 1 1\n", "12 1a2b3c d0e0f0 1 1 1 1 1\n", "1 1a2b3 d0e0f0 1 1 1 1 1\n", "1 1a2b3c d0e0f0 1 1 1 1 1",
                                       "1 1a2b3c d0e0fz 1 1 1 1 1\n", "1 1a2b3c d0e0f0 1 1 1 1\n", ""), 2):
            self.put("menu.theme", text.encode())
            self.put("menu.event", b"1 %d cheats\n" % number)
            self.assertEqual(self.send("tick"), ["event cheats"], text)
        self.put("menu.theme", b"1 000000 ffffff 0 0 720 480 0\n")
        self.put("menu.event", b"1 19 game\n")
        self.assertEqual(self.send("tick"), ["event game", "theme 000000 ffffff"])
        self.assertEqual(self.send("close"), [])

    def enter(self, word="game"):
        """Open the scene of a version 2 launcher and select a page of RetroArch."""
        self.send("open")
        self.frame(1, 1)
        self.put("menu.theme", b"2 1a2b3c d0e0f0 137 67 446 346 18\n")
        self.put("menu.event", f"1 1 {word}\n".encode())
        self.assertEqual(self.send("tick"), ["event " + word, "frame 4 2 1 1 7 7", "theme 1a2b3c d0e0f0", "views"])
        self.send("focus 0")

    def test_views_write_one_line_for_each_change(self):
        self.enter()
        hexed = lambda text: text.encode().hex()
        # The root frame is not the page: the dimmer shows until the view frame.
        self.assertEqual(self.send("view 1 0 10 Game - Resume Core"), ["theme 1a2b3c d0e0f0", "views"])
        view = f"view 1 1 0 10 {hexed('Game')} - {hexed('Resume')} {hexed('Core')}"
        self.assertEqual(self.lines()[2:], [view])
        size = os.stat(self.run_dir / "menu.input").st_size
        for _ in range(5):
            self.send("view 1 0 10 Game - Resume Core")
            self.send("tick")
        self.assertEqual(os.stat(self.run_dir / "menu.input").st_size, size)
        self.frame(1, 2, flags=1 | 1 << 8, fill=5)
        self.assertEqual(self.send("tick")[:2], ["event none", "frame 4 2 257 2 5 5"])
        # The same kind of page: the last frame stays until the new one.
        self.send("view 0 0 0 Cheats Saved.")
        self.assertEqual(self.send("tick")[1], "frame 4 2 257 2 5 5")
        self.assertEqual(self.lines()[3], f"view 1 0 0 0 {hexed('Cheats')} {hexed('Saved.')}")
        # A pad event of the scene has no effect during a view.
        self.put("menu.event", b"1 2 close\n")
        self.assertEqual(self.send("tick")[0], "event none")
        self.send("pad 1")
        # Back: the view frame is not Device Settings.
        self.assertEqual(self.send("root"), ["theme 1a2b3c d0e0f0", "views"])
        self.send("root")
        self.send("focus 1")
        self.assertEqual(self.lines()[4:], ["root 1"])
        self.frame(1, 3, flags=1 | 2 << 8, fill=6)
        # The scene has the pad again, thus its event has an effect.
        self.assertEqual(self.send("tick"), ["event close", "theme 1a2b3c d0e0f0", "views"])
        self.frame(1, 4, flags=1 | 3 << 8, fill=8)
        self.assertEqual(self.send("tick")[:2], ["event none", "frame 4 2 769 4 8 8"])
        # A new open request starts again: the same view is a new line.
        self.send("close")
        self.send("open")
        self.send("focus 0")
        self.send("view 1 0 10 Game - Resume Core")
        self.assertEqual(self.lines()[-2:], ["open 2", view.replace("view 1", "view 2", 1)])

    def test_view_text_is_bounded(self):
        self.enter("cheats")
        long = "é" * 100
        self.send("view 5 3 9 - - " + " ".join([long] * 8))
        words = self.lines()[2].split()
        # Six rows. An empty title is one space. No UTF-8 character is cut.
        self.assertEqual(words[:7], ["view", "1", "5", "3", "9", "20", "-"])
        self.assertEqual(words[7:], [("é" * 60).encode().hex()] * 6)
        self.assertLess(len(self.lines()[2]), 2047)

    def test_launcher_that_stops_during_a_view_fails(self):
        self.enter()
        self.send("view 0 0 1 Game - Resume")
        self.send("view 0 0 1 Game Saved. Resume")
        # New frames of Device Settings do not give the launcher more time.
        for number in range(2, 9):
            self.frame(1, number, fill=number)
            self.send("advance 0.2")
            self.assertEqual(self.send("tick")[0], "event none")
        # A frame of the first view does: it shows a newer line.
        self.frame(1, 9, flags=1 | 1 << 8, fill=4)
        self.assertEqual(self.wait(1.4)[:2], ["event none", "frame 4 2 257 9 4 4"])
        self.frame(1, 10, flags=1 | 1 << 8, fill=5)
        self.assertEqual(self.wait(0.4), ["event failed"])
        self.assertEqual(self.lines()[-1], "close 1")
        self.assertEqual(self.send("open"), ["open 0"])

    def test_part_of_a_line_does_not_join_the_next_line(self):
        self.send("open")
        self.send("pad 0")
        size = os.stat(self.run_dir / "menu.input").st_size
        # The disk is full after 5 bytes of the line.
        self.send(f"limit {size + 5}")
        self.send("pad 1")
        self.send("limit 0")
        self.send("pad 3")
        self.assertEqual(self.lines()[2:], ["pad u", "pad down 1"])
        self.put("menu.theme", b"2 1a2b3c d0e0f0 137 67 446 346 18\n")
        self.put("menu.event", b"1 1 game\n")
        self.send("tick")
        self.send("focus 0")
        size = os.stat(self.run_dir / "menu.input").st_size
        self.send(f"limit {size + 9}")
        self.send("view 0 0 1 Game - Resume")
        # The view failed and "close" could not go out: RetroArch uses its native pages.
        self.assertEqual(self.lines()[-1], "view 1 0 ")
        self.assertEqual(self.send("open"), ["open 0"])

    def test_version_1_launcher_gets_no_view(self):
        self.send("open")
        self.frame(1, 1)
        self.put("menu.theme", b"1 1a2b3c d0e0f0 137 67 446 346 18\n")
        self.put("menu.event", b"1 1 game\n")
        self.assertEqual(self.send("tick"), ["event game", "frame 4 2 1 1 7 7", "theme 1a2b3c d0e0f0"])
        self.send("focus 0")
        self.send("view 0 0 1 Game - Resume")
        self.send("root")
        self.assertEqual(self.lines()[1:], ["open 1"])
        # The native page has no wait for a frame.
        self.assertEqual(self.wait(3), ["event none", "frame 4 2 1 1 7 7", "theme 1a2b3c d0e0f0"])

    def test_pad_lines_follow_the_focus(self):
        self.send("open")
        # A (bit 4) is down at the open request: the scene does not get it.
        self.send("pad 16")
        self.send("pad 17")
        self.send("pad 1")
        self.send("pad 16")
        self.assertEqual(self.lines()[2:], ["pad up 1", "pad up 0", "pad a 1"])
        # A native page takes the pad: the scene gets the release.
        self.send("focus 0")
        self.send("pad 48")
        self.send("focus 1")
        # B (bit 5) is down from the native page.
        self.send("pad 32")
        self.send("pad 0")
        self.send("pad 544")
        self.send("close")
        self.assertEqual(self.lines()[5:], ["pad a 0", "pad b 1", "pad r 1", "pad b 0", "pad r 0", "close 1"])
        self.send("pad 1")
        self.assertEqual(self.lines()[-1], "close 1")

    def test_invalid_frames_are_ignored(self):
        self.send("open")
        self.frame(1, 1, magic=b"SKMG")
        self.assertEqual(self.send("tick"), ["event none"])
        self.frame(1, 1, version=2)
        self.assertEqual(self.send("tick"), ["event none"])
        self.frame(1, 1, size=31)
        self.assertEqual(self.send("tick"), ["event none"])
        self.frame(1, 1, width=1025, height=1)
        self.assertEqual(self.send("tick"), ["event none"])
        self.frame(1, 1, width=0, height=0)
        self.assertEqual(self.send("tick"), ["event none"])
        self.put("menu.frame", b"SKMF")
        self.assertEqual(self.send("tick"), ["event none"])
        self.frame(1, 1)
        self.assertEqual(self.send("tick"), ["event none", "frame 4 2 1 1 7 7"])

    def wait(self, seconds):
        """Move the clock in steps of 0.2 seconds, with a tick for each step."""
        result = []
        for _ in range(round(seconds / 0.2)):
            self.send("advance 0.2")
            result = self.send("tick")
        return result

    def test_no_first_frame_fails_but_sleep_time_does_not_count(self):
        self.send("open")
        self.assertEqual(self.wait(1.4), ["event none"])
        # The process was stopped for 60 seconds.
        self.send("advance 60")
        self.assertEqual(self.send("tick"), ["event none"])
        self.assertEqual(self.wait(0.2), ["event failed"])
        # The failure closes the scene, and the next MENU tap does not wait again.
        self.assertEqual(self.lines()[1:], ["open 1", "close 1"])
        self.assertEqual(self.send("open"), ["open 0"])
        self.assertEqual(self.lines()[1:], ["open 1", "close 1"])

    def test_quiet_launcher_with_a_frame_is_not_a_failure(self):
        self.send("open")
        self.frame(1, 1)
        self.assertEqual(self.wait(3)[0], "event none")

    def test_launcher_without_a_context_is_not_asked(self):
        for value in (None, "0"):
            self.process = None
            self.environment.pop("SOCKET_GAME_OVERLAY_EGL", None)
            if value:
                self.environment["SOCKET_GAME_OVERLAY_EGL"] = value
            self.assertEqual(self.send("open"), ["open 0"])
            self.assertFalse((self.run_dir / "menu.input").exists())

    def test_dead_launcher_fails_immediately(self):
        gone = subprocess.Popen(["true"])
        gone.wait()
        self.environment["SOCKET_FRONTEND_PID"] = str(gone.pid)
        self.send("open")
        self.assertEqual(self.send("tick"), ["event failed"])
        self.assertEqual(self.send("open"), ["open 0"])
        self.process = None
        self.environment["SOCKET_FRONTEND_PID"] = str(os.getpid())
        self.send("open")
        self.assertEqual(self.send("tick"), ["event none"])

    def test_unwritable_run_directory_uses_the_native_pages(self):
        self.environment["SOCKET_RUN"] = str(self.run_dir / "absent")
        self.assertEqual(self.send("open"), ["open 0"])
        self.assertEqual(self.send("tick"), ["event none"])


if __name__ == "__main__":
    unittest.main()

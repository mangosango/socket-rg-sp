/* Device Settings of the launcher, shown above the paused game.
 *
 * The launcher draws its Device Settings scene off the screen and gives the
 * frames to RetroArch. RetroArch keeps the display and sends the pad buttons.
 * socket_quick_menu.h includes this file in its implementation section. The
 * file uses socket_sleep_path() and cpu_features_get_time_usec().
 *
 * Files in SOCKET_RUN:
 * - menu.input: RetroArch adds lines. Line 1 is "session TOKEN 2": the 2
 *   tells the launcher that this RetroArch can use menu.theme version 2. Then
 *   "open ID", "close ID" and "pad NAME 0|1". For a launcher of version 2,
 *   also "view ID SELECTED FIRST TOTAL TITLE STATUS ROW..." and "root ID".
 *   See socket_overlay_view().
 * - menu.frame: the launcher replaces it. A header of 28 bytes, then RGBA
 *   rows from the top. See smo_read_frame().
 * - menu.event: the launcher replaces it. "ID N close|game|cheats".
 * - menu.theme: the launcher writes it before the first frame.
 *   "VERSION SURFACE INK X Y WIDTH HEIGHT RADIUS": the panel color and the
 *   text color as rrggbb, then the panel rectangle in frame pixels. Version 1
 *   draws only Device Settings. Version 2 also draws the pages of RetroArch.
 *
 * Interface:
 * - socket_overlay_open(): send "open". False means "use the native pages".
 *   It is false if the launcher has no GL context for the scene
 *   (SOCKET_GAME_OVERLAY_EGL is not 1), and after one failure, until the game
 *   stops. Thus a launcher that cannot answer costs one wait at most.
 * - socket_overlay_close(): send "close" and erase the frame. A second call
 *   does nothing.
 * - socket_overlay_focus(on): on gives the pad to the launcher scene.
 * - socket_overlay_pad(mask): bit N is the button SMO_NAMES[N].
 * - socket_overlay_tick(): call it one time for each frame while the scene
 *   has the focus. It returns an SMO_ event. SMO_FAILED also closes the scene.
 * - socket_overlay_frame(): the newest frame, or NULL. It is NULL while the
 *   newest frame is older than the last change between Device Settings and a
 *   page of RetroArch.
 * - socket_overlay_views(): true if the launcher draws the pages of RetroArch.
 * - socket_overlay_view(...), socket_overlay_root(): give a page of RetroArch
 *   to the launcher, and go back to Device Settings. They write a line only
 *   if the page changed. RetroArch keeps the pad during a view.
 * - socket_overlay_theme(): the colors of the launcher panel, for the native
 *   pages below the scene. False means "use the default colors".
 *
 * This file does no work while the menu is closed. It reads the pixels one
 * time for each new frame number. If the launcher does not draw the newest
 * page in SMO_WAIT_USEC after the last frame that showed a newer page,
 * socket_overlay_tick() fails.
 */
#ifndef SOCKET_MENU_OVERLAY_H
#define SOCKET_MENU_OVERLAY_H
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* The launcher must show its first frame in this time. Adjust it on the
 * device if a slow card makes the native pages appear. */
#define SMO_WAIT_USEC 1500000
#define SMO_MAX_SIDE 1024
#define SMO_HEADER 28
/* A view has SMO_ROWS rows or fewer. Each text has SMO_TEXT bytes or fewer.
 * SMO_LINE is sufficient for the longest line. */
#define SMO_ROWS 6
#define SMO_TEXT 120
#define SMO_LINE 2048

enum { SMO_NONE, SMO_CLOSE, SMO_GAME, SMO_CHEATS, SMO_FAILED };
static const char *const SMO_NAMES[] = {"up", "down", "left", "right", "a", "b", "x", "y", "l", "r"};
#define SMO_BUTTONS (sizeof(SMO_NAMES) / sizeof(*SMO_NAMES))

static struct {
   int fd;
   bool started, open, focus, ready, themed, views, viewing, torn, seen;
   unsigned surface, ink;
   /* shot: the number of view and root lines of this open request. since:
    * its value at the last change between a view and Device Settings. */
   unsigned shot, since;
   /* acked: the highest count that a frame of this open request showed. */
   unsigned acked;
   char line[SMO_LINE];
   unsigned id, frame, event, held, stale, serial, width, height, flags;
   unsigned char *pixels;
   size_t capacity;
   retro_time_t deadline, last_tick, alive_at;
} smo;

/* Add one complete line. If an earlier write stopped in the middle of a
 * line, end that part first: then the launcher can read this line. */
static bool smo_write(const char *line, size_t length) {
   if (smo.fd < 0 || (smo.torn && write(smo.fd, "\n", 1) != 1)) return false;
   smo.torn = write(smo.fd, line, length) != (ssize_t)length;
   return !smo.torn;
}

static bool smo_send(const char *format, ...) {
   char line[32];
   va_list arguments;
   int length;
   va_start(arguments, format);
   length = vsnprintf(line, sizeof(line), format, arguments);
   va_end(arguments);
   return length > 0 && length < (int)sizeof(line) && smo_write(line, (size_t)length);
}

/* Make menu.input for this RetroArch process. Remove the files of an
 * earlier game. */
static bool smo_start(void) {
   char path[PATH_MAX_LENGTH], temporary[PATH_MAX_LENGTH], line[64];
   const char *context = getenv("SOCKET_GAME_OVERLAY_EGL");
   int length;
   if (smo.started) return smo.fd >= 0;
   smo.started = true;
   smo.fd = -1;
   /* The launcher engine sets this before it starts the game. */
   if (!context || strcmp(context, "1")) return false;
   if (socket_sleep_path(path, sizeof(path), "menu.frame")) unlink(path);
   if (socket_sleep_path(path, sizeof(path), "menu.event")) unlink(path);
   if (!socket_sleep_path(path, sizeof(path), "menu.input")
         || !socket_sleep_path(temporary, sizeof(temporary), "menu.input.new")) return false;
   smo.fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND | O_CLOEXEC, 0600);
   length = snprintf(line, sizeof(line), "session %ld-%lld 2\n", (long)getpid(), (long long)cpu_features_get_time_usec());
   if (smo.fd < 0 || write(smo.fd, line, (size_t)length) != length || rename(temporary, path) != 0) {
      if (smo.fd >= 0) close(smo.fd);
      unlink(temporary);
      smo.fd = -1;
   }
   return smo.fd >= 0;
}

static void smo_release(void) {
   unsigned i;
   for (i = 0; i < SMO_BUTTONS; i++) if (smo.held & (1u << i)) smo_send("pad %s 0\n", SMO_NAMES[i]);
   smo.held = 0;
}

static void socket_overlay_close(void) {
   if (!smo.open) return;
   smo_release();
   smo_send("close %u\n", smo.id);
   smo.open = smo.focus = smo.ready = smo.themed = false;
   /* A frame can show typed text. */
   if (smo.pixels) memset(smo.pixels, 0, smo.capacity);
}

/* The launcher did not answer. Do not ask it again in this game. */
static int smo_fail(void) {
   socket_overlay_close();
   if (smo.fd >= 0) close(smo.fd);
   smo.fd = -1;
   return SMO_FAILED;
}

static bool socket_overlay_open(void) {
   retro_time_t now = cpu_features_get_time_usec();
   socket_overlay_close();
   if (!smo_start() || !smo_send("open %u\n", ++smo.id)) return false;
   smo.open = smo.focus = true;
   smo.ready = smo.themed = smo.viewing = smo.seen = false;
   smo.event = smo.frame = smo.held = smo.shot = smo.since = smo.acked = 0;
   smo.line[0] = 0;
   /* A button that is down now is not for the scene. */
   smo.stale = ~0u;
   smo.deadline = now + SMO_WAIT_USEC;
   smo.last_tick = now;
   smo.alive_at = 0;
   return true;
}

static void socket_overlay_focus(bool on) {
   if (!smo.open || smo.focus == on) return;
   if (!on) smo_release();
   smo.focus = on;
   smo.stale = ~0u;
}

static void socket_overlay_pad(unsigned mask) {
   unsigned i, changed;
   if (!smo.open || !smo.focus) return;
   smo.stale &= mask;
   mask &= ~smo.stale;
   changed = mask ^ smo.held;
   for (i = 0; changed && i < SMO_BUTTONS; i++)
      if (changed & (1u << i)) smo_send("pad %s %d\n", SMO_NAMES[i], (mask >> i) & 1);
   smo.held = mask;
}

static unsigned smo_u32(const unsigned char *bytes) {
   return bytes[0] | bytes[1] << 8 | bytes[2] << 16 | (unsigned)bytes[3] << 24;
}

/* Header, little-endian: "SKMF", version 1, open ID, frame number, width,
 * height, flags. Bit 0 of flags: the color has the alpha in it. Bits 8 to 31:
 * the number of view and root lines of this open request that the frame
 * shows. Then width * height * 4 bytes: R, G, B, A. The first row is the top
 * row. */
static void smo_read_frame(void) {
   char path[PATH_MAX_LENGTH];
   unsigned char header[SMO_HEADER];
   struct stat info;
   unsigned width, height, number;
   size_t size, done = 0;
   ssize_t count = 1;
   int fd;
   if (!socket_sleep_path(path, sizeof(path), "menu.frame") || (fd = open(path, O_RDONLY | O_CLOEXEC)) < 0) return;
   if (read(fd, header, sizeof(header)) == (ssize_t)sizeof(header) && !memcmp(header, "SKMF", 4)
         && smo_u32(header + 4) == 1 && smo_u32(header + 8) == smo.id) {
      number = smo_u32(header + 12);
      width = smo_u32(header + 16);
      height = smo_u32(header + 20);
      size = (size_t)width * height * 4;
      if ((!smo.ready || number != smo.frame) && width && height && width <= SMO_MAX_SIDE && height <= SMO_MAX_SIDE
            && fstat(fd, &info) == 0 && (size_t)info.st_size == size + SMO_HEADER) {
         if (size > smo.capacity) {
            unsigned char *pixels = (unsigned char *)realloc(smo.pixels, size);
            if (pixels) { smo.pixels = pixels; smo.capacity = size; }
         }
         if (size <= smo.capacity) {
            while (done < size && (count = read(fd, smo.pixels + done, size - done)) > 0) done += (size_t)count;
            /* A part of a frame is not a frame. Show the dimmer and wait for
             * the next one. */
            smo.ready = done == size;
            smo.flags = smo_u32(header + 24);
            /* Only a frame that shows a newer line gives the launcher more
             * time. Frames of an old page do not. */
            if (!smo.seen || smo.flags >> 8 > smo.acked) {
               smo.seen = true;
               smo.acked = smo.flags >> 8;
               smo.deadline = cpu_features_get_time_usec() + SMO_WAIT_USEC;
            }
            smo.frame = number;
            smo.width = width;
            smo.height = height;
            smo.serial++;
         }
      }
   }
   close(fd);
}

static int smo_read_event(void) {
   char path[PATH_MAX_LENGTH], data[48], word[8], end;
   unsigned id, number;
   ssize_t length;
   int fd;
   if (!socket_sleep_path(path, sizeof(path), "menu.event") || (fd = open(path, O_RDONLY | O_CLOEXEC)) < 0) return SMO_NONE;
   length = read(fd, data, sizeof(data) - 1);
   close(fd);
   data[length > 0 ? length : 0] = 0;
   if (sscanf(data, "%9u %9u %7[a-z]%c", &id, &number, word, &end) != 4 || end != '\n'
         || id != smo.id || number == smo.event) return SMO_NONE;
   smo.event = number;
   return !strcmp(word, "close") ? SMO_CLOSE : !strcmp(word, "game") ? SMO_GAME
      : !strcmp(word, "cheats") ? SMO_CHEATS : SMO_NONE;
}

/* Read the version, and the colors for the native pages. The rectangle and
 * the radius are not used: the native list needs more space than the launcher
 * panel. The version stays until the launcher fails. */
static void smo_read_theme(void) {
   char path[PATH_MAX_LENGTH], data[96], surface[8], ink[8], end;
   unsigned version, x, y, width, height, radius;
   ssize_t length;
   int fd;
   smo.themed = false;
   if (!socket_sleep_path(path, sizeof(path), "menu.theme") || (fd = open(path, O_RDONLY | O_CLOEXEC)) < 0) return;
   length = read(fd, data, sizeof(data) - 1);
   close(fd);
   data[length > 0 ? length : 0] = 0;
   if (sscanf(data, "%1u %7[0-9a-fA-F] %7[0-9a-fA-F] %5u %5u %5u %5u %5u%c", &version, surface, ink, &x, &y, &width, &height, &radius, &end) != 9
         || end != '\n' || data[1] != ' ' || version < 1 || version > 2 || strlen(surface) != 6 || strlen(ink) != 6) return;
   smo.views = version == 2;
   smo.surface = (unsigned)strtoul(surface, NULL, 16);
   smo.ink = (unsigned)strtoul(ink, NULL, 16);
   smo.themed = true;
}

static bool socket_overlay_theme(unsigned *surface, unsigned *ink) {
   if (!smo.open || !smo.themed) return false;
   *surface = smo.surface;
   *ink = smo.ink;
   return true;
}

static bool socket_overlay_views(void) { return smo.fd >= 0 && smo.views; }

/* True if the newest frame shows the last line. */
static bool smo_current(void) { return smo.ready && smo.flags >> 8 == (smo.shot & 0xffffff); }

/* Add one line for a new page. The same page again adds nothing. */
static void smo_page(bool view, const char *line, size_t length) {
   if (!smo.open || !strcmp(line, smo.line)) return;
   /* A part of a line is not a page. Use the native pages. */
   if (!smo_write(line, length)) { smo_fail(); return; }
   memcpy(smo.line, line, length + 1);
   if (smo_current()) smo.deadline = cpu_features_get_time_usec() + SMO_WAIT_USEC;
   smo.shot++;
   if (view != smo.viewing) { smo.viewing = view; smo.since = smo.shot; }
}

/* Add a space and the bytes of text as hex. An empty text becomes one space. */
static size_t smo_hex(char *line, size_t at, const char *text) {
   size_t length = strnlen(text, SMO_TEXT), i;
   /* Do not cut a UTF-8 character. */
   if (text[length]) while (length && ((unsigned char)text[length] & 0xc0) == 0x80) length--;
   if (!length) { text = " "; length = 1; }
   line[at++] = ' ';
   for (i = 0; i < length; i++) at += (size_t)sprintf(line + at, "%02x", (unsigned char)text[i]);
   return at;
}

/* Show a page of RetroArch in the launcher scene: "view ID SELECTED FIRST
 * TOTAL TITLE STATUS ROW...". rows has count visible rows (SMO_ROWS or
 * fewer), first is the page row of rows[0], selected is an index into rows
 * and total is the number of page rows. Each text is UTF-8 as hex. An empty
 * status is "-". */
static void socket_overlay_view(unsigned selected, unsigned first, unsigned total,
      const char *title, const char *status, const char *const *rows, unsigned count) {
   char line[SMO_LINE];
   size_t at;
   unsigned i;
   if (!smo.open || !socket_overlay_views()) return;
   at = (size_t)sprintf(line, "view %u %u %u %u", smo.id, selected, first, total);
   at = smo_hex(line, at, title);
   if (*status) at = smo_hex(line, at, status);
   else at += (size_t)sprintf(line + at, " -");
   for (i = 0; i < count && i < SMO_ROWS; i++) at = smo_hex(line, at, rows[i]);
   line[at++] = '\n';
   line[at] = 0;
   smo_page(true, line, at);
}

/* Show Device Settings again: "root ID". */
static void socket_overlay_root(void) {
   char line[32];
   if (smo.viewing) smo_page(false, line, (size_t)sprintf(line, "root %u\n", smo.id));
}

static int socket_overlay_tick(void) {
   retro_time_t now = cpu_features_get_time_usec();
   int event;
   if (!smo.open || (!smo.focus && !smo.viewing)) return SMO_NONE;
   /* Sleep stops this process. That time is not a part of the wait. */
   if (now - smo.last_tick > 250000) smo.deadline += now - smo.last_tick;
   smo.last_tick = now;
   smo_read_frame();
   /* The scene has no pad during a view, thus it sends no event. */
   if (smo.focus && (event = smo_read_event()) != SMO_NONE) {
      if (event != SMO_CLOSE) smo_read_theme();
      return event;
   }
   if (now >= smo.alive_at) {
      const char *launcher = getenv("SOCKET_FRONTEND_PID");
      long pid = launcher ? strtol(launcher, NULL, 10) : 0;
      smo.alive_at = now + 250000;
      if (pid > 1 && kill((pid_t)pid, 0) != 0 && errno == ESRCH) return smo_fail();
   }
   return !smo_current() && now >= smo.deadline ? smo_fail() : SMO_NONE;
}

static const unsigned char *socket_overlay_frame(unsigned *width, unsigned *height, unsigned *flags, unsigned *serial) {
   /* ponytail: the count has 24 bits. No menu gets 16 million page changes. */
   if (!smo.open || !smo.ready || smo.flags >> 8 < smo.since) return NULL;
   *width = smo.width;
   *height = smo.height;
   *flags = smo.flags;
   *serial = smo.serial;
   return smo.pixels;
}
#endif

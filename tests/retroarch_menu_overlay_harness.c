/* Host program for tests/test_retroarch_menu_overlay.py.
 * It supplies the items that socket_quick_menu.h and RetroArch supply on the
 * device, and operates socket_menu_overlay.h from standard input.
 *
 * One command on each line:
 *   open, close, focus 0|1, pad MASK, tick, advance SECONDS, root,
 *   view SELECTED FIRST TOTAL TITLE STATUS ROW... (words without spaces; "-"
 *   is an empty text), limit BYTES (the largest size of a file; 0 is no limit)
 * Each command prints its result and the frame, then "end".
 */
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>
#include <features/features_cpu.h>

#define PATH_MAX_LENGTH 4096
static retro_time_t clock_offset;

retro_time_t cpu_features_get_time_usec(void) {
   struct timespec now;
   clock_gettime(CLOCK_MONOTONIC, &now);
   return (retro_time_t)now.tv_sec * 1000000 + now.tv_nsec / 1000 + clock_offset;
}

static bool socket_sleep_path(char *path, size_t size, const char *name) {
   return snprintf(path, size, "%s/%s", getenv("SOCKET_RUN"), name) < (int)size;
}

#include "socket_menu_overlay.h"

int main(void) {
   static const char *events[] = {"none", "close", "game", "cheats", "failed"};
   char line[4096];
   while (fgets(line, sizeof(line), stdin)) {
      struct rlimit limit;
      unsigned value, width, height, flags, serial, surface, ink;
      const unsigned char *frame;
      double seconds;
      if (sscanf(line, "advance %lf", &seconds) == 1) clock_offset += (retro_time_t)(seconds * 1000000);
      else if (sscanf(line, "limit %u", &value) == 1) {
         signal(SIGXFSZ, SIG_IGN);
         limit.rlim_cur = limit.rlim_max = RLIM_INFINITY;
         getrlimit(RLIMIT_FSIZE, &limit);
         limit.rlim_cur = value ? value : limit.rlim_max;
         setrlimit(RLIMIT_FSIZE, &limit);
      }
      else if (sscanf(line, "focus %u", &value) == 1) socket_overlay_focus(value);
      else if (sscanf(line, "pad %u", &value) == 1) socket_overlay_pad(value);
      else if (!strncmp(line, "root", 4)) socket_overlay_root();
      else if (!strncmp(line, "view ", 5)) {
         const char *words[16];
         unsigned count = 0;
         char *word = strtok(line + 5, " \n");
         for (; word && count < 16; word = strtok(NULL, " \n")) words[count++] = strcmp(word, "-") ? word : "";
         if (count >= 5) socket_overlay_view(atoi(words[0]), atoi(words[1]), atoi(words[2]), words[3], words[4], words + 5, count - 5);
      }
      else if (!strncmp(line, "open", 4)) printf("open %d\n", socket_overlay_open());
      else if (!strncmp(line, "close", 5)) socket_overlay_close();
      else if (!strncmp(line, "tick", 4)) printf("event %s\n", events[socket_overlay_tick()]);
      frame = socket_overlay_frame(&width, &height, &flags, &serial);
      if (frame) printf("frame %u %u %u %u %u %u\n", width, height, flags, serial, frame[0], frame[(size_t)width * height * 4 - 1]);
      if (socket_overlay_theme(&surface, &ink)) printf("theme %06x %06x\n", surface, ink);
      if (socket_overlay_views()) printf("views\n");
      printf("end\n");
      fflush(stdout);
   }
   return 0;
}

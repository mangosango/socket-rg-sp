/* Host program for tests/test_retroarch_device_menu.py.
 * It supplies the items that socket_quick_menu.h and RetroArch supply on the
 * device, and operates the Device Settings pages from standard input.
 *
 * One command on each line:
 *   open 0|1, close, tick, up, down, left, right, ok, back
 *   advance SECONDS            move the clock forward
 *   step brightness|volume -1|1
 * Each command prints the screen, then "end".
 */
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <features/features_cpu.h>

#define PATH_MAX_LENGTH 4096
enum menu_action { MENU_ACTION_NOOP, MENU_ACTION_UP, MENU_ACTION_DOWN, MENU_ACTION_LEFT,
   MENU_ACTION_RIGHT, MENU_ACTION_OK, MENU_ACTION_CANCEL };
static struct { unsigned selected; } socket_menu;
static retro_time_t clock_offset;
static char status[256];

retro_time_t cpu_features_get_time_usec(void) {
   struct timespec now;
   clock_gettime(CLOCK_MONOTONIC, &now);
   return (retro_time_t)now.tv_sec * 1000000 + now.tv_nsec / 1000 + clock_offset;
}

static void socket_menu_message(const char *text) {
   snprintf(status, sizeof(status), "%s", text);
   printf("message %s\n", text);
}

static bool socket_sleep_path(char *path, size_t size, const char *name) {
   const char *run = getenv("SOCKET_RUN");
   return snprintf(path, size, "%s/%s", run && *run ? run : "/tmp/socket", name) < (int)size;
}

#include "socket_device_menu.h"

int main(void) {
   static const char *names[] = {"", "up", "down", "left", "right", "ok", "back"};
   char line[64], text[512], word[16];
   bool open = false;
   while (fgets(line, sizeof(line), stdin)) {
      unsigned row, count, action = 0;
      double seconds;
      int direction;
      line[strcspn(line, "\n")] = 0;
      if (sscanf(line, "advance %lf", &seconds) == 1) clock_offset += (retro_time_t)(seconds * 1000000);
      else if (sscanf(line, "step %15s %d", word, &direction) == 2) socket_device_level_step(!strcmp(word, "volume"), direction);
      else if (sscanf(line, "open %u", &row) == 1) { socket_device_open(row); open = true; }
      else if (!strcmp(line, "close")) { socket_device_close(); open = false; }
      else for (row = 1; row < 7; row++) if (!strcmp(line, names[row])) action = row;
      /* The common menu calls the tick for each frame, then handles input. */
      if (open) socket_device_tick();
      count = socket_device_count();
      if (open && count && action == MENU_ACTION_UP) socket_menu.selected = (socket_menu.selected + count - 1) % count;
      else if (open && count && action == MENU_ACTION_DOWN) socket_menu.selected = (socket_menu.selected + 1) % count;
      else if (open && action) open = socket_device_action((enum menu_action)action, socket_menu.selected);
      printf("open %d\n", open);
      for (row = 0; row < 2; row++) {
         socket_device_level_label(row, text, sizeof(text));
         printf("level %s\n", text);
      }
      if (open) {
         printf("title %s\nstatus %s\n", socket_device_title(), status);
         for (row = 0; row < socket_device_count(); row++) {
            socket_device_label(row, text, sizeof(text));
            printf("row%c%s\n", row == socket_menu.selected ? '*' : ' ', text);
         }
      }
      printf("end\n");
      fflush(stdout);
   }
   return 0;
}

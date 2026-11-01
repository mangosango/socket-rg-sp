#ifndef SOCKET_CONTROLS_H
#define SOCKET_CONTROLS_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <features/features_cpu.h>

/* Each consumer owns its snapshot, including its initial stale-HUD suppression. */
typedef struct socket_controls
{
   uint32_t sequence;
   unsigned volume, brightness, temperature, kind;
   int valid;
   int64_t polled_at, shown_at;
} socket_controls_t;

static void socket_controls_poll(socket_controls_t *state, int64_t now)
{
   FILE *file;
   char path[4096], line[128], *cursor;
   const char *run;
   unsigned long long fields[6];
   unsigned i;
   size_t length;
   if (state->polled_at && now - state->polled_at < 50000)
      return;
   state->polled_at = now;
   run = getenv("SOCKET_RUN");
   if (snprintf(path, sizeof(path), "%s/controls", run && *run ? run : "/tmp/socket") >= (int)sizeof(path))
      return;
   file = fopen(path, "rb");
   if (!file)
      return;
   length = fread(line, 1, sizeof(line) - 1, file);
   if (ferror(file) || !feof(file))
   {
      fclose(file);
      return;
   }
   fclose(file);
   line[length] = 0;
   cursor = line;
   /* Version 2: sequence, volume, brightness, Slot temperature (0-9), kind (3 = temperature). */
   for (i = 0; i < 6; i++)
   {
      char *end;
      if (*cursor < '0' || *cursor > '9')
         return;
      fields[i] = strtoull(cursor, &end, 10);
      if (fields[i] > UINT32_MAX || *end != (i == 5 ? '\n' : ' '))
         return;
      cursor = end + 1;
   }
   if (cursor != line + length || fields[0] != 2 || fields[2] > 100 || fields[3] > 9
         || fields[4] > 9 || fields[5] > 3)
      return;
   if (state->valid && state->sequence != fields[1] && fields[5])
      state->shown_at = now;
   state->valid = 1;
   state->sequence = (uint32_t)fields[1];
   state->volume = (unsigned)fields[2];
   state->brightness = (unsigned)fields[3];
   state->temperature = (unsigned)fields[4];
   state->kind = (unsigned)fields[5];
}

#endif

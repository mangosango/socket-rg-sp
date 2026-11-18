/* Socket cheats page. The RetroArch cheat manager loads, stores and applies
 * the cheats. This file adds the page, the card cache and the download.
 *
 * Card layout below cheat_database_path:
 *   <System>/<Game> (<Device>).cht   Files from libretro-database/cht, or
 *                                    files that the user copied or changed.
 *                                    A download does not replace a file.
 *   <Platform ID>/<Name>.cht         Files that the user copied, for a
 *                                    platform without a <System> folder.
 *   <Core>/<ROM name>.cht            The cheats in use for one game.
 *                                    RetroArch loads this file at launch.
 *                                    The files page does not show it.
 */
#ifndef SOCKET_CHEATS_MENU_H
#define SOCKET_CHEATS_MENU_H
#include <ctype.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

#define SOCKET_CHEATS_LIST "https://api.github.com/repos/libretro/libretro-database/git/trees/master:cht/"
#define SOCKET_CHEATS_RAW "https://raw.githubusercontent.com/libretro/libretro-database/master/cht/"
#define SOCKET_CHEATS_MAX_FILES 12
/* The largest official file has 8035 cheats in 612 KB. RetroArch allocates
 * memory for the count in the file, so a file above these limits is not used. */
#define SOCKET_CHEATS_MAX_BYTES (1024 * 1024)
#define SOCKET_CHEATS_MAX_COUNT 16384

/* The Socket platform IDs are also the ROM extensions. Folder names are from
 * github.com/libretro/libretro-database/tree/master/cht. */
static const char *socket_cheats_system(const char *platform) {
   static const char *systems[][2] = {
      {"gb", "Nintendo - Game Boy"},
      {"gbc", "Nintendo - Game Boy Color"},
      {"gba", "Nintendo - Game Boy Advance"}};
   size_t i, j;
   if (platform) for (i = 0; i < sizeof(systems) / sizeof(*systems); i++) {
      for (j = 0; systems[i][0][j] && tolower((unsigned char)platform[j]) == systems[i][0][j]; j++);
      if (!systems[i][0][j] && !platform[j]) return systems[i][1];
   }
   return NULL;
}

/* The key is the title before the first region or device tag, letters and
 * digits only. The name must have no extension, or the .cht extension.
 * The key does not match a title with a moved article ("Legend of Zelda,
 * The"). The title list in the menu is the alternative for such a game. */
static void socket_cheats_key(const char *name, char *key, size_t size) {
   size_t length = strlen(name), n = 0;
   if (length > 4 && !strcmp(name + length - 4, ".cht")) length -= 4;
   for (; length && *name != '(' && *name != '['; name++, length--)
      if (isalnum((unsigned char)*name) && n + 1 < size) key[n++] = tolower((unsigned char)*name);
   key[n] = 0;
}

/* The platform ID becomes a card folder name. */
static bool socket_cheats_platform_ok(const char *platform) {
   size_t i;
   if (!platform || !*platform) return false;
   for (i = 0; platform[i]; i++)
      if (i >= 32 || (!isalnum((unsigned char)platform[i]) && platform[i] != '_' && platform[i] != '-')) return false;
   return true;
}

/* The name becomes a card file name. Accept only a plain .cht file name. */
static bool socket_cheats_name_ok(const char *name) {
   size_t length = strlen(name);
   const unsigned char *c;
   if (length < 5 || length > 200 || *name == '.' || strcmp(name + length - 4, ".cht")) return false;
   for (c = (const unsigned char *)name; *c; c++)
      if (*c < 0x20 || *c == 0x7f || strchr("/\\:*?\"<>|", *c)) return false;
   return true;
}

/* Get the next file name from a GitHub tree listing. Return the position
 * after the name, or NULL at the end. Ignore names that are not safe. */
static const char *socket_cheats_next(const char *json, char *name, size_t size) {
   while ((json = strstr(json, "\"path\""))) {
      size_t n = 0;
      json += 6;
      while (*json == ' ') json++;
      if (*json++ != ':') continue;
      while (*json == ' ') json++;
      if (*json++ != '"') continue;
      while (*json && *json != '"' && *json != '\\' && n + 1 < size) name[n++] = *json++;
      name[n] = 0;
      if (*json == '"' && socket_cheats_name_ok(name)) return json + 1;
   }
   return NULL;
}

static bool socket_cheats_encode(const char *text, char *out, size_t size) {
   size_t n = 0;
   for (; *text; text++) {
      if (n + 4 > size) return false;
      if (isalnum((unsigned char)*text) || strchr("-_.~", *text)) out[n++] = *text;
      else n += snprintf(out + n, 4, "%%%02X", (unsigned char)*text);
   }
   out[n] = 0;
   return true;
}

/* Accept only a complete cheat file with a safe size:
 * - one "cheats = N" line, N in decimal, 1 to SOCKET_CHEATS_MAX_COUNT,
 * - a complete code line for the last cheat, N - 1,
 * - no directive that makes RetroArch read a different file.
 * An error page or a cut transfer must not replace a file on the card. */
static bool socket_cheats_valid(const char *data, size_t size) {
   const char *end, *line, *next;
   char last[32];
   unsigned long count = 0;
   unsigned counts = 0;
   size_t prefix = 0;
   bool complete = false;
   int pass;
   if (!data || !size || size > SOCKET_CHEATS_MAX_BYTES || memchr(data, 0, size)) return false;
   end = data + size;
   for (pass = 0; pass < 2; pass++) {
      for (line = data; line < end; line = next) {
         const char *stop = (const char *)memchr(line, '\n', end - line);
         next = stop ? stop + 1 : end;
         if (!stop) stop = end;
         while (line < stop && (*line == ' ' || *line == '\t')) line++;
         if (pass == 1) {
            if ((size_t)(stop - line) > prefix && !memcmp(line, last, prefix)
                  && (stop < end || stop[-1] == '"')) complete = true;
            continue;
         }
         if (stop - line >= 8 && (!memcmp(line, "#include", 8) || !memcmp(line, "#referen", 8))) return false;
         if (stop - line < 7 || memcmp(line, "cheats", 6) || !strchr(" \t=", line[6])) continue;
         for (line += 6; line < stop && (*line == ' ' || *line == '\t'); line++);
         if (line == stop || *line++ != '=') return false;
         while (line < stop && (*line == ' ' || *line == '\t' || *line == '"')) line++;
         if (line == stop || !isdigit((unsigned char)*line)) return false;
         for (count = 0; line < stop && isdigit((unsigned char)*line); line++)
            if ((count = count * 10 + (*line - '0')) > SOCKET_CHEATS_MAX_COUNT) return false;
         while (line < stop && strchr(" \t\r\"", *line)) line++;
         if (line != stop || !count || ++counts > 1) return false;
      }
      if (counts != 1) return false;
      prefix = (size_t)snprintf(last, sizeof(last), "cheat%lu_code", count - 1);
   }
   return complete;
}

#ifndef SOCKET_CHEATS_PURE_ONLY
#include <stdlib.h>
#include <strings.h>

enum { SOCKET_CHEATS_MAIN, SOCKET_CHEATS_FILES, SOCKET_CHEATS_TITLES };

static struct {
   bool open, busy, pick;
   /* confirm is the row + 1 of a file that replaces the cheats in use. */
   unsigned page, confirm, queued, queue_at, saved, kept;
   /* Card files on the files page. Official file names on the titles page. */
   struct string_list *list;
   const char *system;
   char dir[PATH_MAX_LENGTH], key[128];
   /* The names of the last download. The files page shows them first. */
   char queue[SOCKET_CHEATS_MAX_FILES][204];
} socket_cheats;

/* A file is for this game if its title is the same, or if it is from the
 * last download. The user can select a different title for a download. */
static bool socket_cheats_match(const char *name) {
   char key[sizeof(socket_cheats.key)];
   unsigned i;
   socket_cheats_key(name, key, sizeof(key));
   if (key[0] && !strcmp(key, socket_cheats.key)) return true;
   for (i = 0; i < socket_cheats.queued; i++) if (!strcmp(name, socket_cheats.queue[i])) return true;
   return false;
}

/* Files for this game come first. Other files stay available below them. */
static int socket_cheats_compare(const void *a, const void *b) {
   const char *x = path_basename(((const struct string_list_elem *)a)->data);
   const char *y = path_basename(((const struct string_list_elem *)b)->data);
   int order = (int)socket_cheats_match(y) - (int)socket_cheats_match(x);
   return order ? order : strcasecmp(x, y);
}

static void socket_cheats_free_list(void) {
   if (socket_cheats.list) string_list_free(socket_cheats.list);
   socket_cheats.list = NULL;
}

static void socket_cheats_show(unsigned page, unsigned selected) {
   if (page == SOCKET_CHEATS_MAIN) socket_cheats_free_list();
   socket_cheats.page = page;
   socket_cheats.confirm = 0;
   socket_menu.selected = selected;
}

static unsigned socket_cheats_scan(void) {
   socket_cheats_free_list();
   socket_cheats.list = dir_list_new(socket_cheats.dir, "cht", false, false, false, false);
   if (!socket_cheats.list) return 0;
   qsort(socket_cheats.list->elems, socket_cheats.list->size,
         sizeof(*socket_cheats.list->elems), socket_cheats_compare);
   return (unsigned)socket_cheats.list->size;
}

/* Keep the cheats and their on/off state for the next launch of this game.
 * RetroArch reads this path in command_event_init_cheats(). The name comes
 * from RetroArch, which removes the archive name and the ROM extension. */
static bool socket_cheats_persist(void) {
   struct retro_system_info info;
   char dir[PATH_MAX_LENGTH], path[PATH_MAX_LENGTH], temporary[PATH_MAX_LENGTH];
   const char *database = config_get_ptr()->paths.path_cheat_database;
   const char *game = path_basename_nocompression(runloop_state_get_ptr()->name.cheatfile);
   if (string_is_empty(database) || string_is_empty(game) || !core_get_system_info(&info)
         || string_is_empty(info.library_name)
         || snprintf(dir, sizeof(dir), "%s/%s", database, info.library_name) >= (int)sizeof(dir)
         || snprintf(path, sizeof(path), "%s/%s", dir, game) >= (int)sizeof(path)
         || snprintf(temporary, sizeof(temporary), "%s.tmp", path) >= (int)sizeof(temporary)
         || !path_mkdir(dir)) return false;
   if (cheat_manager_save(temporary, NULL, true) && socket_sleep_publish(temporary, path)) return true;
   unlink(temporary);
   return false;
}

/* Load a card file. The cheats start in the off state, because a file for a
 * different region can have codes that are not correct for this game. A file
 * that does not load leaves the current cheats in use. */
static bool socket_cheats_load(const char *path) {
   void *data = NULL;
   int64_t size = 0;
   unsigned i;
   bool ok = filestream_read_file(path, &data, &size) && socket_cheats_valid((const char *)data, (size_t)size);
   free(data);
   if (!ok || !cheat_manager_load(path, false)) return false;
   for (i = 0; i < cheat_manager_get_size(); i++) cheat_manager_state.cheats[i].state = false;
   cheat_manager_apply_cheats(false);
   return true;
}

static void socket_cheats_fetch(void);

static void socket_cheats_saved(retro_task_t *task, void *task_data, void *user_data, const char *error) {
   http_transfer_data_t *data = (http_transfer_data_t *)task_data;
   char path[PATH_MAX_LENGTH];
   (void)task; (void)user_data;
   /* The file appears on the card only after the full file is written. */
   if (data && string_is_empty(error) && data->status == 200 && socket_cheats_valid(data->data, data->len)
         && snprintf(path, sizeof(path), "%s/%s", socket_cheats.dir, socket_cheats.queue[socket_cheats.queue_at]) < (int)sizeof(path)
         && path_mkdir(socket_cheats.dir) && socket_sleep_write(path, data->data, data->len))
      socket_cheats.saved++;
   socket_cheats.queue_at++;
   socket_cheats_fetch();
}

static void socket_cheats_fetch(void) {
   char url[1024], text[112], path[PATH_MAX_LENGTH];
   size_t n = strlcpy(url, SOCKET_CHEATS_RAW, sizeof(url));
   while (socket_cheats.queue_at < socket_cheats.queued) {
      /* A file on the card can have changes from the user. Do not replace it. */
      if (snprintf(path, sizeof(path), "%s/%s", socket_cheats.dir, socket_cheats.queue[socket_cheats.queue_at]) < (int)sizeof(path)
            && path_is_valid(path)) socket_cheats.kept++;
      else if (socket_cheats_encode(socket_cheats.system, url + n, sizeof(url) - n - 1)) {
         size_t end = strlen(url);
         url[end++] = '/';
         if (socket_cheats_encode(socket_cheats.queue[socket_cheats.queue_at], url + end, sizeof(url) - end)
               && task_push_http_transfer(url, true, NULL, socket_cheats_saved, NULL)) return;
      }
      socket_cheats.queue_at++;
   }
   socket_cheats.busy = false;
   if (socket_cheats.page == SOCKET_CHEATS_FILES) socket_cheats_scan();
   if (!socket_cheats.saved && !socket_cheats.kept) strlcpy(text, "Download failed. Saved cheats were kept.", sizeof(text));
   else snprintf(text, sizeof(text), "Cheat files: %u new, %u on the card and not changed, %u failed. Open Cheat files to load one.",
         socket_cheats.saved, socket_cheats.kept, socket_cheats.queued - socket_cheats.saved - socket_cheats.kept);
   socket_menu_message(text);
}

static void socket_cheats_listed(retro_task_t *task, void *task_data, void *user_data, const char *error) {
   http_transfer_data_t *data = (http_transfer_data_t *)task_data;
   union string_list_elem_attr attr = {0};
   char *json, name[sizeof(*socket_cheats.queue)], key[sizeof(socket_cheats.key)];
   const char *at;
   struct string_list *titles = NULL;
   unsigned nearest = 0;
   (void)task; (void)user_data;
   socket_cheats.queued = socket_cheats.queue_at = socket_cheats.saved = socket_cheats.kept = 0;
   if (!data || !string_is_empty(error) || data->status != 200 || !data->data || !data->len
         || !(json = (char *)malloc(data->len + 1))) {
      socket_cheats.busy = false;
      socket_menu_message("Cheat list download failed. Saved cheats were kept.");
      return;
   }
   memcpy(json, data->data, data->len);
   json[data->len] = 0;
   if (!socket_cheats.pick)
      for (at = json; socket_cheats.queued < SOCKET_CHEATS_MAX_FILES && (at = socket_cheats_next(at, name, sizeof(name)));)
         if (socket_cheats_match(name)) strlcpy(socket_cheats.queue[socket_cheats.queued++], name, sizeof(*socket_cheats.queue));
   if (socket_cheats.queued) {
      free(json);
      socket_cheats_fetch();
      return;
   }
   /* No file has the title of this game, or the user asked for the list.
    * Show all titles. Start at the title nearest to the name of the ROM. */
   socket_cheats.busy = false;
   if (socket_cheats.open && (titles = string_list_new()))
      for (at = json; (at = socket_cheats_next(at, name, sizeof(name)));) {
         socket_cheats_key(name, key, sizeof(key));
         if (strcmp(key, socket_cheats.key) < 0) nearest = (unsigned)titles->size + 1;
         if (!string_list_append(titles, name, attr)) break;
      }
   free(json);
   if (titles && titles->size) {
      socket_cheats_free_list();
      socket_cheats.list = titles;
      socket_cheats_show(SOCKET_CHEATS_TITLES, nearest < titles->size ? nearest : (unsigned)titles->size - 1);
      socket_menu_message(socket_cheats.pick ? "Select the title and region of this game."
            : "No title is the same as this game. Select the title and region.");
   } else {
      if (titles) string_list_free(titles);
      socket_menu_message(socket_cheats.open ? "The libretro database has no cheats for this system."
            : "No title is the same as this game. Open Cheats and select Choose a title.");
   }
}

/* A download starts only when the user selects one of the download rows. */
static void socket_cheats_download(bool pick) {
   char url[512], ready[PATH_MAX_LENGTH];
   size_t n = strlcpy(url, SOCKET_CHEATS_LIST, sizeof(url));
   if (socket_cheats.busy) socket_menu_message("The download is in progress.");
   else if (!socket_sleep_path(ready, sizeof(ready), "wifi.ready") || access(ready, F_OK) != 0)
      socket_menu_message("Offline. Saved cheats still work.");
   else if (!socket_cheats_encode(socket_cheats.system, url + n, sizeof(url) - n)
         || !task_push_http_transfer(url, true, NULL, socket_cheats_listed, NULL))
      socket_menu_message("Download failed. Saved cheats were kept.");
   else {
      socket_cheats.busy = true;
      socket_cheats.pick = pick;
      socket_menu_message("Getting the cheat list of the libretro database...");
   }
}

static void socket_cheats_open(unsigned section) {
   const char *database = config_get_ptr()->paths.path_cheat_database;
   const char *platform = getenv("SOCKET_GAME_PLATFORM");
   const char *folder;
   struct retro_system_info info;
   (void)section;
   socket_cheats.open = true;
   socket_cheats.page = SOCKET_CHEATS_MAIN;
   socket_cheats.confirm = 0;
   /* A download in progress keeps the system and the folder of its start. */
   if (socket_cheats.busy) return;
   socket_cheats.dir[0] = socket_cheats.key[0] = 0;
   /* The platform is correct for an archive or a ROM with a different name. */
   socket_cheats.system = socket_cheats_system(platform);
   if (!socket_cheats.system) socket_cheats.system = socket_cheats_system(path_get_extension(path_get(RARCH_PATH_CONTENT)));
   /* A platform without an official folder uses a folder with its ID. It
    * must not be the folder where RetroArch keeps the cheats in use. */
   folder = socket_cheats.system;
   if (!folder && socket_cheats_platform_ok(platform) && core_get_system_info(&info)
         && (string_is_empty(info.library_name) || strcasecmp(platform, info.library_name))) folder = platform;
   if (string_is_empty(database) || !folder) return;
   if (snprintf(socket_cheats.dir, sizeof(socket_cheats.dir), "%s/%s", database, folder) >= (int)sizeof(socket_cheats.dir))
      socket_cheats.dir[0] = 0;
   socket_cheats_key(path_basename_nocompression(runloop_state_get_ptr()->name.cheatfile), socket_cheats.key, sizeof(socket_cheats.key));
}

static void socket_cheats_close(void) {
   socket_cheats.open = false;
   socket_cheats.page = SOCKET_CHEATS_MAIN;
   socket_cheats.confirm = 0;
   socket_cheats_free_list();
}

/* A move to a different row cancels the question about the cheats in use. */
static void socket_cheats_tick(void) {
   if (socket_cheats.confirm != socket_menu.selected + 1) socket_cheats.confirm = 0;
}

static const char *socket_cheats_title(void) {
   static const char *titles[] = {"Cheats", "Cheat files", "libretro cheat titles"};
   return titles[socket_cheats.page];
}

/* Main page rows: Cheat files. Then, for a known system, the two download
 * rows. Then, with cheats loaded, Apply cheats again and one row per cheat.
 * This is the row of the first cheat. */
static unsigned socket_cheats_first(void) { return socket_cheats.system ? 4 : 2; }

static unsigned socket_cheats_count(void) {
   if (!socket_cheats.dir[0]) return 1;
   if (socket_cheats.page != SOCKET_CHEATS_MAIN) return socket_cheats.list && socket_cheats.list->size ? (unsigned)socket_cheats.list->size : 1;
   return socket_cheats_first() - (cheat_manager_get_size() ? 0 : 1) + cheat_manager_get_size();
}

static void socket_cheats_label(unsigned row, char *text, size_t size) {
   unsigned first = socket_cheats_first();
   if (!socket_cheats.dir[0]) snprintf(text, size, "Cheats are not available for this game");
   else if (socket_cheats.page != SOCKET_CHEATS_MAIN) {
      if (!socket_cheats.list || row >= socket_cheats.list->size) snprintf(text, size, "No cheat files");
      else {
         snprintf(text, size, "%s", path_basename(socket_cheats.list->elems[row].data));
         if (strlen(text) > 4) text[strlen(text) - 4] = 0;
      }
   }
   else if (row == 0) snprintf(text, size, "Cheat files");
   else if (row == 1 && socket_cheats.system) snprintf(text, size, socket_cheats.busy ? "Downloading cheats..." : "Download cheats for this game");
   else if (row == 2 && socket_cheats.system) snprintf(text, size, "Choose a title in the libretro list");
   else if (row == first - 1) snprintf(text, size, "Apply cheats again");
   else if (row - first < cheat_manager_get_size()) {
      const char *desc = cheat_manager_get_desc(row - first);
      if (string_is_empty(desc)) desc = cheat_manager_get_code(row - first);
      snprintf(text, size, "[%s] %s", cheat_manager_get_code_state(row - first) ? "On" : "Off", string_is_empty(desc) ? "Cheat" : desc);
   }
   else text[0] = 0;
}

static bool socket_cheats_action(enum menu_action action, unsigned row) {
   char text[96];
   unsigned first = socket_cheats_first();
   if (action == MENU_ACTION_CANCEL) {
      if (socket_cheats.page == SOCKET_CHEATS_MAIN) return false;
      socket_cheats_show(SOCKET_CHEATS_MAIN, 0);
      return true;
   }
   if (!socket_cheats.dir[0] || (action != MENU_ACTION_OK && action != MENU_ACTION_LEFT && action != MENU_ACTION_RIGHT)) return true;
   if (socket_cheats.page != SOCKET_CHEATS_MAIN) {
      if (!socket_cheats.list || row >= socket_cheats.list->size) return true;
      /* Left and Right move 10 rows. The lists can have more than 1000 rows. */
      if (action == MENU_ACTION_LEFT) socket_menu.selected = row < 10 ? 0 : row - 10;
      else if (action == MENU_ACTION_RIGHT) socket_menu.selected = row + 10 < socket_cheats.list->size ? row + 10 : (unsigned)socket_cheats.list->size - 1;
      else if (socket_cheats.page == SOCKET_CHEATS_TITLES) {
         if (socket_cheats.busy) { socket_menu_message("The download is in progress."); return true; }
         socket_cheats.busy = true;
         socket_cheats.queued = 1;
         socket_cheats.queue_at = socket_cheats.saved = socket_cheats.kept = 0;
         strlcpy(socket_cheats.queue[0], socket_cheats.list->elems[row].data, sizeof(*socket_cheats.queue));
         socket_cheats_show(SOCKET_CHEATS_MAIN, 0);
         socket_menu_message("Downloading the cheat file...");
         socket_cheats_fetch();
      }
      else if (cheat_manager_get_size() && socket_cheats.confirm != row + 1) {
         socket_cheats.confirm = row + 1;
         socket_menu_message("This file replaces the cheats in use for this game. Press A again, or B to cancel.");
      }
      else if (!socket_cheats_load(socket_cheats.list->elems[row].data)) {
         socket_cheats.confirm = 0;
         socket_menu_message("This cheat file is not complete or not correct. It was not loaded.");
      }
      else {
         snprintf(text, sizeof(text), socket_cheats_persist() ? "Loaded %u cheats. All are off. Select a cheat to turn it on."
               : "Loaded %u cheats for this session. The card did not save them.", cheat_manager_get_size());
         socket_menu_message(text);
         socket_cheats_show(SOCKET_CHEATS_MAIN, first);
      }
   }
   else if (row >= first && row - first < cheat_manager_get_size()) {
      cheat_manager_state.cheats[row - first].state = !cheat_manager_state.cheats[row - first].state;
      cheat_manager_apply_cheats(false);
      if (!socket_cheats_persist()) socket_menu_message("The card did not save this cheat setting.");
   }
   else if (action != MENU_ACTION_OK) return true;
   else if (row == 0) {
      if (socket_cheats_scan()) socket_cheats_show(SOCKET_CHEATS_FILES, 0);
      else socket_menu_message(socket_cheats.system ? "No cheat files on the card. Select Download, or copy .cht files."
            : "No cheat files on the card for this platform.");
   }
   else if (socket_cheats.system && row < 3) socket_cheats_download(row == 2);
   else if (row == first - 1) {
      cheat_manager_apply_cheats(false);
      socket_menu_message("Cheats applied.");
   }
   return true;
}
#endif
#endif

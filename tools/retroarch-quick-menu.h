/* Socket uses RetroArch menu input and commands with a small in-game panel. */
#ifndef SOCKET_QUICK_MENU_H
#define SOCKET_QUICK_MENU_H
#include <stddef.h>
#include <stdbool.h>
bool socket_quick_menu_active(void);
unsigned socket_quick_menu_selection(void);
const char *socket_quick_menu_status(void);
void socket_quick_menu_load_result(bool ok);
unsigned socket_quick_menu_count(void);
const char *socket_quick_menu_title(void);
void socket_quick_menu_label(unsigned row, char *text, size_t size);
/* socket_quick_menu_overlay() is true while the Device Settings scene of the
 * launcher is the page: that scene shows the levels itself.
 * socket_quick_menu_shared() is true while the launcher scene draws the page:
 * Device Settings, and each other page if the launcher has version 2 of
 * menu.theme. RetroArch shows the levels above those other pages. Then
 * socket_quick_menu_frame() gives its newest frame, or NULL before the first
 * one. serial changes for each new frame. Bit 0 of flags: the color has the
 * alpha in it. */
bool socket_quick_menu_overlay(void);
bool socket_quick_menu_shared(void);
const unsigned char *socket_quick_menu_frame(unsigned *width, unsigned *height, unsigned *flags, unsigned *serial);
/* The panel color and the text color of the launcher, as 0xrrggbb, for the
 * native pages. False means "use the default dark colors". */
bool socket_quick_menu_theme(unsigned *surface, unsigned *ink);
#endif

#ifdef SOCKET_QUICK_MENU_IMPLEMENTATION
#include "gfx/video_shader_parse.h"
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
bool content_load_state_in_progress(void *data);
static struct { bool active, confirm_load, loading, overlay, wait_release; unsigned page, selected, root_row; char status[128]; } socket_menu;
static struct { bool held, failed, loading, boot_checked, sram, quiet, was_muted; char token[32], ack[32]; } socket_sleep;
static void socket_menu_open(void);
static void socket_menu_leave_module(void);
static void socket_sleep_load_result(bool ok);
static bool socket_overlay_open(void);
static void socket_overlay_close(void);
static bool socket_overlay_views(void);
/* SOCKET_ROOT is Device Settings. The launcher draws it and its radio pages
 * (socket_menu_overlay.h). If the launcher does not answer, socket_menu.overlay
 * is false and the pages of socket_device_menu.h replace them. SOCKET_MAIN is
 * the game menu. The cheats pages come from socket_cheats_menu.h. This menu
 * always operates the other pages. A launcher of version 2 draws them from
 * the lines of socket_menu_show(). If not, gl2_socket_menu() draws them. */
enum { SOCKET_ROOT, SOCKET_MAIN, SOCKET_CORE, SOCKET_SCREEN, SOCKET_GAMEPLAY, SOCKET_CONTROLS,
   SOCKET_DEVICE, SOCKET_CHEATS };
enum { SOCKET_ROOT_WIFI = 2, SOCKET_ROOT_GAME = 4, SOCKET_ROOT_CHEATS };

bool socket_quick_menu_active(void) { return socket_menu.active; }
unsigned socket_quick_menu_selection(void) { return socket_menu.selected; }
const char *socket_quick_menu_status(void) { return socket_menu.status; }

static void socket_menu_message(const char *text) {
   strlcpy(socket_menu.status, text, sizeof(socket_menu.status));
   RARCH_LOG("[Socket Menu] %s\n", text);
   /* The launcher scene shows the status of a view. Do not show it twice. */
   if (socket_menu.active && socket_menu.overlay && socket_menu.page != SOCKET_ROOT && socket_overlay_views()) return;
   runloop_msg_queue_push(text, strlen(text), 1, 240, true, NULL,
         MESSAGE_QUEUE_ICON_DEFAULT, MESSAGE_QUEUE_CATEGORY_WARNING);
}

void socket_quick_menu_load_result(bool ok) {
   if (socket_sleep.loading) { socket_sleep_load_result(ok); return; }
   if (socket_menu.loading) {
      socket_menu.loading = false;
      socket_menu_message(ok ? "State loaded." : "Load failed. Game is still running.");
   }
}

static bool socket_menu_save_exit(void) {
   if (socket_sleep.failed) { command_event(CMD_EVENT_QUIT, NULL); return true; }
   content_wait_for_save_state_task();
   if (command_event_save_auto_state()) {
      command_event(CMD_EVENT_QUIT, NULL);
      return true;
   }
   socket_menu_message("Save failed. Game is still running.");
   return false;
}

/* Each file contains only menu settings. Keep the previous file on failure. */
static bool socket_menu_write_config(config_file_t *conf, const char *path) {
   char temporary[PATH_MAX_LENGTH];
   bool ok = false;
   if (conf && path && *path && snprintf(temporary, sizeof(temporary), "%s.tmp", path)
         < (int)sizeof(temporary)) {
      ok = config_file_write(conf, temporary, false)
         && filestream_rename(temporary, path) == 0;
      if (!ok) filestream_delete(temporary);
   }
   if (conf) config_file_free(conf);
   if (!ok) socket_menu_message("Settings could not be saved. Changes apply to this game.");
   return ok;
}

static void socket_menu_save_settings(bool core) {
   settings_t *s = config_get_ptr();
   config_file_t *conf = config_file_new_alloc();
   const char *path = getenv(core ? "SOCKET_CORE_OPTIONS" : "SOCKET_MENU_CONFIG");
   if (conf) {
      if (core) core_option_manager_flush(runloop_state_get_ptr()->core_options, conf);
      else {
         config_set_string(conf, "video_shader_enable", s->bools.video_shader_enable ? "true" : "false");
         config_set_string(conf, "video_scale_integer", s->bools.video_scale_integer ? "true" : "false");
         config_set_uint(conf, "aspect_ratio_index", s->uints.video_aspect_ratio_idx);
         config_set_int(conf, "state_slot", s->ints.state_slot);
         config_set_float(conf, "fastforward_ratio", s->floats.fastforward_ratio);
         config_set_string(conf, "audio_fastforward_mute", s->bools.audio_fastforward_mute ? "true" : "false");
         config_set_string(conf, "rewind_enable", s->bools.rewind_enable ? "true" : "false");
      }
   }
   socket_menu_write_config(conf, path);
}

static void socket_menu_close(void) {
   if (socket_sleep.failed) return;
   socket_menu.active = false;
   socket_overlay_close();
   retroarch_menu_running_finished(false);
}

static void socket_menu_open(void) {
   socket_menu_leave_module();
   socket_menu.active = true;
   /* After a failed resume the menu has only the native Exit page. */
   socket_overlay_close();
   socket_menu.overlay = !socket_sleep.failed && socket_overlay_open();
   /* The game row has the first focus: MENU, A opens the game menu. After a
    * failed resume, Exit is the only safe action. */
   socket_menu.page = socket_sleep.failed ? SOCKET_MAIN : SOCKET_ROOT;
   socket_menu.selected = socket_sleep.failed ? 9 : SOCKET_ROOT_GAME;
   socket_menu.confirm_load = false;
   socket_menu.status[0] = 0;
   if (socket_sleep.failed) strlcpy(socket_menu.status, "Resume failed. Game is paused. Select Exit to leave safely.", sizeof(socket_menu.status));
   RARCH_LOG("[Socket Menu] Open.\n");
}

/* Acknowledgements follow durable state and manifest writes. */
static bool socket_sleep_path(char *path, size_t size, const char *name) {
   const char *run = getenv("SOCKET_RUN");
   return snprintf(path, size, "%s/%s", run && *run ? run : "/tmp/socket", name) < (int)size;
}

static bool socket_sleep_sync_dir(const char *path) {
   char parent[PATH_MAX_LENGTH], *slash;
   int fd;
   bool ok;
   if (strlcpy(parent, path, sizeof(parent)) >= sizeof(parent)) return false;
   slash = strrchr(parent, '/');
   if (!slash) strlcpy(parent, ".", sizeof(parent));
   else if (slash == parent) slash[1] = 0;
   else *slash = 0;
   fd = open(parent, O_RDONLY | O_DIRECTORY);
   if (fd < 0) return false;
   ok = fsync(fd) == 0;
   if (close(fd) != 0) ok = false;
   return ok;
}

static bool socket_sleep_publish(const char *temporary, const char *path) {
   int fd = open(temporary, O_RDONLY);
   bool ok;
   if (fd < 0) return false;
   ok = fsync(fd) == 0;
   if (close(fd) != 0) ok = false;
   return ok && rename(temporary, path) == 0 && socket_sleep_sync_dir(path);
}

static bool socket_sleep_write(const char *path, const void *data, size_t size) {
   char temporary[PATH_MAX_LENGTH];
   FILE *file;
   bool ok;
   if (!path || !*path || snprintf(temporary, sizeof(temporary), "%s.tmp", path) >= (int)sizeof(temporary)) return false;
   file = fopen(temporary, "wb");
   if (!file) return false;
   ok = fwrite(data, 1, size, file) == size;
   if (fclose(file) != 0) ok = false;
   if (ok) ok = socket_sleep_publish(temporary, path);
   if (!ok) unlink(temporary);
   return ok;
}

static bool socket_sleep_clear_manifest(void) {
   const char *path = getenv("SOCKET_RESUME_MANIFEST");
   if (!path || !*path) return false;
   if (unlink(path) != 0 && errno != ENOENT) return false;
   return socket_sleep_sync_dir(path);
}

static bool socket_sleep_state_path(char *path, size_t size) {
   return runloop_get_savestate_path(path, size, 0)
      && strlcat(path, ".sleep", size) < size;
}

static bool socket_sleep_token(const char *name, char *token, size_t size) {
   char path[PATH_MAX_LENGTH], data[34];
   FILE *file;
   size_t n, i;
   if (!socket_sleep_path(path, sizeof(path), name) || !(file = fopen(path, "rb"))) return false;
   n = fread(data, 1, sizeof(data), file);
   fclose(file);
   if (n < 2 || n > size || data[n-1] != '\n') return false;
   for (i = 0; i < n-1; i++) if (data[i] < '0' || data[i] > '9') return false;
   memcpy(token, data, n-1);
   token[n-1] = 0;
   return true;
}

static bool socket_sleep_ack(const char *name, const char *token, bool ok) {
   char path[PATH_MAX_LENGTH], text[48];
   int n = snprintf(text, sizeof(text), "%s %s\n", token, ok ? "ok" : "error");
   return socket_sleep_path(path, sizeof(path), name) && socket_sleep_write(path, text, n);
}

static bool socket_sleep_save(void) {
   char path[PATH_MAX_LENGTH], temporary[PATH_MAX_LENGTH], descriptor[4097];
   const char *source = getenv("SOCKET_GAME_DESCRIPTOR");
   const char *manifest = getenv("SOCKET_RESUME_MANIFEST");
   FILE *file;
   size_t n;
   bool ok;
   if (socket_sleep.failed || socket_menu.loading || content_load_state_in_progress(NULL)
         || !source || !manifest || !(file = fopen(source, "rb"))) return false;
   n = fread(descriptor, 1, sizeof(descriptor), file);
   ok = !ferror(file) && n > 0 && n < sizeof(descriptor);
   fclose(file);
   if (!ok || !socket_sleep_state_path(path, sizeof(path))
         || snprintf(temporary, sizeof(temporary), "%s.pending", path) >= (int)sizeof(temporary)) return false;
   content_wait_for_save_state_task();
   ok = content_auto_save_state(temporary) && socket_sleep_publish(temporary, path);
   if (!ok) { unlink(temporary); return false; }
   return socket_sleep_write(manifest, descriptor, n);
}

static void socket_sleep_load_result(bool ok) {
   socket_sleep.loading = false;
   /* A failed restore must not be attempted again on the next boot. */
   if (!socket_sleep_clear_manifest()) ok = false;
   if (!socket_sleep_ack(socket_sleep.ack, socket_sleep.token, ok)) ok = false;
   socket_sleep.failed = socket_sleep.held = !ok;
   if (!ok) {
      config_get_ptr()->bools.savestate_auto_save = false;
      if (!(menu_state_get_ptr()->flags & MENU_ST_FLAG_ALIVE))
         retroarch_menu_running();
      socket_menu_open();
      socket_menu_message("Resume failed. Game is paused. Select Exit to leave safely.");
   } else {
      if (socket_sleep.sram) {
         runloop_state_get_ptr()->flags |= RUNLOOP_FLAG_USE_SRAM;
#ifdef HAVE_THREADS
         if (autosave_init(config_get_ptr()->bools.save_file_compression,
                  config_get_ptr()->uints.autosave_interval))
            runloop_state_get_ptr()->flags |= RUNLOOP_FLAG_AUTOSAVE;
#endif
      }
      /* Success is silent, as on a normal launch. Failures stay visible. */
      RARCH_LOG("[Socket] Sleep state restored.\n");
   }
}

static void socket_sleep_load(const char *ack, const char *token) {
   char path[PATH_MAX_LENGTH];
   runloop_state_t *runloop_st = runloop_state_get_ptr();
   socket_sleep.held = socket_sleep.loading = true;
   strlcpy(socket_sleep.ack, ack, sizeof(socket_sleep.ack));
   strlcpy(socket_sleep.token, token, sizeof(socket_sleep.token));
   /* Stop the autosave thread before a core can partly reject a state. */
   socket_sleep.sram = (runloop_st->flags & RUNLOOP_FLAG_USE_SRAM) != 0;
#ifdef HAVE_THREADS
   if (socket_sleep.sram) autosave_deinit();
#endif
   runloop_st->flags &= ~(RUNLOOP_FLAG_USE_SRAM | RUNLOOP_FLAG_AUTOSAVE);
   if (socket_menu.loading || content_load_state_in_progress(NULL)
         || !socket_sleep_state_path(path, sizeof(path)) || !content_load_state(path, false, true))
      socket_sleep_load_result(false);
}

/* Sleep and timed shutdown keep the game silent until wake. The helper can
 * stop the process in the middle of a frame; that frame finishes on resume. */
static void socket_sleep_audio(bool on) {
   audio_driver_state_t *audio = audio_state_get_ptr();
   if (on == !socket_sleep.quiet) return;
   if (!on) socket_sleep.was_muted = audio->mute_enable;
   audio->mute_enable = on ? socket_sleep.was_muted : true;
   command_event(on ? CMD_EVENT_AUDIO_START : CMD_EVENT_AUDIO_STOP, NULL);
   socket_sleep.quiet = !on;
}

/* The Bluetooth worker writes the headset address to bluetooth.audio and
 * changes the default ALSA device. Open the audio device again after each
 * change. The first poll only records the route. Sleep and the menu keep
 * audio stopped, so the change waits until the game runs. */
static void socket_audio_route(retro_time_t now) {
   static retro_time_t poll_at;
   static bool known;
   static char route[32];
   char path[PATH_MAX_LENGTH], current[32] = "";
   FILE *file;
   if (now < poll_at || socket_sleep.quiet || socket_sleep.held || socket_sleep.loading
         || (menu_state_get_ptr()->flags & MENU_ST_FLAG_ALIVE)) return;
   poll_at = now + 500000;
   if (socket_sleep_path(path, sizeof(path), "bluetooth.audio") && (file = fopen(path, "rb"))) {
      current[fread(current, 1, sizeof(current) - 1, file)] = 0;
      fclose(file);
   }
   if (known && strcmp(current, route)) {
      RARCH_LOG("[Socket] Audio route changed to %s.\n", *current ? "Bluetooth" : "the speaker");
      command_event(CMD_EVENT_AUDIO_REINIT, NULL);
   }
   known = true;
   strlcpy(route, current, sizeof(route));
}

static void socket_menu_poweroff(retro_time_t now) {
   static char previous_sleep[32], previous_wake[32], previous_off[32];
   char token[32], current[32];
   bool ok;
   socket_audio_route(now);
   /* MENU closed the menu while a device or cheats page was open. */
   if (!socket_menu.active) { socket_menu_leave_module(); socket_overlay_close(); }
   if (!socket_sleep.boot_checked) {
      const char *load = getenv("SOCKET_RESUME_LOAD");
      socket_sleep.boot_checked = true;
      if (load && !strcmp(load, "1")) socket_sleep_load("resume.ack", "0");
   }
   if (!socket_sleep.loading && socket_sleep_token("wake.request", token, sizeof(token)) && strcmp(token, previous_wake)) {
      strlcpy(previous_wake, token, sizeof(previous_wake));
      /* Wake ends sleep and failed shutdown saves. Restore audio. */
      socket_sleep_audio(true);
      if (socket_sleep.held) {
         ok = !socket_sleep.failed && socket_sleep_clear_manifest();
         if (socket_sleep_ack("wake.ack", token, ok) && ok) {
            socket_sleep.held = false;
            RARCH_LOG("[Socket] Sleep state resumed.\n");
         }
      } else socket_sleep_ack("wake.ack", token, true);
   }
   if (socket_sleep_token("sleep.request", token, sizeof(token)) && strcmp(token, previous_sleep)) {
      strlcpy(previous_sleep, token, sizeof(previous_sleep));
      socket_menu_leave_module();
      /* The launcher stops its radio work and erases the typed text. The
       * menu sends a new open request if it stays open. */
      socket_overlay_close();
      socket_sleep_audio(false);
      ok = !socket_sleep.held && socket_sleep_save();
      if (socket_sleep_token("sleep.request", current, sizeof(current)) && !strcmp(token, current)) {
         if (ok) socket_sleep.held = true;
         if (!socket_sleep_ack("sleep.ack", token, ok) && ok) {
            socket_sleep.held = false;
            socket_sleep_clear_manifest();
         }
      }
      else if (!socket_sleep.held) socket_sleep_clear_manifest();
      if (!ok) {
         if (!socket_sleep.held) socket_sleep_clear_manifest();
         socket_menu_message("Sleep save failed. Game is still running.");
      }
   }
   if (socket_sleep_token("poweroff.request", token, sizeof(token)) && strcmp(token, previous_off)) {
      strlcpy(previous_off, token, sizeof(previous_off));
      socket_menu_leave_module();
      socket_overlay_close();
      socket_sleep_audio(false);
      ok = !socket_sleep.loading && socket_sleep_save();
      if (socket_sleep_token("poweroff.request", current, sizeof(current)) && !strcmp(token, current)
            && socket_sleep_ack("poweroff.ack", token, ok) && ok) {
         config_get_ptr()->bools.savestate_auto_save = false;
         command_event(CMD_EVENT_QUIT, NULL);
      }
      else if (ok && !socket_sleep.held) socket_sleep_clear_manifest();
      if (!ok) {
         if (!socket_sleep.held) socket_sleep_clear_manifest();
         socket_menu_message("Poweroff save failed. Game is still running.");
      }
   }
}

/* Visible core options retain their core-provided labels and value ranges. */
static size_t socket_menu_core_index(unsigned row) {
   core_option_manager_t *options = runloop_state_get_ptr()->core_options;
   size_t i;
   if (options) for (i = 0; i < options->size; i++)
      if (core_option_manager_get_visible(options, i) && row-- == 0) return i;
   return (size_t)-1;
}

static size_t socket_menu_color_index(void) {
   core_option_manager_t *options = runloop_state_get_ptr()->core_options;
   size_t index;
   if (options && (core_option_manager_get_idx(options, "mgba_color_correction", &index)
         || core_option_manager_get_idx(options, "gpsp_color_correction", &index))) return index;
   return (size_t)-1;
}

/* Module contract, for X = device and X = cheats. Each function is static.
 * RetroArch calls it on the main thread while the game is paused.
 * - socket_X_open(section): show the first page. Device sections: 0 is
 *   Wi-Fi, 1 is Bluetooth. Cheats has section 0 only.
 * - socket_X_close(): stop pending work. It is safe to call this twice.
 * - socket_X_tick(): runs one time for each frame while the page is open.
 * - socket_X_title(), socket_X_count(), socket_X_label(row, text, size).
 * - socket_X_action(action, row): gets OK, LEFT, RIGHT and CANCEL. It returns
 *   false to go back to Device Settings. This menu moves the selection for UP
 *   and DOWN. The module can write socket_menu.selected.
 * - socket_device_level_label(volume, text, size) and
 *   socket_device_level_step(volume, direction): the brightness and volume rows.
 * Use socket_menu_message() for status text. Do not show secrets. */
#include "socket_menu_overlay.h"
#include "socket_device_menu.h"
#include "socket_cheats_menu.h"

bool socket_quick_menu_overlay(void) {
   return socket_menu.active && socket_menu.overlay && socket_menu.page == SOCKET_ROOT;
}

bool socket_quick_menu_shared(void) {
   return socket_menu.active && socket_menu.overlay && (socket_menu.page == SOCKET_ROOT || socket_overlay_views());
}

const unsigned char *socket_quick_menu_frame(unsigned *width, unsigned *height, unsigned *flags, unsigned *serial) {
   return socket_overlay_frame(width, height, flags, serial);
}

bool socket_quick_menu_theme(unsigned *surface, unsigned *ink) {
   return socket_menu.overlay && socket_overlay_theme(surface, ink);
}

static void socket_menu_leave_module(void) {
   if (socket_menu.page == SOCKET_DEVICE) socket_device_close();
   else if (socket_menu.page == SOCKET_CHEATS) socket_cheats_close();
   else return;
   RARCH_LOG("[Socket Menu] Page closed.\n");
   socket_menu.page = SOCKET_ROOT;
   socket_menu.selected = socket_menu.root_row;
   socket_overlay_focus(true);
}

unsigned socket_quick_menu_count(void) {
   if (socket_menu.page == SOCKET_ROOT) return 6;
   if (socket_menu.page == SOCKET_DEVICE) return socket_device_count();
   if (socket_menu.page == SOCKET_CHEATS) return socket_cheats_count();
   if (socket_menu.page == SOCKET_MAIN) return 10;
   if (socket_menu.page == SOCKET_SCREEN || socket_menu.page == SOCKET_GAMEPLAY) return 3;
   if (socket_menu.page == SOCKET_CONTROLS) return 3;
   if (socket_menu.page == SOCKET_CORE) {
      core_option_manager_t *options = runloop_state_get_ptr()->core_options;
      unsigned count = 0;
      size_t i;
      if (options) for (i = 0; i < options->size; i++)
         if (core_option_manager_get_visible(options, i)) count++;
      return count ? count : 1;
   }
   return 0;
}

const char *socket_quick_menu_title(void) {
   static const char *titles[] = {"Device Settings", "Game", "Core options", "Screen", "Gameplay", "Controls"};
   if (socket_menu.page == SOCKET_DEVICE) return socket_device_title();
   if (socket_menu.page == SOCKET_CHEATS) return socket_cheats_title();
   return titles[socket_menu.page];
}

void socket_quick_menu_label(unsigned row, char *text, size_t size) {
   settings_t *s = config_get_ptr();
   core_option_manager_t *options = runloop_state_get_ptr()->core_options;
   size_t index;
   const char *value;
   static const char *main_rows[] = {"Resume", "Core options", "State slot", "Save state",
      "Load state", "Screenshot", "Screen", "Gameplay", "Controls", "Save & Exit"};
   static const char *root_rows[] = {"Wi-Fi", "Bluetooth", "Game", "Cheats"};
   if (size) *text = 0;
   if (row >= socket_quick_menu_count()) return;
   if (socket_menu.page == SOCKET_ROOT) {
      if (row < SOCKET_ROOT_WIFI) socket_device_level_label(row == 1, text, size);
      else snprintf(text, size, "%s", root_rows[row - SOCKET_ROOT_WIFI]);
   } else if (socket_menu.page == SOCKET_DEVICE) socket_device_label(row, text, size);
   else if (socket_menu.page == SOCKET_CHEATS) socket_cheats_label(row, text, size);
   else if (socket_menu.page == SOCKET_MAIN) {
      if (row == 2) snprintf(text, size, "State slot                 %d", s->ints.state_slot);
      else if (row == 4 && socket_menu.confirm_load) snprintf(text, size, "Load slot %d: press A again", s->ints.state_slot);
      else snprintf(text, size, "%s", row == 9 && socket_sleep.failed ? "Exit" : main_rows[row]);
   } else if (socket_menu.page == SOCKET_CORE) {
      index = socket_menu_core_index(row);
      if (index == (size_t)-1) snprintf(text, size, "No core options available");
      else snprintf(text, size, "%s: %s", core_option_manager_get_desc(options, index, false),
            core_option_manager_get_val_label(options, index));
   } else if (socket_menu.page == SOCKET_SCREEN) {
      if (row == 0) snprintf(text, size, "Shader                    %s", s->bools.video_shader_enable ? "On" : "Off");
      else if (row == 1) {
         index = socket_menu_color_index();
         value = index == (size_t)-1 ? "Not available" : core_option_manager_get_val_label(options, index);
         snprintf(text, size, "Color correction          %s", value);
      } else snprintf(text, size, "Scaling                   %s", s->bools.video_scale_integer ? "Integer" :
            s->uints.video_aspect_ratio_idx == ASPECT_RATIO_FULL ? "Stretch" : "Aspect");
   } else if (socket_menu.page == SOCKET_GAMEPLAY) {
      if (row == 0) snprintf(text, size, "Fast-forward speed        %.0fx", s->floats.fastforward_ratio);
      else if (row == 1) snprintf(text, size, "Fast-forward sound        %s", s->bools.audio_fastforward_mute ? "Off" : "On");
      else snprintf(text, size, "Rewind                    %s", s->bools.rewind_enable ? "On" : "Off");
   } else {
      static const char *controls[] = {"L2  Hold to rewind", "R2  Hold to fast-forward", "MENU  Hold 1 second to save & exit"};
      snprintf(text, size, "%s", controls[row]);
   }
}

static enum menu_action socket_menu_input(input_bits_t *bits, retro_time_t now) {
   static unsigned held = (unsigned)-1;
   static retro_time_t repeat_at;
   static const unsigned keys[] = {RETRO_DEVICE_ID_JOYPAD_UP, RETRO_DEVICE_ID_JOYPAD_DOWN,
      RETRO_DEVICE_ID_JOYPAD_LEFT, RETRO_DEVICE_ID_JOYPAD_RIGHT,
      RETRO_DEVICE_ID_JOYPAD_A, RETRO_DEVICE_ID_JOYPAD_B};
   static const enum menu_action actions[] = {MENU_ACTION_UP, MENU_ACTION_DOWN,
      MENU_ACTION_LEFT, MENU_ACTION_RIGHT, MENU_ACTION_OK, MENU_ACTION_CANCEL};
   unsigned i;
   /* MENU can share a game binding. Wait for its release before navigation. */
   if (input_state_get_ptr()->flags & INP_FLAG_MENU_PRESS_PENDING) {
      held = (unsigned)-1;
      return MENU_ACTION_NOOP;
   }
   if (socket_menu.page == SOCKET_ROOT && socket_menu.overlay) {
      /* The launcher scene gets the buttons. The sequence is that of SMO_NAMES. */
      static const unsigned pad[] = {RETRO_DEVICE_ID_JOYPAD_UP, RETRO_DEVICE_ID_JOYPAD_DOWN,
         RETRO_DEVICE_ID_JOYPAD_LEFT, RETRO_DEVICE_ID_JOYPAD_RIGHT, RETRO_DEVICE_ID_JOYPAD_A,
         RETRO_DEVICE_ID_JOYPAD_B, RETRO_DEVICE_ID_JOYPAD_X, RETRO_DEVICE_ID_JOYPAD_Y,
         RETRO_DEVICE_ID_JOYPAD_L, RETRO_DEVICE_ID_JOYPAD_R};
      unsigned mask = 0;
      for (i = 0; i < SMO_BUTTONS; i++) if (BIT256_GET_PTR(bits, pad[i])) mask |= 1u << i;
      socket_overlay_pad(mask);
      held = (unsigned)-1;
      socket_menu.wait_release = true;
      return MENU_ACTION_NOOP;
   }
   /* A button that the launcher scene used is down. It is not for this page. */
   if (socket_menu.wait_release) {
      for (i = 0; i < 6; i++) if (BIT256_GET_PTR(bits, keys[i])) return MENU_ACTION_NOOP;
      socket_menu.wait_release = false;
   }
   for (i = 0; i < 6; i++) if (BIT256_GET_PTR(bits, keys[i])) {
      if (held != i) { held = i; repeat_at = now + 350000; return actions[i]; }
      if (i < 4 && now >= repeat_at) { repeat_at = now + 120000; return actions[i]; }
      return MENU_ACTION_NOOP;
   }
   held = (unsigned)-1;
   return MENU_ACTION_NOOP;
}

/* Give the page to a launcher scene of version 2. The scene draws SMO_ROWS
 * rows around the selection, the title and the status. A line goes out only
 * if one of these changed, thus a status from a task also gets to the scene. */
static void socket_menu_show(void) {
   static unsigned first;
   char text[SMO_ROWS][256];
   const char *rows[SMO_ROWS];
   unsigned count, selected, shown;
   if (!socket_menu.active || !socket_menu.overlay) return;
   if (socket_menu.page == SOCKET_ROOT) { socket_overlay_root(); return; }
   if (!socket_overlay_views()) return;
   count = socket_quick_menu_count();
   selected = socket_menu.selected < count ? socket_menu.selected : count ? count - 1 : 0;
   /* Move the window only when the selection goes out of it. */
   if (selected < first) first = selected;
   if (selected >= first + SMO_ROWS) first = selected - SMO_ROWS + 1;
   if (first + SMO_ROWS > count) first = count > SMO_ROWS ? count - SMO_ROWS : 0;
   for (shown = 0; shown < SMO_ROWS && first + shown < count; shown++) {
      socket_quick_menu_label(first + shown, text[shown], sizeof(text[shown]));
      rows[shown] = text[shown];
   }
   socket_overlay_view(selected - first, first, count, socket_quick_menu_title(), socket_menu.status, rows, shown);
}

static void socket_menu_step(enum menu_action action) {
   settings_t *s = config_get_ptr();
   unsigned count;
   unsigned row;
   bool changed = false, core = false, module = socket_menu.page >= SOCKET_DEVICE;
   bool root = socket_menu.page == SOCKET_ROOT;
   int direction = action == MENU_ACTION_LEFT ? -1 : 1;
   core_option_manager_t *options = runloop_state_get_ptr()->core_options;
   if (socket_menu.overlay && (root || socket_overlay_views())) {
      int event = SMO_FAILED;
      /* Sleep closed the scene. Open it again. */
      if (smo.open || socket_overlay_open()) event = socket_overlay_tick();
      /* This menu keeps the pad on its pages. */
      if (!root) socket_overlay_focus(false);
      if (event == SMO_CLOSE) socket_menu_close();
      else if (event == SMO_GAME || event == SMO_CHEATS) {
         socket_overlay_focus(false);
         socket_menu.root_row = event == SMO_GAME ? SOCKET_ROOT_GAME : SOCKET_ROOT_CHEATS;
         socket_menu.page = event == SMO_GAME ? SOCKET_MAIN : SOCKET_CHEATS;
         socket_menu.selected = 0;
         if (event == SMO_CHEATS) socket_cheats_open(0);
      } else if (event == SMO_FAILED) {
         /* The native pages keep Resume, Save & Exit and the settings available.
          * A page of this menu stays open with its selection. */
         socket_overlay_close();
         socket_menu.overlay = false;
         if (root) socket_menu.selected = SOCKET_ROOT_GAME;
         socket_menu_message("The launcher did not show Device Settings. This is the basic menu.");
      }
      if (root) return;
   }
   if (socket_menu.page == SOCKET_DEVICE) socket_device_tick();
   else if (socket_menu.page == SOCKET_CHEATS) socket_cheats_tick();
   /* A module page can have no rows. */
   count = socket_quick_menu_count();
   if (socket_menu.selected >= count) socket_menu.selected = count ? count - 1 : 0;
   if (action != MENU_ACTION_NOOP && action != MENU_ACTION_OK) socket_menu.confirm_load = false;
   if (action == MENU_ACTION_CANCEL && !module) {
      if (socket_menu.page == SOCKET_ROOT) socket_menu_close();
      else if (socket_menu.page == SOCKET_MAIN) {
         socket_menu.page = SOCKET_ROOT;
         socket_menu.selected = SOCKET_ROOT_GAME;
         socket_overlay_focus(true);
      }
      else { socket_menu.page = SOCKET_MAIN; socket_menu.selected = 0; }
      return;
   }
   if (action == MENU_ACTION_UP && count) socket_menu.selected = (socket_menu.selected + count - 1) % count;
   if (action == MENU_ACTION_DOWN && count) socket_menu.selected = (socket_menu.selected + 1) % count;
   if (action != MENU_ACTION_OK && action != MENU_ACTION_LEFT && action != MENU_ACTION_RIGHT
         && action != MENU_ACTION_CANCEL) return;
   row = socket_menu.selected;
   if (module) {
      if (!(socket_menu.page == SOCKET_DEVICE ? socket_device_action(action, row) : socket_cheats_action(action, row)))
         socket_menu_leave_module();
   } else if (socket_menu.page == SOCKET_ROOT) {
      if (row < SOCKET_ROOT_WIFI) {
         if (action != MENU_ACTION_OK) socket_device_level_step(row == 1, direction);
      } else if (action == MENU_ACTION_OK) {
         socket_menu.root_row = row;
         socket_menu.selected = 0;
         if (row == SOCKET_ROOT_GAME) socket_menu.page = SOCKET_MAIN;
         else if (row == SOCKET_ROOT_CHEATS) { socket_menu.page = SOCKET_CHEATS; socket_cheats_open(0); }
         else { socket_menu.page = SOCKET_DEVICE; socket_device_open(row - SOCKET_ROOT_WIFI); }
      }
   } else if (socket_menu.page == SOCKET_MAIN) {
      if (row == 2) {
         int slot = s->ints.state_slot + direction;
         s->ints.state_slot = slot < 0 ? 0 : slot > 9 ? 9 : slot;
         changed = true;
      } else if (action == MENU_ACTION_OK) {
         if (row == 0) socket_menu_close();
         else if (row == 1 || row == 6 || row == 7 || row == 8) {
            socket_menu.page = row == 1 ? SOCKET_CORE : row == 6 ? SOCKET_SCREEN : row == 7 ? SOCKET_GAMEPLAY : SOCKET_CONTROLS;
            socket_menu.selected = 0;
         } else if (row == 3) {
            char path[PATH_MAX_LENGTH];
            content_wait_for_save_state_task();
            if (runloop_get_current_savestate_path(path, sizeof(path)) && content_auto_save_state(path))
               socket_menu_message("State saved.");
            else socket_menu_message("Save failed. Previous state was kept.");
         } else if (row == 4) {
            char path[PATH_MAX_LENGTH];
            if (!runloop_get_current_savestate_path(path, sizeof(path)) || !path_is_valid(path))
               socket_menu_message("This state slot is empty.");
            else if (!socket_menu.confirm_load) {
               socket_menu.confirm_load = true;
               socket_menu_message("Load this state? Press A again, or B to cancel.");
            } else {
               bool notifications = s->bools.notification_show_save_state;
               socket_menu.confirm_load = false;
               socket_menu.loading = true;
               s->bools.notification_show_save_state = true;
               socket_menu_message("Loading state...");
               if (!command_event(CMD_EVENT_LOAD_STATE, NULL)) socket_quick_menu_load_result(false);
               s->bools.notification_show_save_state = notifications;
            }
         }
         else if (row == 5) {
            socket_menu_close();
            video_driver_cached_frame();
            command_event(CMD_EVENT_TAKE_SCREENSHOT, NULL);
         } else if (row == 9) socket_menu_save_exit();
      }
   } else if (socket_menu.page == SOCKET_CORE) {
      size_t index = socket_menu_core_index(row);
      if (index != (size_t)-1) {
         core_option_manager_adjust_val(options, index, direction, false);
         changed = core = true;
      }
   } else if (socket_menu.page == SOCKET_SCREEN) {
      if (row == 0) {
         const char *preset = video_state_get_ptr()->cli_shader_path;
         bool enabled = !s->bools.video_shader_enable;
         if (enabled && string_is_empty(preset)) socket_menu_message("No shader preset is available.");
         else if (video_shader_apply_shader(s, video_shader_parse_type(preset), enabled ? preset : NULL, false)) {
            s->bools.video_shader_enable = enabled;
            changed = true;
         }
      }
      else if (row == 1) {
         size_t index = socket_menu_color_index();
         if (index != (size_t)-1) {
            core_option_manager_adjust_val(options, index, direction, false);
            changed = core = true;
         }
      } else {
         int mode = s->bools.video_scale_integer ? 1 : s->uints.video_aspect_ratio_idx == ASPECT_RATIO_FULL ? 2 : 0;
         mode = (mode + direction + 3) % 3;
         s->bools.video_scale_integer = mode == 1;
         s->uints.video_aspect_ratio_idx = mode == 2 ? ASPECT_RATIO_FULL : ASPECT_RATIO_CORE;
         command_event(CMD_EVENT_VIDEO_SET_ASPECT_RATIO, NULL);
         changed = true;
      }
   } else if (socket_menu.page == SOCKET_GAMEPLAY) {
      if (row == 0) {
         float speed = s->floats.fastforward_ratio + direction;
         s->floats.fastforward_ratio = speed < 2 ? 2 : speed > 8 ? 8 : speed;
      } else if (row == 1) s->bools.audio_fastforward_mute = !s->bools.audio_fastforward_mute;
      else { s->bools.rewind_enable = !s->bools.rewind_enable; command_event(CMD_EVENT_REWIND_TOGGLE, NULL); }
      changed = true;
   }
   if (changed) socket_menu_save_settings(core);
   if (action != MENU_ACTION_NOOP) RARCH_LOG("[Socket Menu] %s row %u.\n", socket_quick_menu_title(), socket_menu.selected);
}

static void socket_menu_iterate(enum menu_action action) {
   socket_menu_step(action);
   socket_menu_show();
}
#endif

#ifdef SOCKET_QUICK_MENU_GL2
/* gl2.c includes this part. It draws the frame of the launcher scene on the
 * root page, and on each page for a launcher of version 2. For version 1, the
 * Game and Cheats pages use the panel color and the text color of that
 * scene. Without the scene, the native pages are dark: a
 * charcoal surface, and soft grey for the text and the focus outline. */
#define SOCKET_MENU_SURFACE 0x212121
#define SOCKET_MENU_INK 0xd0d0d0
static void gl2_socket_menu_text(gl2_t *gl, const char *text, float y, float scale, unsigned color)
{
   struct font_params params = {0};
   params.x = 60.0f / 720.0f;
   params.y = 1.0f - y / 480.0f;
   params.scale = scale;
   params.color = color << 8 | 0xff;
   params.full_screen = true;
   font_driver_render_msg(gl, text, &params, NULL);
}

static void gl2_socket_menu(gl2_t *gl)
{
   const unsigned char white[] = {255, 255, 255, 255};
   unsigned surface = SOCKET_MENU_SURFACE, ink = SOCKET_MENU_INK;
   float sr, sg, sb, ir, ig, ib;
   const unsigned char *frame = NULL;
   unsigned frame_width = 0, frame_height = 0, frame_flags = 0, frame_serial = 0;
   bool overlay = socket_quick_menu_shared();
   GLuint texture;
   unsigned row, count, selected, first;
   float x = gl->video_width / 720.0f;
   float y = gl->video_height / 480.0f;
   float font_size = config_get_ptr()->floats.video_font_size;
   float scale = 22.0f * y / (font_size > 0 ? font_size : 32.0f);
   GLint viewport[4], previous_texture;
   GLboolean blend;
   char text[512];
   if (!socket_quick_menu_active()) return;
   socket_quick_menu_theme(&surface, &ink);
   sr = (surface >> 16 & 255) / 255.0f; sg = (surface >> 8 & 255) / 255.0f; sb = (surface & 255) / 255.0f;
   ir = (ink >> 16 & 255) / 255.0f; ig = (ink >> 8 & 255) / 255.0f; ib = (ink & 255) / 255.0f;
   count = socket_quick_menu_count();
   selected = socket_quick_menu_selection();
   first = selected >= 10 ? selected - 9 : 0;
   glGetIntegerv(GL_VIEWPORT, viewport);
   glGetIntegerv(GL_TEXTURE_BINDING_2D, &previous_texture);
   blend = glIsEnabled(GL_BLEND);
   gl->shader->use(gl, gl->shader_data, VIDEO_SHADER_STOCK_BLEND, true);
   glViewport(0, 0, gl->video_width, gl->video_height);
   glEnable(GL_BLEND);
   glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
   glBlendEquation(GL_FUNC_ADD);
   glGenTextures(1, &texture);
   glBindTexture(GL_TEXTURE_2D, texture);
   glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
   glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
   glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 1, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE, white);
   if (overlay) frame = socket_quick_menu_frame(&frame_width, &frame_height, &frame_flags, &frame_serial);
   if (frame)
   {
      /* One texture for each GL context. Send the pixels one time for each frame. */
      static unsigned shown_serial, shown_width, shown_height;
      if (!gl->socket_overlay)
      {
         glGenTextures(1, &gl->socket_overlay);
         shown_width = shown_height = 0;
      }
      glBindTexture(GL_TEXTURE_2D, gl->socket_overlay);
      if (frame_serial != shown_serial || !shown_width)
      {
         glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
         if (frame_width != shown_width || frame_height != shown_height)
         {
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, frame_width, frame_height, 0, GL_RGBA, GL_UNSIGNED_BYTE, frame);
         }
         else
            glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, frame_width, frame_height, GL_RGBA, GL_UNSIGNED_BYTE, frame);
         shown_serial = frame_serial;
         shown_width = frame_width;
         shown_height = frame_height;
      }
      if (frame_flags & 1) glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
      gl2_socket_quad(gl, gl->socket_overlay, 0, 0, gl->video_width, gl->video_height, 1, 1, 1, 1);
      glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
   }
   else
      gl2_socket_quad(gl, texture, 0, 0, gl->video_width, gl->video_height, 0, 0, 0, .6f);
   if (!overlay)
   {
      gl2_socket_quad(gl, texture, 20*x, 44*y, 680*x, 428*y, sr, sg, sb, 1);
      if (count)
      {
         gl2_socket_quad(gl, texture, 44*x, (99+(selected-first)*30)*y, 632*x, 29*y, ir, ig, ib, 1);
         gl2_socket_quad(gl, texture, 46*x, (101+(selected-first)*30)*y, 628*x, 25*y, sr, sg, sb, 1);
      }
   }
   glDeleteTextures(1, &texture);
   glBindTexture(GL_TEXTURE_2D, previous_texture);
   if (!blend) glDisable(GL_BLEND);
   glViewport(viewport[0], viewport[1], viewport[2], viewport[3]);
   gl->shader->set_coords(gl->shader_data, &gl->coords);
   gl->shader->set_mvp(gl->shader_data, &gl->mvp);
   if (overlay) return;
   gl2_socket_menu_text(gl, socket_quick_menu_title(), 76, scale * 1.5f, ink);
   for (row = first; row < count && row < first + 10; row++)
   {
      size_t length;
      socket_quick_menu_label(row, text, sizeof(text));
      length = strlen(text);
      while (length && font_driver_get_message_width(NULL, text, length, scale) > 595*x)
      {
         do { length--; } while (length && ((unsigned char)text[length] & 0xc0) == 0x80);
         text[length] = '\0';
      }
      gl2_socket_menu_text(gl, text, 120+(row-first)*30, scale, ink);
   }
   gl2_socket_menu_text(gl, socket_quick_menu_status(), 430, scale * .5f, ink);
   gl2_socket_menu_text(gl, "A  Select    B  Back    Left / Right  Change", 458, scale * .5f, ink);
}
#endif

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
#endif

#ifdef SOCKET_QUICK_MENU_IMPLEMENTATION
#include "gfx/video_shader_parse.h"
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
bool content_load_state_in_progress(void *data);
static struct { bool active, confirm_load, loading; unsigned page, selected; char status[128]; } socket_menu;
static struct { bool held, failed, loading, boot_checked, sram, quiet, was_muted; char token[32], ack[32]; } socket_sleep;
static void socket_menu_open(void);
static void socket_sleep_load_result(bool ok);
enum { SOCKET_MAIN, SOCKET_CORE, SOCKET_SCREEN, SOCKET_GAMEPLAY, SOCKET_CONTROLS };

bool socket_quick_menu_active(void) { return socket_menu.active; }
unsigned socket_quick_menu_selection(void) { return socket_menu.selected; }
const char *socket_quick_menu_status(void) { return socket_menu.status; }

static void socket_menu_message(const char *text) {
   strlcpy(socket_menu.status, text, sizeof(socket_menu.status));
   RARCH_LOG("[Socket Menu] %s\n", text);
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
   retroarch_menu_running_finished(false);
}

static void socket_menu_open(void) {
   socket_menu.active = true;
   socket_menu.page = SOCKET_MAIN;
   socket_menu.selected = 0;
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

static void socket_menu_poweroff(retro_time_t now) {
   static char previous_sleep[32], previous_wake[32], previous_off[32];
   char token[32], current[32];
   bool ok;
   (void)now;
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

unsigned socket_quick_menu_count(void) {
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
   static const char *titles[] = {"Socket", "Core options", "Screen", "Gameplay", "Controls"};
   return titles[socket_menu.page];
}

void socket_quick_menu_label(unsigned row, char *text, size_t size) {
   settings_t *s = config_get_ptr();
   core_option_manager_t *options = runloop_state_get_ptr()->core_options;
   size_t index;
   const char *value;
   static const char *main_rows[] = {"Resume", "Core options", "State slot", "Save state",
      "Load state", "Screenshot", "Screen", "Gameplay", "Controls", "Save & Exit"};
   if (socket_menu.page == SOCKET_MAIN) {
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
   for (i = 0; i < 6; i++) if (BIT256_GET_PTR(bits, keys[i])) {
      if (held != i) { held = i; repeat_at = now + 350000; return actions[i]; }
      if (i < 4 && now >= repeat_at) { repeat_at = now + 120000; return actions[i]; }
      return MENU_ACTION_NOOP;
   }
   held = (unsigned)-1;
   return MENU_ACTION_NOOP;
}

static void socket_menu_iterate(enum menu_action action) {
   settings_t *s = config_get_ptr();
   unsigned count = socket_quick_menu_count();
   unsigned row;
   bool changed = false, core = false;
   int direction = action == MENU_ACTION_LEFT ? -1 : 1;
   core_option_manager_t *options = runloop_state_get_ptr()->core_options;
   if (action != MENU_ACTION_NOOP && action != MENU_ACTION_OK) socket_menu.confirm_load = false;
   if (socket_menu.selected >= count) socket_menu.selected = count - 1;
   if (action == MENU_ACTION_CANCEL) {
      if (socket_menu.page == SOCKET_MAIN) socket_menu_close();
      else { socket_menu.page = SOCKET_MAIN; socket_menu.selected = 0; }
      return;
   }
   if (action == MENU_ACTION_UP) socket_menu.selected = (socket_menu.selected + count - 1) % count;
   if (action == MENU_ACTION_DOWN) socket_menu.selected = (socket_menu.selected + 1) % count;
   if (action != MENU_ACTION_OK && action != MENU_ACTION_LEFT && action != MENU_ACTION_RIGHT) return;
   row = socket_menu.selected;
   if (socket_menu.page == SOCKET_MAIN) {
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
#endif

/* Device Settings pages of the Socket in-game menu: brightness, volume,
 * Wi-Fi and Bluetooth.
 *
 * socket_quick_menu.h includes this file in its implementation section. The
 * file uses these items of that section: socket_menu.selected,
 * socket_menu_message(), socket_sleep_path() and enum menu_action.
 *
 * This file starts no radio work. It uses the files in SOCKET_RUN that the
 * launcher panel also uses:
 * - socket-hardware: controls (snapshot), controls.set and controls.ack.
 * - wifi.sh: wifi.request, wifi.candidate, wifi.status and wifi.scan.
 * - bluetooth.sh: bluetooth.request.N, bluetooth.status, bluetooth.state and
 *   bluetooth.log.
 *
 * Interface for the menu:
 * - socket_device_open(section): 0 shows Wi-Fi, 1 shows Bluetooth.
 * - socket_device_close(): call this for Back to the root page, MENU and
 *   sleep. It cancels a pending scan, join or pairing and erases the typed
 *   name, password and code. A second call does nothing.
 * - socket_device_tick(): call this one time for each frame of the page.
 * - socket_device_title(), socket_device_count(), socket_device_label().
 * - socket_device_action(action, row): false means "go back to the root page".
 * - socket_device_level_label() and socket_device_level_step() are for the
 *   Brightness and Volume rows of the root page. The label function also
 *   reads the replies of socket-hardware, so call it for each frame.
 *
 * socket_menu_message() and the page title go to the log on the card. They
 * get fixed text only. Network names, accessory names, addresses, passwords,
 * pairing codes and the error text of a worker go to rows only.
 */
#ifndef SOCKET_DEVICE_MENU_H
#define SOCKET_DEVICE_MENU_H
#include <ctype.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "socket_controls.h"

#define SDM_ROWS 32
#define SDM_NETWORKS 24
#define SDM_DEVICES 24

enum { SDM_CLOSED, SDM_WIFI, SDM_NETS, SDM_FORM, SDM_JOINING, SDM_WIFI_FORGET, SDM_KEYS,
   SDM_BT, SDM_BT_DEVICE, SDM_BT_FORGET, SDM_BT_SCAN, SDM_BT_CONFIRM, SDM_BT_BUSY };
enum { SDM_A_NONE, SDM_A_BACK, SDM_A_WIFI_POWER, SDM_A_WIFI_SCAN, SDM_A_WIFI_RETRY, SDM_A_WIFI_ASK_FORGET,
   SDM_A_WIFI_FORGET, SDM_A_WIFI_CHOOSE, SDM_A_WIFI_HIDDEN, SDM_A_EDIT_SSID, SDM_A_EDIT_PSK, SDM_A_WIFI_JOIN,
   SDM_A_WIFI_RECONNECT, SDM_A_KEY, SDM_A_CAPS, SDM_A_SYMBOLS, SDM_A_SPACE, SDM_A_DELETE, SDM_A_DONE,
   SDM_A_BT_ON, SDM_A_BT_OFF, SDM_A_BT_DEVICE, SDM_A_BT_ADD, SDM_A_BT_CONNECT, SDM_A_BT_DISCONNECT,
   SDM_A_BT_ASK_FORGET, SDM_A_BT_FORGET, SDM_A_BT_CHOOSE, SDM_A_BT_PAIR, SDM_A_BT_YES, SDM_A_BT_NO,
   SDM_A_BT_DIGIT, SDM_A_BT_SUBMIT };
enum { SDM_W_NONE, SDM_W_SCAN, SDM_W_JOIN, SDM_W_CANCEL, SDM_W_OTHER };

/* A grid row shows the characters of its key. Left and Right select one. */
struct sdm_row { char text[128], key[33]; int act; bool grid; };
struct sdm_network { char ssid[33], security[12]; int signal; bool supported; };
struct sdm_device { char address[18], name[33]; bool paired, connected, rssi, named; };

static struct {
   int view, built;
   unsigned count, col;
   struct sdm_row rows[SDM_ROWS];
   char title[80], status[200], shown_status[200];
   retro_time_t poll_at;
   /* Levels. The shown level is the last level that socket-hardware applied. */
   socket_controls_t controls;
   uint32_t sequence;
   int shown[2], wanted[2], request, request_value;
   unsigned long long token;
   retro_time_t request_deadline;
   /* Wi-Fi */
   unsigned w_id, sent;
   char w_result[16], w_state[16], w_saved[33], note[100];
   int waiting;
   retro_time_t w_deadline;
   struct sdm_network networks[SDM_NETWORKS];
   unsigned network_count;
   bool hidden, caps, symbols;
   char ssid[33], psk[65], *field;
   size_t field_max;
   /* Bluetooth */
   char b_status[16], target[18], message[64], prompt[10], code[17], entry[17], session[40];
   const char *phase;
   struct sdm_device devices[SDM_DEVICES];
   unsigned device_count, found_count;
   char found[SDM_DEVICES][18];
   bool discovering, want_scan, agent_ready, asleep;
   long offset;
   long long request_number;
   retro_time_t b_deadline, scan_at;
} sdm = { .shown = {6, 40}, .wanted = {-1, -1}, .request = -1 };

static void sdm_wipe(void *data, size_t size) {
   volatile unsigned char *bytes = (volatile unsigned char *)data;
   while (size--) *bytes++ = 0;
}

static FILE *sdm_open(const char *name) {
   char path[PATH_MAX_LENGTH];
   return socket_sleep_path(path, sizeof(path), name) ? fopen(path, "rb") : NULL;
}

/* Read a small text file. Return false if it is absent, empty or too long. */
static bool sdm_read(const char *name, char *data, size_t size) {
   FILE *file = sdm_open(name);
   size_t length;
   if (!file) return false;
   length = fread(data, 1, size, file);
   fclose(file);
   data[length < size ? length : 0] = 0;
   return length > 0 && length < size;
}

static void sdm_remove(const char *name) {
   char path[PATH_MAX_LENGTH];
   if (socket_sleep_path(path, sizeof(path), name)) unlink(path);
}

/* Replace a file in one step. Only this user can read it. */
static bool sdm_write(const char *name, const char *temporary_name, const char *text) {
   char path[PATH_MAX_LENGTH], temporary[PATH_MAX_LENGTH];
   size_t size = strlen(text);
   int fd;
   bool ok;
   if (!socket_sleep_path(path, sizeof(path), name)
         || !socket_sleep_path(temporary, sizeof(temporary), temporary_name)) return false;
   fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC, 0600);
   if (fd < 0) return false;
   ok = write(fd, text, size) == (ssize_t)size;
   if (close(fd) != 0) ok = false;
   if (ok) ok = rename(temporary, path) == 0;
   if (!ok) unlink(temporary);
   return ok;
}

static void sdm_show(int view, unsigned selected) {
   sdm.view = view;
   sdm.built = SDM_CLOSED;
   sdm.col = 0;
   socket_menu.selected = selected;
}

/* ---- Brightness and volume ---- */

static const struct { const char *name; int min, max, step; } sdm_levels[2] = {
   {"brightness", 1, 10, 1}, {"volume", 0, 100, 5}};

/* Send one request to socket-hardware. Wait for its reply before the next. */
static void sdm_level_send(void) {
   char text[64];
   int i;
   if (sdm.request >= 0) return;
   for (i = 0; i < 2; i++) {
      if (sdm.wanted[i] < 0) continue;
      if (sdm.wanted[i] == sdm.shown[i]) { sdm.wanted[i] = -1; continue; }
      if (!sdm.token) sdm.token = (unsigned long long)cpu_features_get_time_usec();
      snprintf(text, sizeof(text), "%llu %s %d\n", ++sdm.token, sdm_levels[i].name, sdm.wanted[i]);
      if (!sdm_write("controls.set", "controls.set.tmp", text)) {
         sdm.wanted[0] = sdm.wanted[1] = -1;
         return;
      }
      sdm.request = i;
      sdm.request_value = sdm.wanted[i];
      sdm.request_deadline = cpu_features_get_time_usec() + 500000;
      return;
   }
}

static void sdm_level_poll(void) {
   char data[48], token[20], word[8], expected[24], end;
   int level, i = sdm.request;
   /* The snapshot also has the changes from the volume buttons and shortcuts. */
   socket_controls_poll(&sdm.controls, cpu_features_get_time_usec());
   if (sdm.controls.valid && (sdm.controls.sequence != sdm.sequence || !sdm.token)) {
      if (!sdm.token) sdm.token = (unsigned long long)cpu_features_get_time_usec();
      sdm.sequence = sdm.controls.sequence;
      sdm.shown[0] = (int)sdm.controls.brightness + 1;
      sdm.shown[1] = (int)sdm.controls.volume;
   }
   if (i < 0) return;
   snprintf(expected, sizeof(expected), "%llu", sdm.token);
   if (sdm_read("controls.ack", data, sizeof(data))
         && sscanf(data, "%19[0-9] %7[a-z] %3d%c", token, word, &level, &end) == 4 && end == '\n'
         && !strcmp(token, expected)) {
      sdm_remove("controls.ack");
      /* The reply has the level in effect, also when the change failed. */
      sdm.shown[i] = level < sdm_levels[i].min ? sdm_levels[i].min : level > sdm_levels[i].max ? sdm_levels[i].max : level;
      if (strcmp(word, "ok") || sdm.wanted[i] == sdm.request_value) sdm.wanted[i] = -1;
      sdm.request = -1;
      sdm_level_send();
   } else if (cpu_features_get_time_usec() >= sdm.request_deadline) {
      /* No helper answered. Show the last applied levels. */
      sdm.request = -1;
      sdm.wanted[0] = sdm.wanted[1] = -1;
   }
}

static void socket_device_level_label(bool volume, char *text, size_t size) {
   sdm_level_poll();
   if (volume && !sdm.shown[1]) snprintf(text, size, "Volume                    Muted");
   else snprintf(text, size, "%s%d", volume ? "Volume                    " : "Brightness                ", sdm.shown[volume]);
}

static void socket_device_level_step(bool volume, int direction) {
   int i = volume, base, next;
   sdm_level_poll();
   base = sdm.wanted[i] >= 0 ? sdm.wanted[i] : sdm.shown[i];
   next = base + (direction < 0 ? -1 : 1) * sdm_levels[i].step;
   if (next < sdm_levels[i].min) next = sdm_levels[i].min;
   if (next > sdm_levels[i].max) next = sdm_levels[i].max;
   if (next == base) return;
   sdm.wanted[i] = next;
   sdm_level_send();
}

/* ---- Wi-Fi ---- */

static void sdm_wifi_status(void) {
   char data[256], *line, *next;
   sdm.w_id = 0;
   sdm.w_result[0] = sdm.w_state[0] = sdm.w_saved[0] = 0;
   if (!sdm_read("wifi.status", data, sizeof(data))) return;
   for (line = data; line; line = next) {
      next = strchr(line, '\n');
      if (next) *next++ = 0;
      if (!strncmp(line, "id=", 3)) sdm.w_id = (unsigned)strtoul(line + 3, NULL, 10);
      else if (!strncmp(line, "result=", 7)) snprintf(sdm.w_result, sizeof(sdm.w_result), "%s", line + 7);
      else if (!strncmp(line, "state=", 6)) snprintf(sdm.w_state, sizeof(sdm.w_state), "%s", line + 6);
      else if (!strncmp(line, "saved=", 6)) snprintf(sdm.w_saved, sizeof(sdm.w_saved), "%s", line + 6);
   }
}

/* The request number is higher than each number that the worker has seen.
 * The worker gives no result for an older number. */
static void sdm_wifi_send(const char *action, const char *candidate) {
   char text[32];
   bool scan = !strcmp(action, "scan"), join = !strcmp(action, "join");
   sdm_wifi_status();
   sdm.sent = (sdm.sent > sdm.w_id ? sdm.sent : sdm.w_id) + 1;
   sdm.waiting = scan ? SDM_W_SCAN : join ? SDM_W_JOIN : !strcmp(action, "cancel") ? SDM_W_CANCEL : SDM_W_OTHER;
   /* Seconds. These limits are longer than the limits of the worker. */
   sdm.w_deadline = cpu_features_get_time_usec() + (join ? 90 : scan ? 30 : 8) * (retro_time_t)1000000;
   snprintf(text, sizeof(text), "%u %s\n", sdm.sent, action);
   /* The password goes into a private file, not into a command line. */
   if ((candidate && !sdm_write("wifi.candidate", "wifi.candidate.new", candidate))
         || !sdm_write("wifi.request", "wifi.request.new", text))
      sdm.w_deadline = 0;
}

/* wpa_supplicant prints the bytes of a name with C escapes. Return false
 * for a name that is empty, too long or has a zero byte. */
static bool sdm_wifi_unescape(const char *text, char *name, size_t size) {
   size_t length = 0;
   while (*text) {
      unsigned char c = (unsigned char)*text++;
      if (c == '\\' && *text) {
         c = (unsigned char)*text++;
         if (c == 'x') {
            char hex[3] = {text[0], text[0] ? text[1] : 0, 0};
            if (!isxdigit((unsigned char)hex[0]) || !isxdigit((unsigned char)hex[1])) return false;
            c = (unsigned char)strtoul(hex, NULL, 16);
            text += 2;
         } else c = c == 'n' ? 10 : c == 'r' ? 13 : c == 't' ? 9 : c == 'e' ? 27 : c;
      }
      if (!c || length + 1 >= size) return false;
      name[length++] = (char)c;
   }
   name[length] = 0;
   return length > 0;
}

/* Read the wpa_cli scan_results table. The strongest network is first. */
static void sdm_wifi_scan(void) {
   FILE *file = sdm_open("wifi.scan");
   char line[512], ssid[33];
   bool header = true;
   unsigned i, j;
   sdm.network_count = 0;
   if (!file) return;
   while (fgets(line, sizeof(line), file)) {
      char *cells[5], *cursor = line, *group;
      struct sdm_network *slot = NULL, network;
      int n;
      line[strcspn(line, "\n")] = 0;
      if (header) { header = false; continue; }
      for (n = 0; n < 5; n++) {
         cells[n] = cursor;
         if (n == 4) continue;
         cursor = strchr(cursor, '\t');
         if (!cursor) break;
         *cursor++ = 0;
      }
      if (n < 5) continue;
      cells[4][strcspn(cells[4], "\t")] = 0;
      if (!sdm_wifi_unescape(cells[4], ssid, sizeof(ssid))) continue;
      memset(&network, 0, sizeof(network));
      snprintf(network.ssid, sizeof(network.ssid), "%s", ssid);
      network.signal = atoi(cells[2]);
      for (group = cells[3]; (group = strstr(group, "[WPA2-")); group++) {
         char *end = strchr(group, ']'), *psk = strstr(group, "PSK");
         if (psk && (!end || psk < end)) network.supported = true;
      }
      snprintf(network.security, sizeof(network.security), "%s", network.supported ? "WPA2"
         : strstr(cells[3], "SAE") ? "WPA3" : strstr(cells[3], "EAP") ? "Enterprise"
         : strstr(cells[3], "[WPA") ? "WPA" : strstr(cells[3], "WEP") ? "WEP" : "Open");
      /* Keep the strongest access point of each name. A full list keeps the
       * strongest names. */
      for (i = 0; i < sdm.network_count; i++) {
         if (!strcmp(sdm.networks[i].ssid, ssid)) { slot = &sdm.networks[i]; break; }
      }
      if (!slot && sdm.network_count < SDM_NETWORKS) {
         slot = &sdm.networks[sdm.network_count++];
         slot->signal = network.signal - 1;
      } else if (!slot) {
         slot = &sdm.networks[0];
         for (i = 1; i < sdm.network_count; i++) if (sdm.networks[i].signal < slot->signal) slot = &sdm.networks[i];
      }
      if (slot->signal < network.signal) *slot = network;
   }
   fclose(file);
   for (i = 1; i < sdm.network_count; i++) {
      struct sdm_network network = sdm.networks[i];
      for (j = i; j > 0 && sdm.networks[j - 1].signal < network.signal; j--) sdm.networks[j] = sdm.networks[j - 1];
      sdm.networks[j] = network;
   }
}

/* Return the reason why Config/wifi.txt cannot store and give back these
 * values. The rules are those of engine/wifi-config.c. NULL means valid. */
static const char *sdm_wifi_check(const char *ssid, const char *psk) {
   size_t length, i, n;
   for (n = 0; n < 2; n++) {
      const char *value = n ? psk : ssid;
      length = strlen(value);
      for (i = 0; i < length; i++) {
         if ((unsigned char)value[i] < 32 || value[i] == 127)
            return n ? "The password has a character that the card cannot store."
               : "The network name has a character that the card cannot store.";
      }
      if (length && (value[0] == ' ' || value[length - 1] == ' '))
         return n ? "The password cannot start or end with a space." : "The network name cannot start or end with a space.";
   }
   if (!*ssid || strlen(ssid) > 32) return "The network name must be 1 to 32 bytes long.";
   length = strlen(psk);
   if (length < 8 || length > 64) return "The password must be 8 to 63 characters long, or a key of 64 hexadecimal digits.";
   if (length == 64 && strspn(psk, "0123456789abcdefABCDEF") != 64)
      return "A password of 64 characters must be a key of hexadecimal digits.";
   return NULL;
}

static void sdm_wifi_forget_typed(void) {
   sdm_wipe(sdm.ssid, sizeof(sdm.ssid));
   sdm_wipe(sdm.psk, sizeof(sdm.psk));
   sdm.field = NULL;
}

static void sdm_wifi_finish(const char *result) {
   static const char *errors[][2] = {
      {"invalid", "The card format cannot store this name or password."},
      {"auth", "The network rejected the password."}, {"notfound", "The network was not found."},
      {"dhcp", "The network gave no address. DHCP failed."}, {"save", "The card could not save the change."},
      {"canceled", "Canceled."}, {"off", "Wi-Fi is off."}, {"external", "BaseOS manages Wi-Fi on this device."}};
   const char *error = "Wi-Fi did not answer. Try again.";
   int action = sdm.waiting;
   bool ok = !strcmp(result, "ok");
   unsigned i;
   for (i = 0; i < sizeof(errors) / sizeof(*errors); i++) if (!strcmp(result, errors[i][0])) error = errors[i][1];
   if (ok) error = "";
   sdm.waiting = SDM_W_NONE;
   sdm_wifi_status();
   snprintf(sdm.note, sizeof(sdm.note), "%s", error);
   if (action == SDM_W_SCAN) {
      if (ok) sdm_wifi_scan(); else sdm.network_count = 0;
      sdm_show(SDM_NETS, 0);
   } else if (action == SDM_W_CANCEL && !(!strcmp(sdm.w_state, "connected") && !strcmp(sdm.w_saved, sdm.ssid))) {
      /* The join did not complete before the worker read the cancel request. */
      snprintf(sdm.note, sizeof(sdm.note), "Canceled.");
      sdm_show(SDM_FORM, 1);
   } else if (action == SDM_W_JOIN && !ok) sdm_show(SDM_FORM, 1);
   else {
      if (action == SDM_W_JOIN || action == SDM_W_CANCEL) sdm_wifi_forget_typed();
      if (sdm.view != SDM_WIFI) sdm_show(SDM_WIFI, 0);
   }
}

static void sdm_wifi_poll(void) {
   sdm_wifi_status();
   if (!sdm.waiting) return;
   if (sdm.w_id == sdm.sent && sdm.w_result[0] && strcmp(sdm.w_result, "pending")) sdm_wifi_finish(sdm.w_result);
   else if (cpu_features_get_time_usec() > sdm.w_deadline) {
      if (sdm.waiting == SDM_W_SCAN || sdm.waiting == SDM_W_JOIN) sdm_wifi_send("cancel", NULL);
      /* No worker took the password file. */
      sdm_remove("wifi.candidate");
      sdm.waiting = sdm.view == SDM_JOINING ? SDM_W_JOIN : SDM_W_OTHER;
      sdm_wifi_finish("timeout");
   }
}

static void sdm_wifi_open_form(const char *ssid, bool hidden) {
   sdm_wifi_forget_typed();
   snprintf(sdm.ssid, sizeof(sdm.ssid), "%s", ssid);
   sdm.hidden = hidden;
   sdm.note[0] = 0;
   sdm_show(SDM_FORM, hidden ? 0 : 1);
}

static void sdm_wifi_join(void) {
   char candidate[128];
   const char *problem = sdm_wifi_check(sdm.ssid, sdm.psk);
   if (problem) {
      snprintf(sdm.note, sizeof(sdm.note), "%s", problem);
      return;
   }
   snprintf(candidate, sizeof(candidate), "ssid=%s\npsk=%s\n", sdm.ssid, sdm.psk);
   sdm_wifi_send("join", candidate);
   sdm_wipe(candidate, sizeof(candidate));
   sdm_show(SDM_JOINING, 1);
}

static void sdm_wifi_edit(char *field, size_t max) {
   sdm.field = field;
   sdm.field_max = max;
   sdm.caps = sdm.symbols = false;
   sdm_show(SDM_KEYS, 2);
}

/* ---- Bluetooth ---- */

static void sdm_bt_request(const char *text) {
   char name[48], line[48];
   long long now = (long long)cpu_features_get_time_usec();
   /* The worker reads the requests in the sequence of their numbers. */
   sdm.request_number = sdm.request_number + 1 > now ? sdm.request_number + 1 : now;
   snprintf(name, sizeof(name), "bluetooth.request.%014lld", sdm.request_number);
   snprintf(line, sizeof(line), "%s\n", text);
   sdm_write(name, "bluetooth.tmp-request", line);
}

static void sdm_bt_command(const char *command, const char *address) {
   char text[40];
   snprintf(text, sizeof(text), "%s %s", command, address);
   sdm_bt_request(text);
}

static struct sdm_device *sdm_bt_device(const char *address) {
   unsigned i;
   for (i = 0; i < sdm.device_count; i++) if (!strcmp(sdm.devices[i].address, address)) return &sdm.devices[i];
   return NULL;
}

/* The address suffix separates accessories that have the same name. */
static const char *sdm_bt_name(const char *address) {
   static char text[48];
   struct sdm_device *device = sdm_bt_device(address);
   snprintf(text, sizeof(text), "%s (%s)", device && device->name[0] ? device->name : "Accessory",
      strlen(address) == 17 ? address + 12 : "");
   return text;
}

/* Return the device of an object path such as /org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF. */
static struct sdm_device *sdm_bt_path(const char *path) {
   char address[18];
   struct sdm_device *device;
   unsigned i;
   if (strncmp(path, "/org/bluez/hci", 14) || !isdigit((unsigned char)path[14])) return NULL;
   for (path += 14; isdigit((unsigned char)*path); path++) {}
   if (strncmp(path, "/dev_", 5) || strlen(path + 5) != 17) return NULL;
   for (i = 0; i < 17; i++) {
      char c = path[5 + i];
      if (i % 3 == 2 ? c != '_' : !strchr("0123456789ABCDEF", c)) return NULL;
      address[i] = i % 3 == 2 ? ':' : c;
   }
   address[17] = 0;
   device = sdm_bt_device(address);
   if (!device && sdm.device_count < SDM_DEVICES) {
      device = &sdm.devices[sdm.device_count++];
      memset(device, 0, sizeof(*device));
      memcpy(device->address, address, sizeof(address));
   }
   return device;
}

/* Parse the text that dbus-send prints for GetManagedObjects. */
static void sdm_bt_state(void) {
   FILE *file = sdm_open("bluetooth.state");
   char line[512], key[64] = "", interface[64] = "";
   struct sdm_device *device = NULL;
   bool skip = false;
   sdm.device_count = 0;
   sdm.discovering = false;
   if (!file) return;
   while (fgets(line, sizeof(line), file)) {
      char *text = line + strspn(line, " \t");
      size_t length = strlen(text);
      /* A line that is too long has no data for this page. */
      bool whole = length && text[length - 1] == '\n', ignore = skip || !whole;
      skip = !whole;
      if (ignore) continue;
      text[--length] = 0;
      if (!strncmp(text, "object path \"", 13) && text[length - 1] == '"') {
         text[length - 1] = 0;
         device = sdm_bt_path(text + 13);
         interface[0] = key[0] = 0;
      } else if (!strncmp(text, "string \"", 8) && text[length - 1] == '"') {
         text[length - 1] = 0;
         snprintf(key, sizeof(key), "%s", text + 8);
      } else if (!strcmp(text, "array [") && key[0]) {
         snprintf(interface, sizeof(interface), "%s", key);
         key[0] = 0;
      } else if (!strncmp(text, "variant", 7) && key[0]) {
         char *value = text + 7 + strspn(text + 7, " ");
         bool on = !strcmp(value, "boolean true");
         if (!strcmp(interface, "org.bluez.Adapter1")) {
            if (!strcmp(key, "Discovering")) sdm.discovering = on;
         } else if (!strcmp(interface, "org.bluez.Device1") && device) {
            bool alias = !strcmp(key, "Alias"), name = !strcmp(key, "Name");
            if (!strcmp(key, "Paired")) device->paired = on;
            else if (!strcmp(key, "Connected")) device->connected = on;
            else if (!strcmp(key, "RSSI")) device->rssi = true;
            if (name) device->named = true;
            if ((alias || (name && !device->name[0])) && !strncmp(value, "string \"", 8) && text[length - 1] == '"') {
               size_t n = 0;
               unsigned char *c;
               text[length - 1] = 0;
               /* Keep 32 bytes of the name. Do not cut a UTF-8 character. */
               for (c = (unsigned char *)value + 8; *c && n < sizeof(device->name) - 1; c++)
                  if (*c >= 32 && *c != 127) device->name[n++] = (char)*c;
               if ((*c & 0xc0) == 0x80) {
                  while (n && ((unsigned char)device->name[n - 1] & 0xc0) == 0x80) n--;
                  if (n) n--;
               }
               device->name[n] = 0;
            }
         }
         key[0] = 0;
      }
   }
   fclose(file);
}

static void sdm_bt_leave_busy(const char *message) {
   sdm.prompt[0] = sdm.code[0] = 0;
   sdm_wipe(sdm.entry, sizeof(sdm.entry));
   snprintf(sdm.message, sizeof(sdm.message), "%s", message);
   /* A failed connection keeps the bond. The device page offers Connect again. */
   if (sdm.phase && !strcmp(sdm.phase, "connect")) sdm_show(SDM_BT_DEVICE, 1);
   else sdm_show(SDM_BT_SCAN, 0);
}

static void sdm_bt_begin(const char *phase, int seconds) {
   sdm_bt_command(phase, sdm.target);
   sdm.phase = phase;
   sdm.prompt[0] = sdm.code[0] = sdm.entry[0] = sdm.message[0] = 0;
   sdm.b_deadline = cpu_features_get_time_usec() + seconds * (retro_time_t)1000000;
   sdm_show(SDM_BT_BUSY, 1);
}

/* Replace the agent. BlueZ cancels its pairing, prompt and discovery, and
 * a late reply to the canceled attempt cannot arrive. */
static void sdm_bt_cancel(const char *message) {
   sdm_bt_request("reset");
   sdm_bt_leave_busy(message);
}

static bool sdm_ends(const char *text, const char *end) {
   size_t a = strlen(text), b = strlen(end);
   return a >= b && !strcmp(text + a - b, end);
}

static void sdm_bt_event(char *line) {
   char *words[5], *rest;
   int n = 0;
   for (words[0] = strtok_r(line, " \n", &rest); words[n] && n < 4; words[n] = strtok_r(NULL, " \n", &rest)) n++;
   if (words[n]) n++;
   if (!n) return;
   if (!strcmp(words[0], "ready")) sdm.agent_ready = true;
   else if (!strcmp(words[0], "canceled")) sdm.prompt[0] = 0;
   /* The agent rejects each request that is not for its target. Check the
    * address again: only the attempt on this page can change the page. */
   if (sdm.view != SDM_BT_BUSY || n < 3 || strcmp(words[2], sdm.target)) return;
   if (!strcmp(words[0], "prompt")) {
      const char *code = n > 3 ? words[3] : "";
      bool has_code = !strcmp(words[1], "confirm") || !strcmp(words[1], "display");
      if ((!has_code && strcmp(words[1], "pin") && strcmp(words[1], "passkey"))
            || strlen(code) > 16 || (has_code && !*code)) return;
      snprintf(sdm.prompt, sizeof(sdm.prompt), "%s", words[1]);
      snprintf(sdm.code, sizeof(sdm.code), "%s", code);
      sdm_wipe(sdm.entry, sizeof(sdm.entry));
      sdm_show(SDM_BT_BUSY, 0);
   } else if (!strcmp(words[0], "result") && !strcmp(words[1], sdm.phase) && n > 3) {
      const char *error = n > 4 ? words[4] : "";
      bool ok = !strcmp(words[3], "ok");
      if (!strcmp(sdm.phase, "connect")) sdm_bt_leave_busy(ok ? "Connected." : "Could not connect.");
      else if (ok || sdm_ends(error, ".AlreadyExists")) {
         sdm_bt_command("trust", sdm.target);
         sdm_bt_begin("connect", 20);
      } else if (sdm_ends(error, ".AuthenticationFailed") || sdm_ends(error, ".AuthenticationRejected"))
         sdm_bt_leave_busy("The code was wrong or the accessory refused.");
      else sdm_bt_leave_busy("Pairing failed.");
   }
}

/* Read the new events of socket-bluetooth-agent. Line 1 names its instance. */
static void sdm_bt_log(void) {
   FILE *file = sdm_open("bluetooth.log");
   char line[256], session[40] = "";
   bool skip = false;
   if (file && !fgets(session, sizeof(session), file)) session[0] = 0;
   if (strcmp(session, sdm.session)) {
      /* The worker started a new agent. BlueZ canceled the work of the old
       * one, so a result of a canceled attempt cannot arrive. */
      memcpy(sdm.session, session, sizeof(session));
      sdm.offset = file ? ftell(file) : 0;
      sdm.agent_ready = false;
      sdm.prompt[0] = 0;
      if (sdm.view == SDM_BT_BUSY) sdm_bt_leave_busy("Interrupted.");
   }
   if (!file) return;
   if (fseek(file, sdm.offset, SEEK_SET) == 0) {
      while (fgets(line, sizeof(line), file)) {
         bool whole = strchr(line, '\n') != NULL;
         /* Wait for the end of a line that the agent has not completed.
          * Ignore a line that is too long to be an event. */
         if (!whole && strlen(line) < sizeof(line) - 1) break;
         sdm.offset = ftell(file);
         if (whole && !skip) sdm_bt_event(line);
         skip = !whole;
      }
   }
   fclose(file);
}

static void sdm_bt_poll(void) {
   unsigned i;
   if (!sdm_read("bluetooth.status", sdm.b_status, sizeof(sdm.b_status))) sdm.b_status[0] = 0;
   sdm.b_status[strcspn(sdm.b_status, "\n")] = 0;
   sdm_bt_state();
   sdm_bt_log();
   if (strcmp(sdm.b_status, "on") && sdm.view != SDM_BT) {
      sdm.message[0] = 0;
      sdm_show(SDM_BT, 0);
   }
   if (sdm.view == SDM_BT_BUSY && cpu_features_get_time_usec() >= sdm.b_deadline)
      sdm_bt_cancel("The accessory did not respond.");
   if (sdm.view != SDM_BT_SCAN) return;
   for (i = 0; i < sdm.device_count; i++) {
      unsigned j;
      for (j = 0; j < sdm.found_count && strcmp(sdm.found[j], sdm.devices[i].address); j++) {}
      if (sdm.devices[i].rssi && j == sdm.found_count && j < SDM_DEVICES)
         memcpy(sdm.found[sdm.found_count++], sdm.devices[i].address, 18);
   }
   if (sdm.want_scan && sdm.agent_ready) {
      sdm.want_scan = false;
      sdm.scan_at = cpu_features_get_time_usec();
      sdm_bt_request("scan on");
   }
}

static void sdm_bt_scan(void) {
   sdm.found_count = 0;
   sdm.want_scan = true;
   sdm.message[0] = 0;
   sdm_show(SDM_BT_SCAN, 0);
}

/* ---- Rows ---- */

static struct sdm_row *sdm_row(int act, const char *key, const char *format, ...) {
   /* More rows than the limit replace the last row, so the Back row stays. */
   struct sdm_row *row = &sdm.rows[sdm.count < SDM_ROWS ? sdm.count++ : SDM_ROWS - 1];
   unsigned char *c;
   va_list arguments;
   row->act = act;
   row->grid = false;
   snprintf(row->key, sizeof(row->key), "%s", key ? key : "");
   va_start(arguments, format);
   vsnprintf(row->text, sizeof(row->text), format, arguments);
   va_end(arguments);
   /* A network name can have control characters. */
   for (c = (unsigned char *)row->text; *c; c++) if (*c < 32 || *c == 127) *c = '?';
   return row;
}

static void sdm_say(const char *format, ...) {
   va_list arguments;
   va_start(arguments, format);
   vsnprintf(sdm.status, sizeof(sdm.status), format, arguments);
   va_end(arguments);
}

static void sdm_title(const char *format, ...) {
   va_list arguments;
   va_start(arguments, format);
   vsnprintf(sdm.title, sizeof(sdm.title), format, arguments);
   va_end(arguments);
}

static void sdm_build_wifi(void) {
   static const char *letters[] = {"1234567890", "qwertyuiop", "asdfghjkl'", "zxcvbnm,.-"};
   static const char *symbols[] = {"1234567890", "!@#$%&*()?", "_+=/\\:;\"~|", "[]{}<>^`,."};
   const char *state = sdm.w_state, *saved = sdm.w_saved;
   bool connected = !strcmp(state, "connected");
   const char *space = sdm.note[0] ? " " : "";
   char text[80];
   size_t length;
   unsigned i;
   sdm_title("Wi-Fi");
   switch (sdm.view) {
   case SDM_WIFI:
      if (!strcmp(state, "external")) sdm_say("BaseOS manages Wi-Fi on this device.");
      else if (!strcmp(state, "off")) sdm_say("%s%sWi-Fi is off.", sdm.note, space);
      else if (!strcmp(state, "idle")) sdm_say("%s%sWi-Fi is on. No network is saved.", sdm.note, space);
      else if (!strcmp(state, "connecting")) sdm_say("%s%sConnecting...", sdm.note, space);
      else if (connected) sdm_say("%s%sConnected.", sdm.note, space);
      else sdm_say("Wi-Fi is not available.");
      if (!strcmp(state, "off")) {
         sdm_row(SDM_A_WIFI_POWER, NULL, "Wi-Fi                     Off");
         if (*saved) sdm_row(SDM_A_NONE, "saved", "Saved network: %s", saved);
      } else if (!strcmp(state, "idle") || !strcmp(state, "connecting") || connected) {
         sdm_row(SDM_A_WIFI_POWER, NULL, "Wi-Fi                     On");
         if (*saved) sdm_row(SDM_A_NONE, "saved", "Network: %s", saved);
         sdm_row(SDM_A_WIFI_SCAN, NULL, "Choose a network");
         if (*saved && !connected) sdm_row(SDM_A_WIFI_RETRY, NULL, "Retry");
         if (*saved) sdm_row(SDM_A_WIFI_ASK_FORGET, NULL, "Forget %s", saved);
      }
      sdm_row(SDM_A_BACK, NULL, "Back");
      break;
   case SDM_NETS:
      sdm_title("Choose a network");
      if (sdm.waiting == SDM_W_SCAN) {
         sdm_say("Searching for networks...");
         sdm_row(SDM_A_BACK, NULL, "Cancel");
         break;
      }
      sdm_say("%s", sdm.note[0] ? sdm.note : sdm.network_count ? "Choose a network." : "No networks found.");
      for (i = 0; i < sdm.network_count; i++)
         sdm_row(SDM_A_WIFI_CHOOSE, sdm.networks[i].ssid, "%s  (%s%s)", sdm.networks[i].ssid,
            sdm.networks[i].security, sdm.networks[i].supported ? "" : ", not supported");
      sdm_row(SDM_A_WIFI_HIDDEN, NULL, "Enter network name");
      sdm_row(SDM_A_WIFI_SCAN, NULL, "Search again");
      sdm_row(SDM_A_BACK, NULL, "Back");
      break;
   case SDM_FORM:
      sdm_title("%s", sdm.hidden ? "Join a hidden network" : "Join a network");
      sdm_say("%s", sdm.note[0] ? sdm.note : "Enter the password. Then select Join.");
      if (sdm.hidden) sdm_row(SDM_A_EDIT_SSID, NULL, "Network name: %s", sdm.ssid);
      else sdm_row(SDM_A_NONE, "name", "Network: %s", sdm.ssid);
      memset(text, '*', sizeof(text));
      sdm_row(SDM_A_EDIT_PSK, NULL, "Password: %.*s", (int)strlen(sdm.psk), text);
      sdm_row(SDM_A_WIFI_JOIN, NULL, "Join");
      if (sdm.note[0] && *saved) sdm_row(SDM_A_WIFI_RECONNECT, NULL, "Reconnect to %s", saved);
      sdm_row(SDM_A_BACK, NULL, "Back");
      break;
   case SDM_JOINING:
      sdm_say("Joining...");
      sdm_row(SDM_A_NONE, "name", "Network: %s", sdm.ssid);
      sdm_row(SDM_A_BACK, NULL, "Cancel");
      break;
   case SDM_WIFI_FORGET:
      sdm_say("Forget this network? The device disconnects and removes the saved password.");
      sdm_row(SDM_A_NONE, "name", "Network: %s", saved);
      sdm_row(SDM_A_BACK, NULL, "Cancel");
      sdm_row(SDM_A_WIFI_FORGET, NULL, "Forget");
      break;
   default:
      /* The keyboard. The first row shows the end of the text. */
      sdm_title("%s", sdm.field == sdm.psk ? "Password" : "Network name");
      sdm_say("A types a character. B deletes one. Left and Right select.");
      length = strlen(sdm.field);
      memset(text, '*', sizeof(text));
      if (sdm.field != sdm.psk) snprintf(text, sizeof(text), "%s", sdm.field);
      text[length < sizeof(text) - 1 ? length : sizeof(text) - 1] = 0;
      sdm_row(SDM_A_DONE, NULL, "%s%s_", length > 40 ? "..." : "", text + (length > 40 ? length - 40 : 0));
      for (i = 0; i < 4; i++) {
         struct sdm_row *row = sdm_row(SDM_A_KEY, (sdm.symbols ? symbols : letters)[i], "%s", "");
         char *c;
         row->grid = true;
         if (sdm.caps) for (c = row->key; *c; c++) *c = (char)toupper((unsigned char)*c);
      }
      sdm_row(SDM_A_CAPS, NULL, "%s", sdm.caps ? "CAPS" : "Caps");
      sdm_row(SDM_A_SYMBOLS, NULL, "%s", sdm.symbols ? "abc" : "#+=");
      sdm_row(SDM_A_SPACE, NULL, "Space");
      sdm_row(SDM_A_DELETE, NULL, "Delete");
      sdm_row(SDM_A_DONE, "done", "Done");
      break;
   }
}

static void sdm_build_bt(void) {
   struct sdm_device *device = sdm_bt_device(sdm.target);
   const char *status = sdm.b_status;
   bool entry = !strcmp(sdm.prompt, "pin") || !strcmp(sdm.prompt, "passkey");
   /* BlueZ reports the discovery some time after the request. */
   bool searching = sdm.want_scan || sdm.discovering || cpu_features_get_time_usec() < sdm.scan_at + 3000000;
   unsigned i, j;
   sdm_title("Bluetooth");
   switch (sdm.view) {
   case SDM_BT:
      if (!strcmp(status, "off")) {
         sdm_say("Bluetooth is off.");
         sdm_row(SDM_A_BT_ON, NULL, "Bluetooth                 Off");
      } else if (!strcmp(status, "starting")) {
         sdm_say("Bluetooth starts...");
         sdm_row(SDM_A_BT_OFF, NULL, "Bluetooth                 Turning on...");
      } else if (!strcmp(status, "on")) {
         sdm_say("Bluetooth is on.");
         sdm_row(SDM_A_BT_OFF, NULL, "Bluetooth                 On");
         for (i = 0; i < sdm.device_count; i++) if (sdm.devices[i].paired)
            sdm_row(SDM_A_BT_DEVICE, sdm.devices[i].address, "%s: %s", sdm_bt_name(sdm.devices[i].address),
               sdm.devices[i].connected ? "Connected" : "Paired");
         sdm_row(SDM_A_BT_ADD, NULL, "Add accessory");
      } else {
         sdm_say("Bluetooth is unavailable.");
         if (!strcmp(status, "unavailable")) {
            /* The worker gives the cause. Show it on rows of the screen width. */
            char error[161] = "", key[4] = "e0", *line = error, *cut;
            FILE *file = sdm_open("bluetooth.error");
            if (file && !fgets(error, sizeof(error), file)) error[0] = 0;
            if (file) fclose(file);
            error[strcspn(error, "\n")] = 0;
            while (*line) {
               for (cut = line + (strlen(line) > 48 ? 48 : strlen(line)); *cut && cut > line && *cut != ' '; cut--) {}
               if (cut == line) cut = line + 48;
               sdm_row(SDM_A_NONE, key, "%.*s", (int)(cut - line), line);
               key[1]++;
               line = cut + strspn(cut, " ");
            }
            if (error[0]) sdm_say("Bluetooth is unavailable. The cause is also in Logs/socket-bluetooth.log.");
            sdm_row(SDM_A_BT_ON, NULL, "Try again");
         }
      }
      sdm_row(SDM_A_BACK, NULL, "Back");
      break;
   case SDM_BT_DEVICE:
      sdm_title("Accessory");
      sdm_say("%s", sdm.message[0] ? sdm.message : device && device->connected ? "Connected." : "Not connected.");
      sdm_row(SDM_A_NONE, "name", "%s", sdm_bt_name(sdm.target));
      if (device && device->connected) sdm_row(SDM_A_BT_DISCONNECT, NULL, "Disconnect");
      else sdm_row(SDM_A_BT_CONNECT, NULL, "Connect");
      sdm_row(SDM_A_BT_ASK_FORGET, NULL, "Forget");
      sdm_row(SDM_A_BACK, NULL, "Back");
      break;
   case SDM_BT_FORGET:
      sdm_say("Forget this accessory? You must pair it again to use it.");
      sdm_row(SDM_A_NONE, "name", "%s", sdm_bt_name(sdm.target));
      sdm_row(SDM_A_BACK, NULL, "Cancel");
      sdm_row(SDM_A_BT_FORGET, NULL, "Forget");
      break;
   case SDM_BT_SCAN:
      sdm_title("Add accessory");
      if (sdm.message[0]) sdm_say("%s", sdm.message);
      else sdm_say("%s", searching ? "Searching... Put the accessory in pairing mode." : "Search finished.");
      for (i = 0; i < sdm.device_count; i++) {
         for (j = 0; j < sdm.found_count && strcmp(sdm.found[j], sdm.devices[i].address); j++) {}
         if (!sdm.devices[i].paired && sdm.devices[i].named && j < sdm.found_count)
            sdm_row(SDM_A_BT_CHOOSE, sdm.devices[i].address, "%s", sdm_bt_name(sdm.devices[i].address));
      }
      if (!searching) sdm_row(SDM_A_BT_ADD, NULL, "Search again");
      sdm_row(SDM_A_BACK, NULL, "Cancel");
      break;
   case SDM_BT_CONFIRM:
      sdm_say("Pair with this accessory?");
      sdm_row(SDM_A_NONE, "name", "%s", sdm_bt_name(sdm.target));
      sdm_row(SDM_A_BT_PAIR, NULL, "Pair");
      sdm_row(SDM_A_BACK, NULL, "Cancel");
      break;
   default:
      /* The name and the codes are in rows, because the status line goes to the log. */
      sdm_row(SDM_A_NONE, "name", "%s", sdm_bt_name(sdm.target));
      if (!strcmp(sdm.prompt, "confirm")) {
         sdm_say("Does the accessory show this code?");
         sdm_row(SDM_A_NONE, "code", "Code: %s", sdm.code);
         sdm_row(SDM_A_BT_YES, NULL, "Accept");
         sdm_row(SDM_A_BT_NO, NULL, "Reject");
      } else if (!strcmp(sdm.prompt, "display")) {
         sdm_say("Type this code on the accessory. Then press Enter on it.");
         sdm_row(SDM_A_NONE, "code", "Code: %s", sdm.code);
      } else if (entry) {
         sdm_say("Enter the code of the accessory. B deletes a digit.");
         sdm_row(SDM_A_NONE, "code", "Code: %s_", sdm.entry);
         sdm_row(SDM_A_BT_DIGIT, "0123456789", "%s", "")->grid = true;
         if (sdm.entry[0]) sdm_row(SDM_A_BT_SUBMIT, NULL, "Submit");
      } else sdm_say("%s", !strcmp(sdm.phase, "pair") ? "Pairing..." : "Connecting...");
      sdm_row(SDM_A_BACK, NULL, "Cancel");
      break;
   }
}

/* Make the rows of the current view. The selection stays on its row when
 * a list changes. */
static void sdm_build(void) {
   struct sdm_row old;
   bool keep = sdm.built == sdm.view && socket_menu.selected < sdm.count, found = false;
   unsigned i;
   if (sdm.view == SDM_CLOSED) return;
   if (keep) old = sdm.rows[socket_menu.selected];
   sdm.count = 0;
   if (sdm.view < SDM_BT) sdm_build_wifi();
   else sdm_build_bt();
   sdm.built = sdm.view;
   for (i = 0; keep && i < sdm.count; i++) {
      if (sdm.rows[i].act == old.act && !strcmp(sdm.rows[i].key, old.key)) {
         socket_menu.selected = i;
         found = true;
         break;
      }
   }
   if (socket_menu.selected >= sdm.count) socket_menu.selected = sdm.count - 1;
   /* The row of the selection went away. Do not stop on a row of text. */
   while (keep && !found && sdm.rows[socket_menu.selected].act == SDM_A_NONE && socket_menu.selected + 1 < sdm.count)
      socket_menu.selected++;
   /* The status has no secrets. Send it one time for each change. */
   if (strcmp(sdm.status, sdm.shown_status)) {
      memcpy(sdm.shown_status, sdm.status, sizeof(sdm.status));
      socket_menu_message(sdm.status);
   }
}

/* ---- Interface ---- */

static void socket_device_close(void) {
   if (sdm.view == SDM_CLOSED) return;
   if (sdm.view < SDM_BT) {
      /* Stop a pending scan or join and discard the typed password. */
      bool join = sdm.waiting == SDM_W_JOIN || sdm.waiting == SDM_W_CANCEL;
      if (sdm.waiting == SDM_W_SCAN || sdm.waiting == SDM_W_JOIN) sdm_wifi_send("cancel", NULL);
      /* The worker removes the password file. Remove it also without a worker. */
      if (join) sdm_remove("wifi.candidate");
      sdm.waiting = SDM_W_NONE;
      sdm.note[0] = 0;
      sdm_wifi_forget_typed();
   } else {
      /* The worker stops the agent. BlueZ then cancels discovery and pairing. */
      sdm_bt_request("close");
      sdm.prompt[0] = sdm.code[0] = 0;
      sdm.want_scan = false;
      sdm_wipe(sdm.entry, sizeof(sdm.entry));
   }
   sdm_wipe(sdm.rows, sizeof(sdm.rows));
   sdm.count = 0;
   sdm.view = sdm.built = SDM_CLOSED;
}

static void socket_device_open(unsigned section) {
   socket_device_close();
   sdm.shown_status[0] = sdm.note[0] = sdm.message[0] = 0;
   sdm.poll_at = cpu_features_get_time_usec() + 250000;
   if (section == 0) {
      sdm_show(SDM_WIFI, 0);
      sdm_wifi_status();
   } else {
      sdm.session[0] = sdm.target[0] = sdm.prompt[0] = 0;
      sdm.offset = 0;
      sdm.agent_ready = sdm.want_scan = false;
      sdm.phase = "pair";
      sdm_show(SDM_BT, 0);
      sdm_bt_request("open");
      sdm_bt_poll();
   }
   sdm_build();
}

static void socket_device_tick(void) {
   char path[PATH_MAX_LENGTH];
   retro_time_t now = cpu_features_get_time_usec();
   if (sdm.view == SDM_CLOSED || now < sdm.poll_at) return;
   sdm.poll_at = now + 250000;
   if (socket_sleep_path(path, sizeof(path), "shallow.sleep") && access(path, F_OK) == 0) {
      /* Sleep: stop the radio work of this page and erase the typed text.
       * Do this one time for each sleep. */
      unsigned section = sdm.view >= SDM_BT;
      if (sdm.asleep) return;
      socket_device_close();
      socket_device_open(section);
      sdm.asleep = true;
      return;
   }
   sdm.asleep = false;
   if (sdm.view < SDM_BT) sdm_wifi_poll();
   else sdm_bt_poll();
   sdm_build();
}

static const char *socket_device_title(void) { return sdm.title; }
static unsigned socket_device_count(void) { return sdm.count; }

static void socket_device_label(unsigned row, char *text, size_t size) {
   struct sdm_row *item = &sdm.rows[row < sdm.count ? row : 0];
   size_t length = strlen(item->key), used = 0, i;
   if (!size) return;
   text[0] = 0;
   if (row >= sdm.count) return;
   if (!item->grid) { snprintf(text, size, "%s", item->text); return; }
   for (i = 0; i < length && used + 4 < size; i++) {
      bool on = row == socket_menu.selected && i == (sdm.col < length ? sdm.col : length - 1);
      used += (size_t)snprintf(text + used, size - used, on ? "[%c]" : " %c ", item->key[i]);
   }
}

/* Go back one step. Return false if the page itself must close. */
static bool sdm_back(void) {
   size_t length;
   switch (sdm.view) {
   case SDM_KEYS:
      length = strlen(sdm.field);
      if (length) sdm.field[length - 1] = 0;
      else sdm_show(SDM_FORM, sdm.field == sdm.psk);
      break;
   case SDM_JOINING:
      /* The join can complete before the worker reads the cancel request.
       * The result of the cancel request shows which one occurred. */
      if (sdm.waiting == SDM_W_JOIN) sdm_wifi_send("cancel", NULL);
      break;
   case SDM_FORM:
      sdm_wifi_forget_typed();
      sdm.note[0] = 0;
      sdm_show(SDM_NETS, 0);
      break;
   case SDM_NETS:
      if (sdm.waiting == SDM_W_SCAN) sdm_wifi_send("cancel", NULL);
      sdm.waiting = SDM_W_NONE;
      sdm.note[0] = 0;
      sdm_show(SDM_WIFI, 0);
      break;
   case SDM_WIFI_FORGET:
      sdm_show(SDM_WIFI, 0);
      break;
   case SDM_BT_BUSY:
      length = strlen(sdm.entry);
      if (length) sdm.entry[length - 1] = 0;
      else sdm_bt_cancel("Canceled.");
      break;
   case SDM_BT_SCAN:
      sdm_bt_request("scan off");
      sdm.want_scan = false;
      sdm.scan_at = 0;
      sdm.message[0] = 0;
      sdm_show(SDM_BT, 0);
      break;
   case SDM_BT_CONFIRM:
      sdm_show(SDM_BT_SCAN, 0);
      break;
   case SDM_BT_FORGET:
      sdm_show(SDM_BT_DEVICE, 1);
      break;
   case SDM_BT_DEVICE:
      sdm.message[0] = 0;
      sdm_show(SDM_BT, 0);
      break;
   default:
      socket_device_close();
      return false;
   }
   return true;
}

static void sdm_type(char *field, size_t max, char c) {
   size_t length = strlen(field);
   if (length < max) { field[length] = c; field[length + 1] = 0; }
}

static bool sdm_activate(struct sdm_row *row) {
   size_t length = strlen(row->key), col = length && sdm.col >= length ? length - 1 : sdm.col;
   unsigned i;
   switch (row->act) {
   case SDM_A_BACK: return sdm_back();
   case SDM_A_WIFI_POWER: sdm_wifi_send(!strcmp(sdm.w_state, "off") ? "on" : "off", NULL); break;
   case SDM_A_WIFI_SCAN:
      sdm.network_count = 0;
      sdm.note[0] = 0;
      sdm_wifi_send("scan", NULL);
      sdm_show(SDM_NETS, 0);
      break;
   case SDM_A_WIFI_RETRY: sdm_wifi_send("reconnect", NULL); break;
   case SDM_A_WIFI_ASK_FORGET: sdm_show(SDM_WIFI_FORGET, 1); break;
   case SDM_A_WIFI_FORGET:
      sdm_wifi_send("forget", NULL);
      sdm_show(SDM_WIFI, 0);
      break;
   case SDM_A_WIFI_CHOOSE:
      for (i = 0; i < sdm.network_count && strcmp(sdm.networks[i].ssid, row->key); i++) {}
      if (i == sdm.network_count) break;
      if (sdm.networks[i].supported) sdm_wifi_open_form(row->key, false);
      else snprintf(sdm.note, sizeof(sdm.note), "This device joins WPA2-Personal networks only.");
      break;
   case SDM_A_WIFI_HIDDEN: sdm_wifi_open_form("", true); break;
   case SDM_A_EDIT_SSID: sdm_wifi_edit(sdm.ssid, 32); break;
   case SDM_A_EDIT_PSK: sdm_wifi_edit(sdm.psk, 64); break;
   case SDM_A_WIFI_JOIN: sdm_wifi_join(); break;
   case SDM_A_WIFI_RECONNECT:
      sdm_wifi_forget_typed();
      sdm_wifi_send("reconnect", NULL);
      sdm.note[0] = 0;
      sdm_show(SDM_WIFI, 0);
      break;
   case SDM_A_KEY: sdm_type(sdm.field, sdm.field_max, row->key[col]); break;
   case SDM_A_CAPS: sdm.caps = !sdm.caps; break;
   case SDM_A_SYMBOLS: sdm.symbols = !sdm.symbols; break;
   case SDM_A_SPACE: sdm_type(sdm.field, sdm.field_max, ' '); break;
   case SDM_A_DELETE:
      length = strlen(sdm.field);
      if (length) sdm.field[length - 1] = 0;
      break;
   case SDM_A_DONE: sdm_show(SDM_FORM, sdm.field == sdm.psk); break;
   case SDM_A_BT_ON: sdm_bt_request("on"); break;
   case SDM_A_BT_OFF: sdm_bt_request("off"); break;
   case SDM_A_BT_DEVICE:
   case SDM_A_BT_CHOOSE:
      /* This selects the accessory only. Pair or Connect starts the work. */
      snprintf(sdm.target, sizeof(sdm.target), "%.17s", row->key);
      sdm.message[0] = 0;
      sdm_show(row->act == SDM_A_BT_DEVICE ? SDM_BT_DEVICE : SDM_BT_CONFIRM, 1);
      break;
   case SDM_A_BT_ADD: sdm_bt_scan(); break;
   case SDM_A_BT_CONNECT: sdm_bt_begin("connect", 20); break;
   case SDM_A_BT_DISCONNECT: sdm_bt_command("disconnect", sdm.target); break;
   case SDM_A_BT_ASK_FORGET: sdm_show(SDM_BT_FORGET, 1); break;
   case SDM_A_BT_FORGET:
      sdm_bt_command("remove", sdm.target);
      sdm.message[0] = 0;
      sdm_show(SDM_BT, 0);
      break;
   case SDM_A_BT_PAIR:
      sdm_bt_request("scan off");
      sdm.want_scan = false;
      sdm.scan_at = 0;
      sdm_bt_begin("pair", 60);
      break;
   case SDM_A_BT_YES:
   case SDM_A_BT_NO:
      sdm_bt_command("answer", row->act == SDM_A_BT_YES ? "yes" : "no");
      sdm.prompt[0] = 0;
      break;
   case SDM_A_BT_DIGIT:
      /* A passkey has 6 digits. A legacy PIN has a maximum of 16.
       * ponytail: digits only. Add letters if an accessory needs a text PIN. */
      sdm_type(sdm.entry, !strcmp(sdm.prompt, "passkey") ? 6 : 16, row->key[col]);
      break;
   case SDM_A_BT_SUBMIT:
      sdm_bt_command("answer", sdm.entry);
      sdm_wipe(sdm.entry, sizeof(sdm.entry));
      sdm.prompt[0] = 0;
      break;
   default: break;
   }
   return true;
}

static bool socket_device_action(enum menu_action action, unsigned row) {
   struct sdm_row *item;
   size_t length;
   bool stay = true;
   if (sdm.view == SDM_CLOSED) return false;
   if (row >= sdm.count) return true;
   item = &sdm.rows[row];
   length = strlen(item->key);
   if (action == MENU_ACTION_CANCEL) stay = sdm_back();
   else if (action == MENU_ACTION_OK) stay = sdm_activate(item);
   else if ((action == MENU_ACTION_LEFT || action == MENU_ACTION_RIGHT) && item->grid && length) {
      if (sdm.col >= length) sdm.col = (unsigned)length - 1;
      sdm.col = (sdm.col + (unsigned)length + (action == MENU_ACTION_LEFT ? -1 : 1)) % (unsigned)length;
   } else return true;
   if (stay) sdm_build();
   return stay;
}
#endif

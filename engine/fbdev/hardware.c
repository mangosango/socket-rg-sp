// H700 controls for the whole Socket session, including RetroArch.
// Codes, hall polarity and backlight curve follow slot. Sleep follows Slot.
#define _GNU_SOURCE
#include "hardware_input.h"
#include <errno.h>
#include <fcntl.h>
#include <glob.h>
#include <inttypes.h>
#include <linux/uinput.h>
#include <math.h>
#include <poll.h>
#include <signal.h>
#include <sound/asound.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static struct Controls controls;
static struct LidControls lid_controls;
static int virtual_pad = -1, stopped_app;
static volatile sig_atomic_t running = 1;
static struct pollfd inputs[32];
static int input_count;
static struct ControlStream streams[32];
static char run_dir[512], backlight[512], hall_path[512];
static int brightness_step = 6, max_brightness = 255;
static int hall_closed = -1, lid_input = -1;
static enum { NO_SLEEP, POWER_SLEEP, LID_SLEEP } sleep_requested;
static unsigned char held[KEY_MAX + 1];
static int volume_level = 40, temperature_step;
static uint32_t control_sequence;
static char settings_path[512];
static uint64_t settings_due;
static int game_poweroff(void);
static uint64_t game_shutdown_pending, shutdown_at, poweroff_retry_at;
static void commit_shutdown(uint64_t delay);
static int save_settings(void);

static uint64_t millis(void) {
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (uint64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

static uint64_t boot_millis(void) {
	struct timespec t;
	clock_gettime(CLOCK_BOOTTIME, &t);
	return (uint64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

static int number(const char *path) {
	FILE *f = fopen(path, "r");
	int n = -1;
	if (f) { if (fscanf(f, "%d", &n) != 1) n = -1; fclose(f); }
	return n;
}

static int write_text(const char *path, const char *text) {
	int fd = open(path, O_WRONLY | O_CLOEXEC);
	if (fd < 0) { perror(path); return -1; }
	int ok = write(fd, text, strlen(text)) == (ssize_t)strlen(text);
	if (!ok) perror(path);
	close(fd);
	return ok ? 0 : -1;
}

static void quicken_poll(const char *path) {
	int interval = number(path);
	// Match Slot without slowing a device that already polls faster.
	if (interval > 10 && !write_text(path, "10\n"))
		fprintf(stderr, "socket-hardware: %s: poll %d ms -> 10 ms\n", path, interval);
}

static int command(const char *const argv[]) {
	pid_t pid = fork();
	if (pid < 0) { perror("socket-hardware: fork"); return -1; }
	if (!pid) {
		execvp(argv[0], (char *const *)argv);
		perror(argv[0]);
		_exit(127);
	}
	int status;
	while (waitpid(pid, &status, 0) < 0) { if (errno != EINTR) return -1; }
	if (!WIFEXITED(status) || WEXITSTATUS(status)) {
		fprintf(stderr, "socket-hardware: %s failed (%d)\n", argv[0], status);
		return -1;
	}
	return 0;
}

// Like Slot, unload the WiFi driver before poweroff. The card script does this.
static int system_poweroff(void) {
	char script[1024];
	const char *system = getenv("SOCKET_SYSTEM");
	if (settings_due) save_settings();
	sync();
	if (system && *system && snprintf(script, sizeof(script), "%s/poweroff.sh", system) < (int)sizeof(script)) {
		const char *argv[] = { "/bin/sh", script, NULL };
		return command(argv);
	}
	const char *argv[] = { "poweroff", NULL };
	return command(argv);
}

static int mixer_read(struct snd_ctl_elem_info *info, struct snd_ctl_elem_value *value) {
	int fd = open("/dev/snd/controlC0", O_RDWR | O_CLOEXEC);
	if (fd < 0) { perror("socket-hardware: mixer open"); return -1; }
	*info = (struct snd_ctl_elem_info){ .id = { .iface = SNDRV_CTL_ELEM_IFACE_MIXER, .name = "digital volume" } };
	if (ioctl(fd, SNDRV_CTL_IOCTL_ELEM_INFO, info) < 0) goto failed;
	if (info->id.iface != SNDRV_CTL_ELEM_IFACE_MIXER || info->id.index ||
			info->id.device || info->id.subdevice ||
			strncmp((const char *)info->id.name, "digital volume", sizeof(info->id.name)) ||
			info->type != SNDRV_CTL_ELEM_TYPE_INTEGER || (info->access & SNDRV_CTL_ELEM_ACCESS_INACTIVE) ||
			(info->access & SNDRV_CTL_ELEM_ACCESS_READWRITE) != SNDRV_CTL_ELEM_ACCESS_READWRITE ||
			!info->count || info->count > sizeof(value->value.integer.value) / sizeof(long) || info->value.integer.min < 0 ||
			info->value.integer.max <= info->value.integer.min || info->value.integer.max > 65535) {
		errno = EINVAL;
		goto failed;
	}
	*value = (struct snd_ctl_elem_value){ .id = info->id };
	if (ioctl(fd, SNDRV_CTL_IOCTL_ELEM_READ, value) < 0) goto failed;
	for (unsigned i = 0; i < info->count; i++) {
		if (value->value.integer.value[i] < info->value.integer.min ||
				value->value.integer.value[i] > info->value.integer.max) {
			errno = ERANGE;
			goto failed;
		}
	}
	return fd;
failed:
	perror("socket-hardware: mixer read");
	close(fd);
	return -1;
}

static int mixer_write(int fd, struct snd_ctl_elem_value *value) {
	// The device log shows a transient EPERM. Retry once before reporting it.
	for (int attempt = 0; attempt < 2; attempt++) {
		if (ioctl(fd, SNDRV_CTL_IOCTL_ELEM_WRITE, value) >= 0) return 0;
		perror("socket-hardware: mixer write");
		if (!attempt) usleep(20000);
	}
	return -1;
}

static void forward(unsigned short type, unsigned short code, int value) {
	struct input_event e = { .type = type, .code = code, .value = value };
	if (write(virtual_pad, &e, sizeof(e)) != sizeof(e)) {
		perror("socket-hardware: uinput write");
		running = 0;
	}
	if (type == EV_KEY && code <= KEY_MAX) held[code] = value != 0;
}

// Publish one complete snapshot so both renderers use the same controls.
static int publish_controls(int volume, int kind) {
	char path[1024], temporary[1024];
	snprintf(path, sizeof(path), "%s/controls", run_dir);
	snprintf(temporary, sizeof(temporary), "%s/controls.tmp", run_dir);
	FILE *f = fopen(temporary, "w");
	if (!f) { perror("socket-hardware: control snapshot"); return -1; }
	uint32_t sequence = control_sequence + (kind != 0);
	// Version 2 adds the Slot screen temperature step, 0 to 9. Kind 3 is temperature.
	int ok = fprintf(f, "2 %u %d %d %d %d\n", sequence, volume, brightness_step - 1, temperature_step, kind) > 0;
	if (fclose(f)) ok = 0;
	if (!ok || rename(temporary, path)) {
		perror("socket-hardware: control snapshot");
		unlink(temporary);
		return -1;
	}
	control_sequence = sequence;
	volume_level = volume;
	// Save user changes after one second without another change.
	if (kind) settings_due = millis() + 1000;
	return 0;
}

// Keep volume, brightness and temperature across power cycles.
static int save_settings(void) {
	settings_due = 0;
	if (!settings_path[0]) return 0;
	char temporary[1024], directory[512];
	snprintf(temporary, sizeof(temporary), "%s.tmp", settings_path);
	int fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
	if (fd < 0) { perror("socket-hardware: settings"); return -1; }
	char text[64];
	int size = snprintf(text, sizeof(text), "socket-controls-v1 %d %d %d\n", volume_level, brightness_step, temperature_step);
	int ok = write(fd, text, size) == size && !fsync(fd);
	if (close(fd)) ok = 0;
	if (ok && rename(temporary, settings_path)) ok = 0;
	if (!ok) { perror("socket-hardware: settings"); unlink(temporary); return -1; }
	snprintf(directory, sizeof(directory), "%s", settings_path);
	char *slash = strrchr(directory, '/');
	if (slash) {
		*slash = 0;
		fd = open(directory[0] ? directory : "/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
		if (fd >= 0) { fsync(fd); close(fd); }
	}
	return 0;
}

// Return 0 only for a complete, valid settings record.
static int load_settings(void) {
	if (!settings_path[0]) return -1;
	FILE *f = fopen(settings_path, "r");
	if (!f) return -1;
	char line[64], extra;
	int volume, step, temperature;
	int ok = fgets(line, sizeof(line), f) && fgetc(f) == EOF &&
		sscanf(line, "socket-controls-v1 %d %d %d%c", &volume, &step, &temperature, &extra) == 4 && extra == '\n' &&
		volume >= 0 && volume <= 100 && volume % 5 == 0 && step >= 1 && step <= 10 &&
		temperature >= 0 && temperature <= 9;
	fclose(f);
	if (!ok) { fprintf(stderr, "socket-hardware: ignoring invalid settings %s\n", settings_path); return -1; }
	volume_level = volume;
	brightness_step = step;
	temperature_step = temperature;
	return 0;
}

static void neutral_pad(void) {
	for (int code = 0; code <= KEY_MAX; code++) if (held[code]) forward(EV_KEY, code, 0);
	forward(EV_ABS, ABS_HAT0X, 0);
	forward(EV_ABS, ABS_HAT0Y, 0);
	forward(EV_ABS, ABS_Z, 0);
	forward(EV_ABS, ABS_RX, 0);
	forward(EV_SYN, SYN_REPORT, 0);
}

static int backlight_value(int step) {
	double floor = fmax(1, round(max_brightness * (8.0 / 255.0)));
	return (int)round(floor + (max_brightness - floor) * pow((step - 1) / 9.0, 1.75));
}

static int set_backlight(int level) {
	if (backlight[0]) {
		char value[32];
		snprintf(value, sizeof(value), "%d", level);
		return write_text(backlight, value);
	}
	// Allwinner disp2 ABI from BaseOS charger-wait.c.
	int fd = open("/dev/disp", O_RDWR | O_CLOEXEC);
	unsigned long args[4] = { 0, (unsigned long)level, 0, 0 };
	int ok = fd >= 0 && ioctl(fd, 0x102, args) >= 0;
	if (!ok) perror("socket-hardware: backlight");
	if (fd >= 0) close(fd);
	return ok ? 0 : -1;
}

static int get_backlight(void) {
	if (backlight[0]) return number(backlight);
	int fd = open("/dev/disp", O_RDWR | O_CLOEXEC);
	unsigned long args[4] = {0};
	int level = fd >= 0 ? ioctl(fd, 0x103, args) : -1;
	if (fd >= 0) close(fd);
	return level;
}

static void brightness(int direction) {
	int next = brightness_step + direction;
	if (next < 1) next = 1;
	if (next > 10) next = 10;
	if (!set_backlight(backlight_value(next))) brightness_step = next;
}

static int pad_button(unsigned short code) {
	return (code >= 0x130 && code <= 0x138) || code == 0x13a || code == 0x13b;
}

static void action(enum ControlAction what, unsigned short type, unsigned short code, int value) {
	if (what == RESET) {
		neutral_pad();
	} else if (what == FORWARD) {
		if ((type == EV_KEY && pad_button(code)) || type == EV_ABS || type == EV_SYN) forward(type, code, value);
	} else if (what == BRIGHTNESS) {
		brightness(value);
		publish_controls(volume_level, 2);
	} else if (what == TEMPERATURE) {
		int next = temperature_step + (value > 0 ? 1 : -1);
		temperature_step = next < 0 ? 0 : next > 9 ? 9 : next;
		publish_controls(volume_level, 3);
	} else if (what == VOLUME) {
		int next = volume_level + (value > 0 ? 5 : -5);
		if (next < 0) next = 0;
		if (next > 100) next = 100;
		publish_controls(next, 1);
	} else if (what == SLEEP) {
		sleep_requested = type == EV_SW && code == SW_LID ? LID_SLEEP : POWER_SLEEP;
	} else if (what == SHUTDOWN) {
		if (game_poweroff()) return;
		// Use the BaseOS wrapper so init flushes and unmounts before PMIC off.
		// Keep running until init stops the session, so no app is killed early.
		if (!system_poweroff()) commit_shutdown(10000);
	}
}

static int bit(const unsigned long *bits, int n) {
	return (bits[n / (8 * sizeof(long))] >> (n % (8 * sizeof(long)))) & 1;
}

static int create_pad(int fd) {
	virtual_pad = open("/dev/uinput", O_WRONLY | O_CLOEXEC);
	if (virtual_pad < 0) { perror("/dev/uinput"); return -1; }
	struct uinput_user_dev dev = { .name = "Socket H700 Gamepad", .id = { .bustype = BUS_VIRTUAL, .vendor = 0x534f, .product = 1, .version = 1 } };
	if (ioctl(virtual_pad, UI_SET_EVBIT, EV_KEY) < 0 || ioctl(virtual_pad, UI_SET_EVBIT, EV_ABS) < 0) return -1;
	// Fixed capabilities keep RetroArch button indexes stable across physical pads.
	for (int k = 0x130; k <= 0x13b; k++)
		if (pad_button(k) && ioctl(virtual_pad, UI_SET_KEYBIT, k) < 0) return -1;
	if (ioctl(virtual_pad, UI_SET_KEYBIT, BTN_TRIGGER_HAPPY1) < 0 ||
			ioctl(virtual_pad, UI_SET_KEYBIT, BTN_TRIGGER_HAPPY2) < 0) return -1;
	const int axes[] = { ABS_HAT0X, ABS_HAT0Y, ABS_Z, ABS_RX };
	for (unsigned i = 0; i < sizeof(axes) / sizeof(*axes); i++) {
		struct input_absinfo a;
		int axis = axes[i];
		if (ioctl(fd, EVIOCGABS(axis), &a) < 0) continue;
		if (ioctl(virtual_pad, UI_SET_ABSBIT, axis) < 0) return -1;
		dev.absmin[axis] = a.minimum;
		dev.absmax[axis] = a.maximum;
		dev.absfuzz[axis] = a.fuzz;
		dev.absflat[axis] = a.flat;
	}
	if (write(virtual_pad, &dev, sizeof(dev)) != sizeof(dev) || ioctl(virtual_pad, UI_DEV_CREATE) < 0) return -1;
	return 0;
}

static int open_inputs(void) {
	for (int i = 0; i < 32; i++) {
		char path[64], name[128] = {0};
		snprintf(path, sizeof(path), "/dev/input/event%d", i);
		int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
		if (fd < 0) continue;
		ioctl(fd, EVIOCGNAME(sizeof(name)), name);
		if (!strcmp(name, "Socket H700 Gamepad")) { close(fd); continue; }
		unsigned long keys[KEY_MAX / (8 * sizeof(long)) + 1] = {0}, sw[1] = {0};
		ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(keys)), keys);
		ioctl(fd, EVIOCGBIT(EV_SW, sizeof(sw)), sw);
		int pad = bit(keys, BTN_SOUTH);
		if (!pad && !bit(keys, KEY_POWER) && !bit(keys, KEY_VOLUMEUP) && !bit(keys, KEY_VOLUMEDOWN) && !bit(sw, SW_LID)) { close(fd); continue; }
		fprintf(stderr, "socket-hardware: input %s (%s), lid=%d\n", path, name, bit(sw, SW_LID));
		if (ioctl(fd, EVIOCGRAB, 1) < 0) { perror("socket-hardware: EVIOCGRAB (another input daemon?)"); close(fd); return -1; }
		snprintf(path, sizeof(path), "/sys/class/input/event%d/device/poll", i);
		quicken_poll(path);
		if (bit(sw, SW_LID)) lid_input = input_count;
		inputs[input_count++] = (struct pollfd){ .fd = fd, .events = POLLIN };
		if (pad && virtual_pad < 0 && create_pad(fd) < 0) { perror("socket-hardware: create virtual pad"); return -1; }
	}
	if (virtual_pad < 0) fprintf(stderr, "socket-hardware: no H700 gamepad found\n");
	return virtual_pad < 0 ? -1 : 0;
}

static void find_hall(void) {
	glob_t paths = {0};
	if (!glob("/sys/class/power_supply/*/hallkey", 0, NULL, &paths)) {
		const char *path = paths.gl_pathv[0];
		for (size_t i = 0; i < paths.gl_pathc; i++) {
			int value = number(paths.gl_pathv[i]);
			if (value != 0 && value != 1) continue;
			path = paths.gl_pathv[i];
			break;
		}
		snprintf(hall_path, sizeof(hall_path), "%s", path);
		fprintf(stderr, "socket-hardware: hall sensor %s\n", hall_path);
	}
	globfree(&paths);
}

static int read_lid(void) {
	int hall = hall_path[0] ? number(hall_path) : -1;
	int closed = -1;
	unsigned long sw[1] = {0};
	if (hall == 0 || hall == 1) closed = hall == 0;
	else if (lid_input >= 0 && ioctl(inputs[lid_input].fd, EVIOCGSW(sizeof(sw)), sw) >= 0) closed = bit(sw, SW_LID);
	static int previous = -2;
	if (closed != previous) {
		fprintf(stderr, "socket-hardware: t=%" PRIu64 "ms lid %s (hall=%d, input_index=%d)\n",
			millis(), closed < 0 ? "unavailable" : closed ? "closed" : "open", hall, lid_input);
		previous = closed;
	}
	return closed;
}

static void check_lid(void) {
	int closed = read_lid();
	char path[1024];
	snprintf(path, sizeof(path), "%s/poweroff.request", run_dir);
	// Do not stop the app while its shutdown save is pending.
	int pending = access(path, F_OK) == 0;
	static int was_pending;
	if (pending != was_pending) {
		fprintf(stderr, "socket-hardware: t=%" PRIu64 "ms poweroff request %s\n",
			millis(), pending ? "pending, lid sleep blocked" : "cleared");
		was_pending = pending;
	}
	if ((closed != 1 || !pending) &&
			controls_lid_tick(&lid_controls, closed, millis()) && sleep_requested != POWER_SLEEP)
		sleep_requested = LID_SLEEP;
	hall_closed = closed;
}

static int active_game(void) {
	char path[1024];
	snprintf(path, sizeof(path), "%s/game.active", run_dir);
	int pid = number(path);
	snprintf(path, sizeof(path), "%s/app.pid", run_dir);
	return pid > 1 && pid == number(path) && !kill(pid, 0) ? pid : 0;
}

static void remove_request(const char *kind) {
	char path[1024];
	snprintf(path, sizeof(path), "%s/%s.request", run_dir, kind);
	unlink(path);
}

static int game_request(const char *kind, int resume_pid) {
	char path[1024], temporary[1024], ack[1024], token[64], expected[80], actual[80];
	struct timespec now;
	clock_gettime(CLOCK_BOOTTIME, &now);
	static unsigned sequence;
	snprintf(token, sizeof(token), "%" PRIu64 "%09lu%03u", (uint64_t)now.tv_sec,
		(unsigned long)now.tv_nsec, ++sequence % 1000);
	snprintf(path, sizeof(path), "%s/%s.request", run_dir, kind);
	snprintf(temporary, sizeof(temporary), "%s/%s.request.tmp", run_dir, kind);
	snprintf(ack, sizeof(ack), "%s/%s.ack", run_dir, kind);
	unlink(ack);
	FILE *f = fopen(temporary, "w");
	if (!f) return -1;
	int ok = fprintf(f, "%s\n", token) > 0;
	if (fclose(f)) ok = 0;
	if (!ok || rename(temporary, path)) { unlink(temporary); return -1; }
	if (resume_pid && kill(resume_pid, SIGCONT)) { remove_request(kind); return -1; }
	snprintf(expected, sizeof(expected), "%s ok\n", token);
	int result = -1;
	// Bound the wait even when the process or its clock stops making progress.
	// A shutdown save syncs the card, so it gets 30 seconds instead of 5.
	int attempts = strcmp(kind, "poweroff") ? 500 : 3000;
	for (int attempt = 0; attempt < attempts && running; attempt++) {
		f = fopen(ack, "r");
		if (f) {
			size_t size = fread(actual, 1, sizeof(actual) - 1, f);
			actual[size] = 0;
			fclose(f);
			if (!strcmp(actual, expected)) { result = 0; break; }
			snprintf(expected, sizeof(expected), "%s error\n", token);
			if (!strcmp(actual, expected)) break;
			snprintf(expected, sizeof(expected), "%s ok\n", token);
		}
		usleep(10000);
	}
	if ((result || strcmp(kind, "poweroff")) && (running || strcmp(kind, "wake"))) remove_request(kind);
	return result;
}

// Return nonzero when this shutdown belongs to a game, including failed saves.
static int game_poweroff(void) {
	int pid = active_game();
	if (game_shutdown_pending && pid && millis() < game_shutdown_pending) return 1;
	game_shutdown_pending = 0;
	if (!pid) return 0;
	int was_stopped = stopped_app == pid;
	neutral_pad();
	if (!game_request("poweroff", was_stopped ? pid : 0)) {
		stopped_app = 0;
		game_shutdown_pending = millis() + 15000;
	} else {
		fprintf(stderr, "socket-hardware: game poweroff save failed\n");
		// Keep a failed shutdown save asleep until an explicit wake.
		if (was_stopped) kill(pid, SIGSTOP);
		// An awake game continues. Wake restores the audio muted for the save.
		else game_request("wake", 0);
	}
	return 1;
}

// Like Slot, a started shutdown keeps the screen dark and the audio muted.
// Wake input cannot cancel it. A saved game must not show the launcher.
// The helper powers off again after delay milliseconds if the device is still on.
static void commit_shutdown(uint64_t delay) {
	if (shutdown_at) return;
	shutdown_at = millis();
	poweroff_retry_at = shutdown_at + delay;
	fprintf(stderr, "socket-hardware: t=%" PRIu64 "ms shutdown started, screen and audio stay off\n", shutdown_at);
}

static struct SleepControls wait_for_wake(uint64_t sleep_at, uint64_t boot_at) {
	struct SleepControls wake = { .closed = hall_closed, .sleep_at = sleep_at };
	uint64_t retry_at = 0;
	while (running) {
		if (poll(inputs, input_count, 100) < 0 && errno != EINTR) {
			perror("socket-hardware: sleep poll");
			running = 0;
			break;
		}
		int awake = 0, shutdown = 0, lid_wake = 0;
		for (int i = 0; i < input_count; i++) {
			if (inputs[i].revents & (POLLERR | POLLHUP | POLLNVAL)) running = 0;
			struct input_event ev;
			while (running && read(inputs[i].fd, &ev, sizeof(ev)) == sizeof(ev)) {
				if (ev.type == EV_SYN && ev.code == SYN_DROPPED) {
					streams[i].dropping = 1;
					controls_sleep_event(&wake, ev.type, ev.code, ev.value, millis());
					continue;
				}
				if (streams[i].dropping) {
					if (ev.type == EV_SYN && ev.code == SYN_REPORT) streams[i].dropping = 0;
					continue;
				}
				// Read the current lid state below, because queued switch events can be stale.
				if (ev.type != EV_SW) {
					enum SleepAction request = controls_sleep_event(&wake, ev.type, ev.code, ev.value, millis());
					awake |= request == SLEEP_WAKE;
					shutdown |= request == SLEEP_OFF;
				}
			}
		}
		int closed = read_lid();
		if (closed >= 0) {
			lid_wake = controls_sleep_event(&wake, EV_SW, SW_LID, closed, millis()) == SLEEP_WAKE;
			awake |= lid_wake;
			hall_closed = closed;
		}
		if (shutdown_at) {
			// Like Slot's lid watchdog, retry poweroff while the screen stays off.
			// A committed shutdown never lights the screen again.
			if (millis() < poweroff_retry_at) continue;
			fprintf(stderr, "socket-hardware: t=%" PRIu64 "ms shutdown stalled, powering off\n", millis());
			poweroff_retry_at = millis() + 10000;
			system_poweroff();
			continue;
		}
		enum SleepAction timed = controls_sleep_tick(&wake, millis());
		shutdown |= timed == SLEEP_OFF;
		if (shutdown && !awake) {
			action(SHUTDOWN, 0, 0, 0);
			// A durable game save gives the app 60 seconds to exit before the watchdog.
			if (game_shutdown_pending) commit_shutdown(60000);
			if (shutdown_at || !running) continue;
			if (!stopped_app) break;
		}
		if (awake) {
			fprintf(stderr, "socket-hardware: t=%" PRIu64 "ms wake (%s), asleep=%" PRIu64 "ms boot=%" PRIu64 "ms boot_asleep=%" PRIu64 "ms\n",
				millis(), lid_wake ? "lid open" : "power button", millis() - sleep_at,
				boot_millis(), boot_millis() - boot_at);
			break;
		}
		if (running && timed == SLEEP_TIMEOUT && millis() >= retry_at) {
			if (active_game()) {
				game_poweroff();
				if (game_shutdown_pending) { commit_shutdown(60000); continue; }
				retry_at = millis() + 5000;
				continue;
			}
			// No game needs a save. Like Slot, power off without resuming the frontend.
			fprintf(stderr, "socket-hardware: t=%" PRIu64 "ms boot=%" PRIu64 "ms sleep timeout, powering off\n", millis(), boot_millis());
			commit_shutdown(10000);
			system_poweroff();
		}
	}
	return wake;
}

static void suspend_device(void) {
	char pid_path[1024];
	snprintf(pid_path, sizeof(pid_path), "%s/app.pid", run_dir);
	int pid = number(pid_path);
	int game = active_game();
	int shallow = lid_input >= 0 || hall_closed >= 0;
	int level = shallow ? get_backlight() : -1;
	int slept = 0;
	struct SleepControls wake = {0};
	if (settings_due) save_settings();
	neutral_pad();
	if (game && game_request("sleep", 0)) {
		fprintf(stderr, "socket-hardware: game sleep save failed\n");
	}
	if (game && sleep_requested == LID_SLEEP && read_lid() == 0) goto resume;
	neutral_pad();
	if (pid > 1 && kill(pid, SIGSTOP) == 0) stopped_app = pid;
	if (shallow && (!stopped_app || level < 0)) {
		fprintf(stderr, "socket-hardware: t=%" PRIu64 "ms sleep aborted (%s)\n", millis(), !stopped_app ? "cannot stop app" : "cannot read backlight");
		goto resume;
	}
	struct snd_ctl_elem_info info;
	struct snd_ctl_elem_value saved, muted;
	int mixer = mixer_read(&info, &saved);
	int changed = 0;
	if (mixer >= 0) {
		muted = saved;
		for (unsigned i = 0; i < info.count; i++) muted.value.integer.value[i] = info.value.integer.min;
		changed = mixer_write(mixer, &muted) == 0;
	}
	if (shallow) {
		// shortcut: SP lid wake uses idle sleep, use suspend only after kernel wake support is verified.
		if (!set_backlight(0)) {
			uint64_t sleep_at = millis(), boot_at = boot_millis();
			fprintf(stderr, "socket-hardware: t=%" PRIu64 "ms boot=%" PRIu64 "ms shallow sleep (%s, app=%d, lid=%d), poweroff request after %ds\n",
				sleep_at, boot_at, sleep_requested == LID_SLEEP ? "lid closed" : "power button", stopped_app, hall_closed,
				180);
			sync();
			slept = 1;
			wake = wait_for_wake(sleep_at, boot_at);
		}
		// A started shutdown never lights the screen again.
		if (level >= 0 && !shutdown_at) set_backlight(level);
	} else {
		// shortcut: mem stops this timer, add timed shutdown after RTC wake is verified.
		const char *standby = "/sys/class/power_supply/axp2202-battery/os_sleep";
		if (access(standby, W_OK) == 0) write_text(standby, "16");
		sync();
		write_text("/sys/power/state", "mem");
	}
	if (changed) mixer_write(mixer, &saved);
	if (mixer >= 0) close(mixer);
resume:
	// Discard wake input before the application runs again.
	for (int i = 0; i < input_count; i++) {
		struct input_event ev;
		while (read(inputs[i].fd, &ev, sizeof(ev)) == sizeof(ev)) {
			if (ev.type == EV_KEY && ev.code == KEY_POWER && ev.value == 0) wake.power = 0;
		}
	}
	memset(&controls, 0, sizeof(controls));
	controls.power = wake.power ? 2 : 0;
	controls.power_at = wake.power_at;
	memset(streams, 0, sizeof(streams));
	if (game && active_game() == game && (running || stopped_app)) game_request("wake", stopped_app ? stopped_app : game);
	// A frontend stopped for shutdown stays stopped so it cannot play audio.
	else if (stopped_app && !shutdown_at) kill(stopped_app, SIGCONT);
	stopped_app = 0;
	sleep_requested = NO_SLEEP;
	// A completed sleep needs a new open edge. Retry an aborted attempt after five seconds.
	lid_controls.closed = 1;
	lid_controls.retry_at = slept ? 0 : millis() + 5000;
}

static void stop(int sig) { (void)sig; running = 0; }

int main(void) {
	const char *run = getenv("SOCKET_RUN");
	snprintf(run_dir, sizeof(run_dir), "%s", run ? run : "/tmp/socket");
	char path[1024];
	snprintf(path, sizeof(path), "%s/hardware.lock", run_dir);
	int lock = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0600);
	if (lock < 0 || flock(lock, LOCK_EX | LOCK_NB) < 0) { perror("socket-hardware: session lock"); return 1; }
	pid_t parent = getppid();
	prctl(PR_SET_PDEATHSIG, SIGTERM);
	if (getppid() != parent) return 1;
	signal(SIGTERM, stop);
	signal(SIGINT, stop);
	int result = 1;
	if (open_inputs() < 0) goto cleanup;
	find_hall();
	glob_t paths = {0};
	int current = -1;
	if (!glob("/sys/class/backlight/*/brightness", 0, NULL, &paths)) {
		snprintf(backlight, sizeof(backlight), "%s", paths.gl_pathv[0]);
		snprintf(path, sizeof(path), "%.*smax_brightness", (int)(strlen(backlight) - strlen("brightness")), backlight);
		int max = number(path);
		if (max > 0) max_brightness = max;
		current = number(backlight);
	} else {
		int fd = open("/dev/disp", O_RDWR | O_CLOEXEC);
		unsigned long args[4] = {0};
		if (fd >= 0) { current = ioctl(fd, 0x103, args); close(fd); }
	}
	globfree(&paths);
	const char *settings = getenv("SOCKET_SETTINGS");
	if (settings) snprintf(settings_path, sizeof(settings_path), "%s", settings);
	if (!load_settings()) {
		if (set_backlight(backlight_value(brightness_step)))
			fprintf(stderr, "socket-hardware: cannot restore brightness\n");
	} else if (current >= 0 && current <= max_brightness) {
		int distance = max_brightness;
		for (int step = 1; step <= 10; step++) {
			int d = abs(backlight_value(step) - current);
			if (d < distance) { brightness_step = step; distance = d; }
		}
	}
	// Wait for the virtual evdev node before the frontend scans input devices.
	char sysname[128] = {0};
	if (ioctl(virtual_pad, UI_GET_SYSNAME(sizeof(sysname)), sysname) < 0) {
		perror("socket-hardware: virtual gamepad sysname");
		goto cleanup;
	}
	snprintf(path, sizeof(path), "/sys/devices/virtual/input/%s/event*", sysname);
	int ready = 0;
	for (int retry = 0; retry < 100 && running; retry++) {
		if (!glob(path, 0, NULL, &paths)) ready = 1;
		globfree(&paths);
		if (ready) break;
		usleep(10000);
	}
	if (!ready) { fprintf(stderr, "socket-hardware: virtual gamepad did not appear\n"); goto cleanup; }
	if (publish_controls(volume_level, 0)) goto cleanup;
	snprintf(path, sizeof(path), "%s/hardware.ready", run_dir);
	FILE *f = fopen(path, "w");
	if (!f) { perror("socket-hardware: ready file"); goto cleanup; }
	fputs("ready\n", f);
	fclose(f);
	result = 0;
	while (running) {
		if (poll(inputs, input_count, 20) < 0 && errno != EINTR) { perror("socket-hardware: poll"); result = 1; break; }
		for (int i = 0; i < input_count && running; i++) {
			if (inputs[i].revents & (POLLERR | POLLHUP | POLLNVAL)) { result = 1; running = 0; break; }
			struct input_event ev;
			while (running && read(inputs[i].fd, &ev, sizeof(ev)) == sizeof(ev)) {
				controls_stream_event(&controls, &streams[i], ev.type, ev.code, ev.value, millis(), action);
			}
		}
		forward(EV_SYN, SYN_REPORT, 0);
		check_lid();
		controls_tick(&controls, millis(), action);
		if (settings_due && millis() >= settings_due) save_settings();
		if (sleep_requested && running) suspend_device();
	}
	if (settings_due) save_settings();
cleanup:
	if (stopped_app && !shutdown_at) kill(stopped_app, SIGCONT);
	snprintf(path, sizeof(path), "%s/hardware.ready", run_dir);
	unlink(path);
	snprintf(path, sizeof(path), "%s/controls", run_dir);
	unlink(path);
	if (virtual_pad >= 0) { ioctl(virtual_pad, UI_DEV_DESTROY); close(virtual_pad); }
	for (int i = 0; i < input_count; i++) close(inputs[i].fd);
	close(lock);
	return result;
}

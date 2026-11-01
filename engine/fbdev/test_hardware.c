// Run in the ARM64 build container. Include the full helper and replace kernel devices.
#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <glob.h>
#include <linux/uinput.h>
#include <limits.h>
#include <math.h>
#include <poll.h>
#include <signal.h>
#include <sound/asound.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static int device_glob(const char *, int, int (*)(const char *, int), glob_t *);
static int device_open(const char *, int, ...);
static FILE *device_fopen(const char *, const char *);
static int device_ioctl(int, unsigned long, ...);
static int device_poll(struct pollfd *, nfds_t, int);
static int device_clock(clockid_t, struct timespec *);
static uint64_t now_ms, sync_delay_ms, boot_extra_ms;
static void device_sync(void) { now_ms += sync_delay_ms; }
#define glob device_glob
#define open device_open
#define fopen device_fopen
#define ioctl device_ioctl
#define poll device_poll
#define clock_gettime device_clock
#define sync device_sync
#define main hardware_main
#include "hardware.c"
#undef glob
#undef open
#undef fopen
#undef ioctl
#undef poll
#undef clock_gettime
#undef sync
#undef main

static int mixer_fd, event_write, app_pid, wake_mode, polls, writes, fail_write, fail_read, bad_info;
static long mixer_values[2] = { 40, 24 };
static int mixer_opens;
static int deny_poll_write;
static int request_opens;
static int game_fixture, game_off_requests;
static int hall_value = -1, lid_read_error, lid_queries, committed_polls;
static char marker_path[1024];

static char hall_fixture[1024], hall_pattern[1024];
static int device_glob(const char *pattern, int flags, int (*error)(const char *, int), glob_t *paths) {
	return glob(!strcmp(pattern, "/sys/class/power_supply/*/hallkey") ? hall_pattern : pattern, flags, error, paths);
}

static FILE *device_fopen(const char *path, const char *mode) {
	if (strstr(path, "/poweroff.request.tmp") && !strcmp(mode, "w")) game_off_requests++;
	if (strcmp(path, hall_fixture)) return fopen(path, mode);
	if (hall_value < 0) { errno = ENOENT; return NULL; }
	FILE *f = tmpfile();
	assert(f);
	assert(fprintf(f, "%d\n", hall_value) > 0);
	rewind(f);
	return f;
}

static int device_open(const char *path, int flags, ...) {
	if ((flags & O_WRONLY) && strstr(path, "/poweroff.request")) {
		request_opens++;
		if ((wake_mode == 9 || wake_mode == 10) && request_opens == 1) { errno = EACCES; return -1; }
	}
	if (deny_poll_write && (flags & O_WRONLY) && strstr(path, "/poll")) { errno = EACCES; return -1; }
	if (backlight[0] && !strcmp(path, backlight) && (flags & O_WRONLY)) flags |= O_TRUNC;
	if (!strcmp(path, "/dev/snd/controlC0")) {
		assert(flags == (O_RDWR | O_CLOEXEC));
		mixer_opens++;
		mixer_fd = open("/dev/null", flags);
		return mixer_fd;
	}
	if (flags & O_CREAT) {
		va_list args;
		va_start(args, flags);
		int mode = va_arg(args, int);
		va_end(args);
		return open(path, flags, mode);
	}
	return open(path, flags);
}

static void check_id(const struct snd_ctl_elem_id *id) {
	assert(id->iface == SNDRV_CTL_ELEM_IFACE_MIXER && !id->index && !id->device && !id->subdevice);
	assert(!strcmp((const char *)id->name, "digital volume"));
}

static int device_ioctl(int fd, unsigned long request, ...) {
	va_list args;
	va_start(args, request);
	void *arg = va_arg(args, void *);
	va_end(args);
	if (request == EVIOCGSW(sizeof(unsigned long))) {
		lid_queries++;
		if (lid_read_error) { errno = EIO; return -1; }
		int opened = (wake_mode == 0 && polls) || ((wake_mode == 7 || wake_mode == 10 || wake_mode == 12 || wake_mode == 13) && polls >= 2);
		*(unsigned long *)arg = opened ? 0 : 1UL << SW_LID;
		return 0;
	}
	assert(fd == mixer_fd);
	if (request == SNDRV_CTL_IOCTL_ELEM_INFO) {
		struct snd_ctl_elem_info *info = arg;
		check_id(&info->id);
		info->type = SNDRV_CTL_ELEM_TYPE_INTEGER;
		info->access = SNDRV_CTL_ELEM_ACCESS_READWRITE;
		info->count = 2;
		info->value.integer.min = 0;
		info->value.integer.max = 63;
		info->value.integer.step = 1;
		if (bad_info == 1) info->type = SNDRV_CTL_ELEM_TYPE_BOOLEAN;
		if (bad_info == 2) info->access = SNDRV_CTL_ELEM_ACCESS_READ;
		if (bad_info == 3) info->access |= SNDRV_CTL_ELEM_ACCESS_INACTIVE;
		if (bad_info == 4) info->count = 129;
		if (bad_info == 5) info->count = 0;
		if (bad_info == 6) info->value.integer.min = -1;
		if (bad_info == 7) info->value.integer.max = 0;
		if (bad_info == 8) info->value.integer.max = LONG_MAX;
		if (bad_info == 9) info->id.index = 1;
		return 0;
	}
	struct snd_ctl_elem_value *value = arg;
	check_id(&value->id);
	if (request == SNDRV_CTL_IOCTL_ELEM_READ) {
		if (fail_read) { errno = EIO; return -1; }
		memcpy(value->value.integer.value, mixer_values, sizeof(mixer_values));
		if (wake_mode == 4) {
			int status;
			assert(waitpid(app_pid, &status, WUNTRACED) == app_pid && WIFSTOPPED(status));
			raise(SIGTERM);
		}
		return 0;
	}
	assert(request == SNDRV_CTL_IOCTL_ELEM_WRITE);
	writes++;
	if (wake_mode == 5 && writes == 1) {
		int status;
		assert(waitpid(app_pid, &status, WUNTRACED) == app_pid && WIFSTOPPED(status));
		raise(SIGTERM);
	}
	if (fail_write == writes) { errno = EPERM; return -1; }
	memcpy(mixer_values, value->value.integer.value, sizeof(mixer_values));
	return 0;
}

static int device_clock(clockid_t id, struct timespec *t) {
	assert(id == CLOCK_MONOTONIC || id == CLOCK_BOOTTIME);
	uint64_t value = now_ms + (id == CLOCK_BOOTTIME ? boot_extra_ms : 0);
	t->tv_sec = value / 1000;
	t->tv_nsec = (value % 1000) * 1000000;
	return 0;
}

static int device_poll(struct pollfd *fds, nfds_t count, int timeout) {
	assert(count == 1 && timeout == 100);
	assert(number(backlight) == 0);
	assert(stopped_app == app_pid || game_shutdown_pending || shutdown_at);
	assert(mixer_values[0] == (fail_read || bad_info ? 40 : 0));
	if (!polls) {
		int status;
		assert(waitpid(app_pid, &status, WUNTRACED) == app_pid && WIFSTOPPED(status));
	}
	polls++;
	// A started shutdown stays dark and muted until init stops the helper.
	if (shutdown_at && wake_mode != 17) {
		struct input_event event = { .type = EV_KEY, .code = KEY_POWER, .value = 1 };
		assert(write(event_write, &event, sizeof(event)) == sizeof(event));
		if (++committed_polls == 2) stop(SIGTERM);
		fds[0].revents = POLLIN;
		return 1;
	}
	if (wake_mode >= 15) {
		if (wake_mode == 15 && (polls == 2 || polls == 4)) {
			int status;
			assert(waitpid(app_pid, &status, WUNTRACED) == app_pid && WIFSTOPPED(status));
		}
		if (wake_mode == 16) {
			now_ms += polls == 1 ? 180000 : 100;
			assert(polls <= 2);
			return 0;
		}
		if (wake_mode == 17) {
			// An acknowledged save whose game never exits: the watchdog powers off.
			const int advance[] = {180000, 59999, 1, 0};
			assert(polls <= 4 && running);
			// The watchdog acts only 60 seconds after the acknowledged save.
			assert((access(marker_path, F_OK) == 0) == (polls == 4));
			assert(game_off_requests == (polls == 1 ? 0 : 1));
			if (polls > 1) assert(shutdown_at);
			if (polls == 4) stop(SIGTERM);
			now_ms += advance[polls - 1];
			return 0;
		} else {
			const int advance[] = {180000, 4999, 1, 1};
			assert(polls <= 4);
			now_ms += advance[polls - 1];
			assert(game_off_requests == (polls == 1 ? 0 : polls < 4 ? 1 : 2));
			if (polls < 4) return 0;
		}
		struct input_event event = { .type = EV_KEY, .code = KEY_POWER, .value = 1 };
		assert(write(event_write, &event, sizeof(event)) == sizeof(event));
		fds[0].revents = POLLIN;
		return 1;
	}
	if (wake_mode == 13 && polls == 2) boot_extra_ms += 60000;
	if (wake_mode == 3) { stop(SIGTERM); return 0; }
	if (wake_mode >= 6) {
		if (wake_mode >= 11) now_ms += polls == 1 ? (wake_mode == 12 ? 29999 : wake_mode == 14 ? 178999 : 179999) : 1;
		else if (wake_mode == 9) now_ms += polls == 1 ? 180000 : polls == 2 ? 4999 : 1;
		else if (wake_mode == 10) now_ms += polls == 1 ? 180000 : 100;
		else now_ms += polls == 1 ? 179999 : 1;
		assert(!request_opens);
		assert(polls <= (wake_mode == 9 ? 3 : 2));
		if (wake_mode != 8) return 0;
	}
	if (wake_mode) {
		struct input_event event = { .type = EV_KEY, .code = KEY_POWER, .value = polls == 1 };
		assert(write(event_write, &event, sizeof(event)) == sizeof(event));
		if (polls == 2 && wake_mode < 6) now_ms += wake_mode == 2 ? 1100 : 100;
	}
	fds[0].revents = POLLIN;
	assert(polls <= 2);
	return 1;
}

static void sleep_case(int mode, int fail_at, int read_error, int invalid) {
	wake_mode = mode;
	fail_write = fail_at;
	fail_read = read_error;
	bad_info = invalid;
	writes = polls = request_opens = game_off_requests = 0;
	game_shutdown_pending = shutdown_at = 0;
	committed_polls = 0;
	mixer_values[0] = 40;
	mixer_values[1] = 24;
	assert(!write_text(backlight, "147"));
	now_ms = 100;
	boot_extra_ms = 0;
	sync_delay_ms = mode == 14 ? 1000 : 0;
	running = 1;
	hall_closed = 1;
	app_pid = fork();
	assert(app_pid >= 0);
	if (!app_pid) {
		if (!game_fixture) { for (;;) pause(); }
		char path[1024], token[64], previous_off[64] = "";
		int off_count = 0;
		for (;;) {
			const char *kinds[] = { "sleep", "wake", "poweroff" };
			for (unsigned i = 0; i < 3; i++) {
				snprintf(path, sizeof(path), "%s/%s.request", run_dir, kinds[i]);
				FILE *request = fopen(path, "r");
				if (!request) continue;
				assert(fgets(token, sizeof(token), request));
				fclose(request);
				token[strcspn(token, "\n")] = 0;
				if (i == 2 && strcmp(previous_off, token)) {
					snprintf(previous_off, sizeof(previous_off), "%s", token);
					off_count++;
				}
				snprintf(path, sizeof(path), "%s/%s.ack", run_dir, kinds[i]);
				FILE *ack = fopen(path, "w");
				assert(ack && fprintf(ack, "%s %s\n", token, (game_fixture == 2 && i == 0) || (i == 2 && (mode == 15 || (mode == 17 && off_count > 1))) ? "error" : "ok") > 0 && !fclose(ack));
				if (i == 2 && mode == 16) {
					snprintf(path, sizeof(path), "%s/game.active", run_dir);
					assert(!unlink(path));
					_exit(0);
				}
			}
			usleep(1000);
		}
	}
	char path[1024];
	snprintf(path, sizeof(path), "%s/app.pid", run_dir);
	FILE *f = fopen(path, "w");
	assert(f);
	fprintf(f, "%d\n", app_pid);
	fclose(f);
	if (game_fixture) {
		snprintf(path, sizeof(path), "%s/game.active", run_dir);
		f = fopen(path, "w");
		assert(f && fprintf(f, "%d\n", app_pid) > 0 && !fclose(f));
	}
	sleep_requested = mode == 0 || mode >= 11 ? LID_SLEEP : POWER_SLEEP;
	lid_controls = (struct LidControls){ .closed = 2 };
	suspend_device();
	int idle_off = mode == 6 || mode == 9 || mode == 10 || mode == 11 || mode == 14;
	int committed = idle_off || mode == 16 || mode == 17;
	// A started shutdown never relights the screen. Wake input does not cancel it.
	assert((mode == 4 || mode == 5 ? !polls : polls > 0) && !stopped_app && sleep_requested == NO_SLEEP);
	assert(number(backlight) == (committed ? 0 : 147));
	assert(committed ? !running && shutdown_at && committed_polls == (mode == 17 ? 0 : 2) : !shutdown_at);
	// Idle sleep powers off at once with the frontend still stopped, as Slot does.
	assert((access(marker_path, F_OK) == 0) == (idle_off || mode == 17));
	if (idle_off) {
		int stopped;
		assert(waitpid(app_pid, &stopped, WCONTINUED | WNOHANG) == 0);
	}
	if (committed) {
		running = 1;
		shutdown_at = 0;
		unlink(marker_path);
		assert(!write_text(backlight, "147"));
	}
	snprintf(path, sizeof(path), "%s/poweroff.request", run_dir);
	// The acknowledged request stays, so play_game.sh keeps the resume record.
	assert((access(path, F_OK) == 0) == (mode == 16 || mode == 17));
	assert(lid_controls.retry_at == 0);
	// A closed lid cannot stop the app again during its save or wake cooldown.
	hall_value = 0;
	check_lid();
	assert(sleep_requested == NO_SLEEP);
	now_ms += 180000;
	check_lid();
	assert(sleep_requested == NO_SLEEP);
	assert(!request_opens);
	if (mode == 16 || mode == 17) assert(!unlink(path));
	hall_value = 1;
	check_lid();
	hall_value = 0;
	check_lid();
	assert(sleep_requested == LID_SLEEP);
	sleep_requested = NO_SLEEP;
	hall_value = -1;
	// One transient EPERM, as in the device log, is retried for mute and restore.
	assert(writes == ((read_error || invalid) ? 0 : fail_at ? 3 : 2));
	assert(mixer_values[0] == 40 && mixer_values[1] == 24);
	int status;
	if (mode == 16) assert(waitpid(app_pid, &status, 0) == app_pid && WIFEXITED(status));
	else if (idle_off) {
		assert(!kill(app_pid, SIGKILL));
		assert(waitpid(app_pid, &status, 0) == app_pid);
	} else {
		assert(waitpid(app_pid, &status, WCONTINUED | WNOHANG) == app_pid && WIFCONTINUED(status));
		assert(!kill(app_pid, SIGKILL));
		assert(waitpid(app_pid, &status, 0) == app_pid);
	}
	if (game_fixture) {
		const char *files[] = { "game.active", "sleep.ack", "wake.ack", "wake.request", "poweroff.ack" };
		for (unsigned i = 0; i < 5; i++) {
			snprintf(path, sizeof(path), "%s/%s", run_dir, files[i]);
			unlink(path);
		}
	}
}

static void protocol_case(const char *kind, const char *reply, int resume) {
	char request[1024], ack[1024];
	snprintf(request, sizeof(request), "%s/%s.request", run_dir, kind);
	snprintf(ack, sizeof(ack), "%s/%s.ack", run_dir, kind);
	pid_t child = fork();
	assert(child >= 0);
	if (!child) {
		if (resume) raise(SIGSTOP);
		char token[64];
		for (;;) {
			FILE *f = fopen(request, "r");
			if (f) {
				assert(fgets(token, sizeof(token), f));
				fclose(f);
				token[strcspn(token, "\n")] = 0;
				f = fopen(ack, "w");
				assert(f && fprintf(f, "%s %s\n", token, reply) > 0 && !fclose(f));
				_exit(0);
			}
			usleep(1000);
		}
	}
	int status;
	if (resume) assert(waitpid(child, &status, WUNTRACED) == child && WIFSTOPPED(status));
	assert(game_request(kind, resume ? child : 0) == (!strcmp(reply, "ok") ? 0 : -1));
	assert(waitpid(child, &status, 0) == child && WIFEXITED(status) && !WEXITSTATUS(status));
	assert((access(request, F_OK) == 0) == (!strcmp(kind, "poweroff") && !strcmp(reply, "ok")));
	unlink(request);
	unlink(ack);
}

static void snapshot(unsigned sequence, int volume, int brightness, int kind) {
	char path[1024], extra;
	snprintf(path, sizeof(path), "%s/controls", run_dir);
	FILE *f = fopen(path, "r");
	assert(f);
	unsigned version, actual_sequence;
	int actual_volume, actual_brightness, actual_temperature, actual_kind;
	assert(fscanf(f, "%u %u %d %d %d %d %c", &version, &actual_sequence,
		&actual_volume, &actual_brightness, &actual_temperature, &actual_kind, &extra) == 6);
	assert(version == 2 && actual_sequence == sequence && actual_volume == volume);
	assert(actual_brightness == brightness && actual_temperature == temperature_step && actual_kind == kind);
	fclose(f);
}

int main(void) {
	// Boottime reveals kernel suspend without changing monotonic input deadlines.
	now_ms = 100;
	boot_extra_ms = 60000;
	assert(millis() == 100 && boot_millis() == 60100);
	boot_extra_ms = 0;
	now_ms = 0;
	signal(SIGTERM, stop);
	char temp[] = "/tmp/socket-hardware-test-XXXXXX";
	assert(mkdtemp(temp));
	char poll_path[1024];
	snprintf(poll_path, sizeof(poll_path), "%s/poll", temp);
	quicken_poll(poll_path);
	assert(access(poll_path, F_OK) < 0);
	const char *intervals[] = { "20\n", "10\n", "5\n", "invalid\n" };
	const int expected[] = { 10, 10, 5, -1 };
	for (unsigned i = 0; i < 4; i++) {
		FILE *poll_file = fopen(poll_path, "w");
		assert(poll_file);
		fputs(intervals[i], poll_file);
		assert(!fclose(poll_file));
		quicken_poll(poll_path);
		assert(number(poll_path) == expected[i]);
	}
	FILE *poll_file = fopen(poll_path, "w");
	assert(poll_file);
	fputs("20\n", poll_file);
	assert(!fclose(poll_file));
	deny_poll_write = 1;
	quicken_poll(poll_path);
	assert(number(poll_path) == 20);
	deny_poll_write = 0;
	assert(!unlink(poll_path));
	snprintf(run_dir, sizeof(run_dir), "%s", temp);
	snprintf(backlight, sizeof(backlight), "%s/brightness", temp);
	int fd = open(backlight, O_CREAT | O_WRONLY, 0600);
	assert(fd >= 0);
	close(fd);
	virtual_pad = open("/dev/null", O_WRONLY);
	assert(virtual_pad >= 0);
	int pipefd[2];
	assert(!pipe2(pipefd, O_NONBLOCK | O_CLOEXEC));
	inputs[0] = (struct pollfd){ .fd = pipefd[0], .events = POLLIN };
	event_write = pipefd[1];
	input_count = 1;
	lid_input = 0;
	// Discover a hall sensor under an alternate supply name.
	snprintf(hall_fixture, sizeof(hall_fixture), "%s/hallkey-a", temp);
	snprintf(hall_pattern, sizeof(hall_pattern), "%s/hallkey-*", temp);
	FILE *hall_file = fopen(hall_fixture, "w");
	assert(hall_file && !fclose(hall_file));
	hall_value = 2;
	find_hall();
	assert(!strcmp(hall_path, hall_fixture));
	// Prefer a later valid node to the retained invalid first node.
	char valid_hall[1024];
	snprintf(valid_hall, sizeof(valid_hall), "%s/hallkey-b", temp);
	hall_file = fopen(valid_hall, "w");
	assert(hall_file && fputs("1\n", hall_file) >= 0 && !fclose(hall_file));
	find_hall();
	assert(!strcmp(hall_path, valid_hall));
	assert(!unlink(valid_hall));
	find_hall();
	assert(!strcmp(hall_path, hall_fixture));
	assert(!unlink(hall_fixture));
	// The hall sensor uses inverse polarity and takes priority over evdev.
	hall_value = 0;
	assert(read_lid() == 1 && !lid_queries);
	hall_value = 1;
	assert(read_lid() == 0 && !lid_queries);
	hall_value = 2;
	assert(read_lid() == 1 && lid_queries == 1);
	hall_value = -1;
	assert(read_lid() == 1 && lid_queries == 2);
	polls = 1;
	assert(read_lid() == 0 && lid_queries == 3);
	lid_read_error = 1;
	assert(read_lid() == -1);
	lid_read_error = 0;
	lid_input = -1;
	assert(read_lid() == -1);
	lid_input = 0;
	polls = 0;
	// A new close sleeps immediately. POWER takes priority when simultaneous.
	hall_value = 0;
	check_lid();
	assert(sleep_requested == LID_SLEEP);
	sleep_requested = NO_SLEEP;
	check_lid();
	assert(sleep_requested == NO_SLEEP);
	hall_value = 1;
	check_lid();
	hall_value = 0;
	sleep_requested = POWER_SLEEP;
	check_lid();
	assert(sleep_requested == POWER_SLEEP);
	sleep_requested = NO_SLEEP;
	hall_value = -1;

	// Only poweroff remains an external command. Reject unexpected command arguments.
	char path[1024], marker[1024], script[2048];
	snprintf(path, sizeof(path), "%s/poweroff", temp);
	snprintf(marker, sizeof(marker), "%s/off", temp);
	snprintf(marker_path, sizeof(marker_path), "%s", marker);
	FILE *f = fopen(path, "w");
	assert(f);
	snprintf(script, sizeof(script), "#!/bin/sh\n[ \"$#\" = 0 ] || exit 2\n: > '%s'\n", marker);
	fputs(script, f);
	fclose(f);
	assert(!chmod(path, 0700));
	assert(!setenv("PATH", temp, 1));
	const char *missing[] = { "amixer", "sset", "digital volume", "0%", NULL };
	assert(command(missing) == -1);
	assert(command((const char *const[]){ "poweroff", "unexpected", NULL }) == -1);
	assert(access(marker, F_OK) < 0);

	// Control snapshots replace polled button taps and never touch the mixer.
	int volume_pipe[2];
	assert(!pipe2(volume_pipe, O_NONBLOCK | O_CLOEXEC));
	close(virtual_pad);
	virtual_pad = volume_pipe[1];
	int opens_before = mixer_opens;
	assert(!publish_controls(40, 0));
	snapshot(0, 40, 5, 0);
	action(VOLUME, 0, 0, 1);
	snapshot(1, 45, 5, 1);
	action(VOLUME, 0, 0, -1);
	snapshot(2, 40, 5, 1);
	for (int i = 0; i < 10; i++) action(VOLUME, 0, 0, -1);
	snapshot(12, 0, 5, 1);
	for (int i = 0; i < 22; i++) action(VOLUME, 0, 0, 1);
	snapshot(34, 100, 5, 1);
	// A failed write leaves the last complete snapshot and shared level intact.
	char blocked[1024];
	snprintf(blocked, sizeof(blocked), "%s/controls.tmp", temp);
	assert(!mkdir(blocked, 0700));
	action(VOLUME, 0, 0, -1);
	snapshot(34, 100, 5, 1);
	assert(volume_level == 100 && control_sequence == 34);
	assert(!rmdir(blocked));
	// Slot temperature has ten steps, 0 to 9, and clamps at both ends.
	action(TEMPERATURE, 0, 0, 1);
	assert(temperature_step == 1);
	snapshot(35, 100, 5, 3);
	for (int i = 0; i < 12; i++) action(TEMPERATURE, 0, 0, 1);
	assert(temperature_step == 9);
	snapshot(47, 100, 5, 3);
	for (int i = 0; i < 12; i++) action(TEMPERATURE, 0, 0, -1);
	assert(temperature_step == 0);
	snapshot(59, 100, 5, 3);
	control_sequence = 34;
	action(BRIGHTNESS, 0, 0, 1);
	snapshot(35, 100, 6, 2);
	assert(number(backlight) == backlight_value(7));
	for (int i = 0; i < 12; i++) action(BRIGHTNESS, 0, 0, -1);
	snapshot(47, 100, 0, 2);
	assert(number(backlight) == backlight_value(1));
	for (int i = 0; i < 12; i++) action(BRIGHTNESS, 0, 0, 1);
	snapshot(59, 100, 9, 2);
	assert(number(backlight) == backlight_value(10));
	// A rejected backlight write must not report a level that was not applied.
	assert(!unlink(backlight));
	action(BRIGHTNESS, 0, 0, -1);
	snapshot(60, 100, 9, 2);
	fd = open(backlight, O_CREAT | O_WRONLY, 0600);
	assert(fd >= 0); close(fd);
	// Settings are saved after a one-second pause, durably, and validated on load.
	char settings_file[1024];
	snprintf(settings_file, sizeof(settings_file), "%s/controls.cfg", temp);
	snprintf(settings_path, sizeof(settings_path), "%s", settings_file);
	assert(settings_due && settings_due <= now_ms + 1000);
	temperature_step = 4;
	brightness_step = 3;
	assert(!save_settings() && !settings_due);
	FILE *saved = fopen(settings_file, "r");
	char saved_line[64];
	assert(saved && fgets(saved_line, sizeof(saved_line), saved) && !fclose(saved));
	assert(!strcmp(saved_line, "socket-controls-v1 100 3 4\n"));
	volume_level = 40; brightness_step = 6; temperature_step = 0;
	assert(!load_settings() && volume_level == 100 && brightness_step == 3 && temperature_step == 4);
	const char *invalid[] = { "socket-controls-v1 101 3 4\n", "socket-controls-v1 42 3 4\n",
		"socket-controls-v1 40 0 4\n", "socket-controls-v1 40 11 4\n", "socket-controls-v1 40 3 10\n",
		"socket-controls-v1 40 3 4", "socket-controls-v1 40 3 4\nx", "socket-controls-v2 40 3 4\n", "" };
	for (unsigned i = 0; i < sizeof(invalid) / sizeof(*invalid); i++) {
		saved = fopen(settings_file, "w");
		assert(saved && fputs(invalid[i], saved) >= 0 && !fclose(saved));
		assert(load_settings() && volume_level == 100 && brightness_step == 3 && temperature_step == 4);
	}
	assert(!unlink(settings_file));
	assert(load_settings());
	settings_path[0] = 0;
	temperature_step = 0;
	brightness_step = 10;
	struct input_event tap_events[32];
	assert(read(volume_pipe[0], tap_events, sizeof(tap_events)) == -1 && errno == EAGAIN);
	action(FORWARD, EV_KEY, 0x162, 1);
	assert(read(volume_pipe[0], tap_events, sizeof(tap_events)) == -1 && errno == EAGAIN);
	int buttons = 0;
	for (int code = 0; code <= KEY_MAX; code++) buttons += pad_button(code);
	assert(buttons == 11 && !pad_button(0x139) && !pad_button(0x162));
	assert(mixer_opens == opens_before && !writes);
	close(virtual_pad);
	close(volume_pipe[0]);
	virtual_pad = open("/dev/null", O_WRONLY);
	assert(virtual_pad >= 0);

	// Exact token acknowledgements gate save and a real stopped process resumes for wake.
	char pending_path[1024], active_path[1024], pid_path[1024];
	snprintf(pending_path, sizeof(pending_path), "%s/poweroff.request", run_dir);
	snprintf(active_path, sizeof(active_path), "%s/game.active", run_dir);
	snprintf(pid_path, sizeof(pid_path), "%s/app.pid", run_dir);
	const char *pending_files[] = { active_path, pid_path, pending_path };
	for (unsigned i = 0; i < 3; i++) {
		FILE *pending = fopen(pending_files[i], "w");
		assert(pending && fprintf(pending, "%d\n", getpid()) > 0 && !fclose(pending));
	}
	assert(!unlink(active_path) && !unlink(pending_path) && !unlink(pid_path));
	protocol_case("sleep", "ok", 0);
	protocol_case("sleep", "error", 0);
	protocol_case("wake", "ok", 1);
	protocol_case("poweroff", "error", 0);
	protocol_case("poweroff", "ok", 0);
	assert(game_request("sleep", 0) == -1);
	char request_path[1024];
	snprintf(request_path, sizeof(request_path), "%s/sleep.request", run_dir);
	assert(access(request_path, F_OK) < 0);

	struct snd_ctl_elem_info info;
	struct snd_ctl_elem_value value;
	mixer_values[0] = 64;
	writes = 0;
	assert(mixer_read(&info, &value) == -1);
	assert(!writes && mixer_values[0] == 64);
	for (int invalid = 1; invalid <= 9; invalid++) {
		bad_info = invalid;
		assert(mixer_read(&info, &value) == -1);
		assert(!writes);
	}
	bad_info = 0;
	// A missing app PID retries after five seconds with the lid closed.
	lid_controls = (struct LidControls){0};
	hall_value = 0;
	now_ms = 100;
	check_lid();
	assert(sleep_requested == LID_SLEEP);
	suspend_device();
	assert(!stopped_app && sleep_requested == NO_SLEEP && lid_controls.retry_at == 5100);
	now_ms = 5099;
	check_lid();
	assert(sleep_requested == NO_SLEEP);
	now_ms = 5100;
	check_lid();
	assert(sleep_requested == LID_SLEEP);
	hall_value = 1;
	check_lid();
	assert(!lid_controls.closed && !lid_controls.retry_at);
	hall_value = -1;
	game_fixture = 1;
	sleep_case(1, 0, 0, 0);
	sleep_case(3, 0, 0, 0);
	game_fixture = 2;
	sleep_case(1, 0, 0, 0);
	game_fixture = 1;
	// Failed timeout saves and a stalled exit remain dark, with bounded retries.
	for (int mode = 15; mode <= 17; mode++) sleep_case(mode, 0, 0, 0);
	game_fixture = 0;
	sleep_case(0, 0, 0, 0);
	sleep_case(1, 0, 0, 0);
	sleep_case(1, 1, 0, 0);
	sleep_case(1, 2, 0, 0);
	sleep_case(1, 0, 1, 0);
	sleep_case(1, 0, 0, 2);
	sleep_case(3, 0, 0, 0);
	sleep_case(3, 2, 0, 0);
	sleep_case(4, 0, 0, 0);
	sleep_case(5, 0, 0, 0);
	sleep_case(5, 2, 0, 0);
	// Timed shutdown resumes the app with a request. Wake wins at the deadline.
	for (int mode = 6; mode <= 10; mode++) {
		sleep_case(mode, 0, 0, 0);
		assert(access(marker, F_OK) < 0);
	}
	// Lid timeout is 180 seconds asleep. Reopening at the deadline wins.
	for (int mode = 11; mode <= 14; mode++) {
		sleep_case(mode, 0, 0, 0);
		assert(access(marker, F_OK) < 0);
	}
	sleep_case(2, 0, 0, 0);
	assert(access(marker, F_OK) < 0 && running && mixer_opens > 10);
	action(SHUTDOWN, 0, 0, 0);
	// The helper keeps running until init stops it, so it cannot kill apps early.
	assert(!access(marker, F_OK) && running && shutdown_at);
	close(virtual_pad);
	close(pipefd[0]); close(pipefd[1]);
	unlink(marker); unlink(path);
	snprintf(path, sizeof(path), "%s/app.pid", temp);
	unlink(path); unlink(backlight);
	snprintf(path, sizeof(path), "%s/controls", temp);
	unlink(path);
	assert(!rmdir(temp));
	puts("hardware integration tests passed");
}

#include "hardware_input.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

struct Seen { enum ControlAction action; unsigned short type, code; int value; };
static struct Seen seen[128];
static int count;
static void sink(enum ControlAction a, unsigned short t, unsigned short c, int v) {
	assert(count < 128);
	seen[count++] = (struct Seen){a, t, c, v};
}
static void event(struct Controls *s, unsigned short t, unsigned short c, int v, uint64_t now) {
	controls_event(s, t, c, v, now, sink);
}
static int actions(enum ControlAction action) {
	int n = 0;
	for (int i = 0; i < count; i++) n += seen[i].action == action;
	return n;
}
static void reset(struct Controls *s) { memset(s, 0, sizeof(*s)); count = 0; }

int main(void) {
	struct Controls s = {0};
	// Short taps remain down for several game frames, then release.
	event(&s, EV_KEY, 0x136, 1, 100);
	event(&s, EV_KEY, 0x136, 0, 130);
	assert(count == 1 && seen[0].code == 0x136 && seen[0].value == 1);
	controls_tick(&s, 189, sink);
	assert(count == 1);
	controls_tick(&s, 190, sink);
	assert(count == 2 && seen[1].value == 0);

	// Ordinary holds are visible before release and combine with game keys.
	reset(&s);
	event(&s, EV_KEY, 0x136, 1, 100);
	controls_tick(&s, 350, sink);
	assert(count == 1 && seen[0].value == 1);
	event(&s, EV_KEY, 0x130, 1, 400);
	assert(count == 2 && seen[1].code == 0x130);
	event(&s, EV_KEY, 0x136, 0, 500);
	assert(count == 3 && seen[2].code == 0x136 && seen[2].value == 0);

	// Chords consume both SELECT and vertical movement, including release order.
	reset(&s);
	event(&s, EV_KEY, 0x136, 1, 100);
	event(&s, EV_ABS, ABS_HAT0Y, -1, 150);
	assert(actions(BRIGHTNESS) == 1);
	controls_tick(&s, 549, sink);
	assert(actions(BRIGHTNESS) == 1);
	controls_tick(&s, 550, sink);
	assert(actions(BRIGHTNESS) == 1);
	controls_tick(&s, 5000, sink);
	assert(actions(BRIGHTNESS) == 1);
	event(&s, EV_ABS, ABS_HAT0Y, 0, 6000);
	event(&s, EV_ABS, ABS_HAT0Y, -1, 6010);
	assert(actions(BRIGHTNESS) == 2);
	event(&s, EV_ABS, ABS_HAT0Y, 0, 6020);
	event(&s, EV_KEY, 0x136, 0, 6050);
	for (int i = 0; i < count; i++) if (seen[i].action == FORWARD) assert(seen[i].type == EV_ABS && seen[i].value == 0);
	reset(&s);
	event(&s, EV_KEY, 0x136, 1, 100);
	event(&s, EV_ABS, ABS_HAT0Y, 1, 150);
	event(&s, EV_KEY, 0x136, 0, 200);
	event(&s, EV_ABS, ABS_HAT0Y, 0, 250);
	assert(actions(FORWARD) == 1);
	event(&s, EV_ABS, ABS_HAT0Y, -1, 300);
	assert(seen[count - 1].action == FORWARD && seen[count - 1].value == -1);

	// A direction already held is neutralized when SELECT starts the chord.
	reset(&s);
	event(&s, EV_ABS, ABS_HAT0Y, -1, 100);
	event(&s, EV_KEY, 0x136, 1, 150);
	assert(count == 3 && seen[1].value == 0 && seen[2].action == BRIGHTNESS);
	event(&s, EV_KEY, 0x136, 0, 200);
	assert(count == 3);

	// SELECT+Left/Right changes temperature as Slot does: Right raises, Left lowers.
	reset(&s);
	event(&s, EV_KEY, 0x136, 1, 100);
	event(&s, EV_ABS, ABS_HAT0X, 1, 150);
	assert(count == 2 && seen[1].action == TEMPERATURE && seen[1].value == 1);
	controls_tick(&s, 5000, sink);
	assert(actions(TEMPERATURE) == 1 && actions(FORWARD) == 1);
	event(&s, EV_ABS, ABS_HAT0X, 0, 6000);
	event(&s, EV_ABS, ABS_HAT0X, -1, 6010);
	assert(actions(TEMPERATURE) == 2 && seen[count - 1].value == -1);
	event(&s, EV_ABS, ABS_HAT0X, 0, 6020);
	event(&s, EV_KEY, 0x136, 0, 6050);
	for (int i = 0; i < count; i++) if (seen[i].action == FORWARD) assert(seen[i].type == EV_ABS && seen[i].value == 0);
	assert(!actions(BRIGHTNESS));
	// A held SELECT that was already sent is released before the chord.
	reset(&s);
	event(&s, EV_KEY, 0x136, 1, 100);
	controls_tick(&s, 350, sink);
	event(&s, EV_ABS, ABS_HAT0X, -1, 400);
	assert(count == 4 && seen[1].code == 0x136 && seen[1].value == 0 && seen[3].action == TEMPERATURE);
	// A horizontal direction already held is neutralized when SELECT starts the chord.
	reset(&s);
	event(&s, EV_ABS, ABS_HAT0X, 1, 100);
	event(&s, EV_KEY, 0x136, 1, 150);
	assert(count == 3 && seen[1].code == ABS_HAT0X && seen[1].value == 0 && seen[2].action == TEMPERATURE);
	event(&s, EV_KEY, 0x136, 0, 200);
	event(&s, EV_ABS, ABS_HAT0X, 0, 250);
	assert(count == 3);
	event(&s, EV_ABS, ABS_HAT0X, 1, 300);
	assert(seen[count - 1].action == FORWARD && seen[count - 1].value == 1);

	// Kernel repeats do not restart the power timer or produce duplicate actions.
	reset(&s);
	event(&s, EV_KEY, KEY_POWER, 1, 100);
	event(&s, EV_KEY, KEY_POWER, 2, 150);
	controls_tick(&s, 1099, sink);
	assert(!count);
	controls_tick(&s, 1100, sink);
	assert(actions(SHUTDOWN) == 1);
	event(&s, EV_KEY, KEY_POWER, 0, 1200);
	assert(count == 1);
	reset(&s);
	event(&s, EV_KEY, KEY_POWER, 1, 100);
	event(&s, EV_KEY, KEY_POWER, 0, 150);
	assert(actions(SLEEP) == 1);
	reset(&s);
	event(&s, EV_KEY, KEY_POWER, 1, 100);
	event(&s, EV_KEY, KEY_POWER, 0, 1200);
	assert(actions(SHUTDOWN) == 1 && !actions(SLEEP));

	reset(&s);
	event(&s, EV_KEY, KEY_VOLUMEUP, 1, 100);
	event(&s, EV_KEY, KEY_VOLUMEUP, 2, 200);
	assert(actions(VOLUME) == 1);
	controls_tick(&s, 499, sink);
	assert(actions(VOLUME) == 1);
	controls_tick(&s, 500, sink);
	assert(actions(VOLUME) == 2);
	controls_tick(&s, 619, sink);
	assert(actions(VOLUME) == 2);
	controls_tick(&s, 620, sink);
	assert(actions(VOLUME) == 3);
	event(&s, EV_KEY, KEY_VOLUMEUP, 0, 630);
	controls_tick(&s, 1000, sink);
	assert(actions(VOLUME) == 3);
	event(&s, EV_SW, SW_LID, 0, 1100);
	assert(!actions(SLEEP));
	event(&s, EV_SW, SW_LID, 1, 1200);
	assert(!actions(SLEEP));
	// Close sleeps immediately. Repeated closed and unknown levels do not re-arm.
	struct LidControls lid = {0};
	assert(controls_lid_tick(&lid, 1, 0));
	assert(!controls_lid_tick(&lid, 1, 180000));
	assert(!controls_lid_tick(&lid, -1, 180001));
	assert(!controls_lid_tick(&lid, 1, 180002));
	assert(!controls_lid_tick(&lid, 0, 180003));
	assert(controls_lid_tick(&lid, 1, 180004));
	lid.retry_at = 185004;
	assert(!controls_lid_tick(&lid, 1, 185003));
	assert(controls_lid_tick(&lid, 1, 185004));
	// A wake press consumes a short release. A continued hold still shuts down.
	reset(&s);
	s.power = 2;
	s.power_at = 100;
	event(&s, EV_KEY, KEY_POWER, 2, 100);
	controls_tick(&s, 1099, sink);
	event(&s, EV_KEY, KEY_POWER, 0, 1099);
	assert(!count && !s.power);
	event(&s, EV_KEY, KEY_POWER, 1, 5200);
	event(&s, EV_KEY, KEY_POWER, 0, 5300);
	assert(actions(SLEEP) == 1);
	reset(&s);
	s.power = 2;
	s.power_at = 100;
	controls_tick(&s, 1100, sink);
	assert(actions(SHUTDOWN) == 1);
	event(&s, EV_KEY, KEY_POWER, 0, 1200);
	assert(count == 1);
	reset(&s);
	s.power = 2;
	s.power_at = 100;
	event(&s, EV_KEY, KEY_POWER, 0, 1200);
	assert(!count);
	// A release queued during a slow wake handshake is consumed before tick.
	reset(&s);
	s.power = 2;
	s.power_at = 100;
	event(&s, EV_KEY, KEY_POWER, 0, 2000);
	controls_tick(&s, 2000, sink);
	assert(!count);
	// Lost events are invalid through the next report on that device only.
	reset(&s);
	struct ControlStream lost = {0}, other = {0};
	controls_stream_event(&s, &lost, EV_KEY, KEY_POWER, 1, 0, sink);
	controls_stream_event(&s, &lost, EV_SYN, SYN_DROPPED, 0, 10, sink);
	controls_stream_event(&s, &lost, EV_KEY, KEY_POWER, 1, 20, sink);
	controls_stream_event(&s, &lost, EV_SW, SW_LID, 1, 30, sink);
	controls_stream_event(&s, &lost, EV_ABS, ABS_HAT0Y, -1, 40, sink);
	controls_tick(&s, 2000, sink);
	assert(count == 1 && seen[0].action == RESET);
	controls_stream_event(&s, &other, EV_KEY, 0x130, 1, 2001, sink);
	assert(count == 2 && seen[1].code == 0x130);
	controls_stream_event(&s, &lost, EV_SYN, SYN_REPORT, 0, 2002, sink);
	assert(count == 3 && seen[2].action == RESET);
	controls_stream_event(&s, &lost, EV_KEY, KEY_POWER, 0, 2003, sink);
	assert(!actions(SLEEP) && !actions(SHUTDOWN));
	controls_stream_event(&s, &lost, EV_KEY, 0x130, 1, 2010, sink);
	assert(count == 4 && seen[3].code == 0x130);
	// Idle sleep wakes on a lid-open edge or POWER press, including at timeout.
	struct SleepControls wake = { .closed = 0, .sleep_at = 100 };
	assert(controls_sleep_event(&wake, EV_SW, SW_LID, 0, 0) == SLEEP_WAIT);
	assert(controls_sleep_event(&wake, EV_SW, SW_LID, 1, 0) == SLEEP_WAIT);
	assert(controls_sleep_event(&wake, EV_SW, SW_LID, 0, 0) == SLEEP_WAKE);
	assert(controls_sleep_event(&wake, EV_KEY, KEY_POWER, 0, 0) == SLEEP_WAIT);
	assert(controls_sleep_event(&wake, EV_KEY, KEY_POWER, 1, 100) == SLEEP_WAKE);
	assert(controls_sleep_event(&wake, EV_KEY, KEY_POWER, 2, 500) == SLEEP_WAIT);
	assert(controls_sleep_tick(&wake, 1100) == SLEEP_WAIT);
	assert(controls_sleep_event(&wake, EV_KEY, KEY_POWER, 0, 1200) == SLEEP_WAIT);
	assert(controls_sleep_tick(&wake, 180099) == SLEEP_WAIT);
	assert(controls_sleep_tick(&wake, 180100) == SLEEP_TIMEOUT);
	assert(controls_sleep_event(&wake, EV_KEY, KEY_POWER, 1, 180100) == SLEEP_WAKE);
	wake.closed = 1;
	assert(controls_sleep_event(&wake, EV_SW, SW_LID, -1, 0) == SLEEP_WAIT);
	assert(controls_sleep_event(&wake, EV_SW, SW_LID, 0, 180100) == SLEEP_WAKE);
	puts("hardware input checks passed");
}

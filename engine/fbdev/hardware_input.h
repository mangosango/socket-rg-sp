#pragma once

#include <linux/input.h>
#include <stdint.h>

// SELECT is delayed until another game key or release identifies its use.
struct Controls {
	int select, chord, select_sent, vertical, blocked_vertical, horizontal, blocked_horizontal, volume, power;
	uint64_t power_at, repeat_at, select_at, release_at;
};

enum ControlAction { FORWARD, BRIGHTNESS, VOLUME, SLEEP, SHUTDOWN, RESET, TEMPERATURE };
typedef void (*ControlSink)(enum ControlAction, unsigned short, unsigned short, int);

static void controls_tick(struct Controls *s, uint64_t now, ControlSink sink) {
	if (s->release_at && now >= s->release_at) {
		sink(FORWARD, EV_KEY, 0x136, 0);
		s->release_at = 0;
	}
	if (s->select && !s->chord && !s->select_sent && now - s->select_at >= 250) {
		sink(FORWARD, EV_KEY, 0x136, 1);
		s->select_sent = 1;
	}
	if (s->power > 0 && now - s->power_at >= 1000) {
		s->power = 0;
		sink(SHUTDOWN, 0, 0, 0);
	}
	if (s->volume && now >= s->repeat_at) {
		sink(VOLUME, 0, 0, s->volume);
		s->repeat_at = now + 120;
	}
}

static void controls_event(struct Controls *s, unsigned short type, unsigned short code,
		int value, uint64_t now, ControlSink sink) {
	if (type == EV_KEY && code == KEY_POWER) {
		if (s->power == 2) {
			if (!value) s->power = 0;
			return;
		}
		if (value == 1 && !s->power) {
			s->power = 1;
			s->power_at = now;
		} else if (value == 0 && s->power) {
			s->power = 0;
			sink(now - s->power_at >= 1000 ? SHUTDOWN : SLEEP, 0, 0, 0);
		}
		return;
	}
	if (type == EV_SW && code == SW_LID) {
		// The current lid state controls sleep. Queued events can be stale.
		return;
	}
	if (type == EV_KEY && (code == KEY_VOLUMEUP || code == KEY_VOLUMEDOWN)) {
		if (value == 1) {
			s->volume = code == KEY_VOLUMEUP ? 1 : -1;
			sink(VOLUME, 0, 0, s->volume);
			s->repeat_at = now + 400;
		} else if (value == 0 && s->volume == (code == KEY_VOLUMEUP ? 1 : -1)) {
			s->volume = 0;
		}
		return;
	}
	if (type == EV_KEY && code == 0x136) {
		if (value == 1) {
			if (s->release_at) sink(FORWARD, EV_KEY, code, 0);
			s->release_at = 0;
			s->select = 1;
			s->select_at = now;
			s->chord = s->select_sent = 0;
			if (s->vertical) {
				sink(FORWARD, EV_ABS, ABS_HAT0Y, 0);
				s->chord = s->blocked_vertical = 1;
				sink(BRIGHTNESS, 0, 0, -s->vertical);
			}
			// Slot: SELECT+Left lowers and SELECT+Right raises screen temperature.
			if (s->horizontal) {
				sink(FORWARD, EV_ABS, ABS_HAT0X, 0);
				s->chord = s->blocked_horizontal = 1;
				sink(TEMPERATURE, 0, 0, s->horizontal);
			}
		} else if (value == 0 && s->select) {
			if (!s->chord && !s->select_sent) {
				sink(FORWARD, EV_KEY, code, 1);
				// Keep a short tap visible to applications that poll once per frame.
				s->release_at = now + 60;
			} else if (s->select_sent && !s->chord) sink(FORWARD, EV_KEY, code, 0);
			s->select = s->select_sent = 0;
		}
		return;
	}
	if (type == EV_ABS && (code == ABS_HAT0Y || code == ABS_HAT0X)) {
		int vertical = code == ABS_HAT0Y;
		int *held = vertical ? &s->vertical : &s->horizontal;
		int *blocked = vertical ? &s->blocked_vertical : &s->blocked_horizontal;
		int was = *held;
		*held = value;
		if (s->select && value) {
			if (!s->chord) {
				if (s->select_sent) sink(FORWARD, EV_KEY, 0x136, 0);
				sink(FORWARD, EV_ABS, code, 0);
			}
			s->chord = *blocked = 1;
			if (value != was) {
				if (vertical) sink(BRIGHTNESS, 0, 0, -value);
				else sink(TEMPERATURE, 0, 0, value);
			}
			return;
		}
		if (*blocked) {
			if (!value) *blocked = 0;
			return;
		}
	}
	if (s->select && !s->chord && !s->select_sent &&
			((type == EV_KEY && value == 1) || (type == EV_ABS && value))) {
		sink(FORWARD, EV_KEY, 0x136, 1);
		s->select_sent = 1;
	}
	sink(FORWARD, type, code, value);
}

struct ControlStream { int dropping; };

static void controls_stream_event(struct Controls *s, struct ControlStream *stream,
		unsigned short type, unsigned short code, int value, uint64_t now, ControlSink sink) {
	if (type == EV_SYN && code == SYN_DROPPED) {
		stream->dropping = 1;
		*s = (struct Controls){0};
		sink(RESET, 0, 0, 0);
		return;
	}
	if (stream->dropping) {
		if (type == EV_SYN && code == SYN_REPORT) {
			stream->dropping = 0;
			// Start from neutral. Held controls need a fresh press after event loss.
			*s = (struct Controls){0};
			sink(RESET, 0, 0, 0);
		}
		return;
	}
	controls_event(s, type, code, value, now, sink);
}

struct LidControls { int closed; uint64_t retry_at; };

static int controls_lid_tick(struct LidControls *s, int closed, uint64_t now) {
	if (closed == 0) {
		*s = (struct LidControls){0};
		return 0;
	}
	if (closed != 1 || (s->closed && !s->retry_at)) return 0;
	if (s->retry_at && now < s->retry_at) return 0;
	s->closed = 1;
	s->retry_at = 0;
	return 1;
}

struct SleepControls { int closed, power; uint64_t power_at, sleep_at; };
enum SleepAction { SLEEP_WAIT, SLEEP_WAKE, SLEEP_OFF, SLEEP_TIMEOUT };

static enum SleepAction controls_sleep_tick(struct SleepControls *s, uint64_t now) {
	if (now - s->sleep_at >= 180000) return SLEEP_TIMEOUT;
	return SLEEP_WAIT;
}

static enum SleepAction controls_sleep_event(struct SleepControls *s, unsigned short type,
		unsigned short code, int value, uint64_t now) {
	if (type == EV_SYN && code == SYN_DROPPED) s->power = 0;
	if (type == EV_SW && code == SW_LID && (value == 0 || value == 1)) {
		int opened = s->closed == 1 && value == 0;
		s->closed = value;
		return opened ? SLEEP_WAKE : SLEEP_WAIT;
	}
	if (type == EV_KEY && code == KEY_POWER) {
		if (value == 1 && !s->power) {
			s->power = 1;
			s->power_at = now;
			return SLEEP_WAKE;
		}
		if (value == 0) s->power = 0;
	}
	return SLEEP_WAIT;
}

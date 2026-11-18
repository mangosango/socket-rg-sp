/*
 * socket-bluetooth-agent: BlueZ pairing agent and device commands for
 * card/System/socket/bluetooth.sh.
 *
 * Standard input, one command on each line:
 *   scan on | scan off
 *   pair ADDRESS | connect ADDRESS      select ADDRESS as the target
 *   trust ADDRESS | disconnect ADDRESS | remove ADDRESS
 *   answer TEXT                         yes, no or the digits of a code
 * Standard output, one event on each line:
 *   ready
 *   result COMMAND ok | result COMMAND error NAME
 *   prompt confirm ADDRESS CODE | prompt display ADDRESS CODE
 *   prompt pin ADDRESS | prompt passkey ADDRESS
 *   canceled                            BlueZ withdrew the prompt
 *   rejected DEVICE_PATH METHOD         a request that was not for the target
 *   rejected sender METHOD              a request that was not from BlueZ
 *
 * The agent accepts a request only if the owner of org.bluez sent it and its
 * device object path is the target.
 * The target stays selected until its pair command fails or its connect
 * command has a result.
 * At end of input the program exits and does not answer a pending prompt.
 * BlueZ then cancels that pairing.
 */
#include <dbus/dbus.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* shortcut: one adapter. Find the adapter path if a device has more. */
#define ADAPTER "/org/bluez/hci0"
#define AGENT "/socket/agent"
#define REJECTED "org.bluez.Error.Rejected"

static DBusConnection *bus;
static char target[18];
static DBusMessage *pending;
static char pending_kind;

static void say(const char *format, ...)
{
	va_list arguments;
	va_start(arguments, format);
	vprintf(format, arguments);
	va_end(arguments);
	putchar('\n');
	fflush(stdout);
}

/* Write the object path of ADDRESS. Return 0 if ADDRESS is not an address. */
static int device_path(const char *address, char *path, size_t size)
{
	size_t start = strlen(ADAPTER "/dev_");
	if (strlen(address) != 17)
		return 0;
	snprintf(path, size, ADAPTER "/dev_%s", address);
	for (size_t i = 0; i < 17; i++) {
		char *c = path + start + i;
		if (i % 3 == 2) {
			if (*c != ':')
				return 0;
			*c = '_';
		} else if (!strchr("0123456789ABCDEF", *c)) {
			return 0;
		}
	}
	return 1;
}

static void send(DBusMessage *message)
{
	if (message != NULL) {
		dbus_connection_send(bus, message, NULL);
		dbus_message_unref(message);
	}
}

static void drop_pending(void)
{
	if (pending != NULL)
		dbus_message_unref(pending);
	pending = NULL;
}

static void on_reply(DBusPendingCall *call, void *tag)
{
	DBusMessage *reply = dbus_pending_call_steal_reply(call);
	const char *error = dbus_message_get_error_name(reply);
	const char *address = strchr(tag, ' ') + 1;
	if (error != NULL)
		say("result %s error %s", (const char *)tag, error);
	else
		say("result %s ok", (const char *)tag);
	/* A successful pair keeps its target for the trust and connect commands. */
	if (!strcmp(address, target) && (!strncmp(tag, "connect ", 8) || (!strncmp(tag, "pair ", 5) && error != NULL))) {
		target[0] = '\0';
		drop_pending();
	}
	dbus_message_unref(reply);
	dbus_pending_call_unref(call);
}

/* Send MESSAGE. Print its result with TAG, which is the command line.
 * BlueZ ends each call. The settings page has the time limit: it stops this
 * program, and BlueZ then cancels the call. */
static void call(DBusMessage *message, const char *tag)
{
	DBusPendingCall *reply = NULL;
	if (message != NULL && dbus_connection_send_with_reply(bus, message, &reply, DBUS_TIMEOUT_INFINITE) && reply != NULL)
		dbus_pending_call_set_notify(reply, on_reply, strdup(tag), free);
	else
		say("result %s error local", tag);
	if (message != NULL)
		dbus_message_unref(message);
}

static DBusMessage *method(const char *path, const char *interface, const char *name)
{
	return dbus_message_new_method_call("org.bluez", path, interface, name);
}

static void answer(const char *text)
{
	DBusMessage *reply = NULL;
	if (pending == NULL)
		return;
	if (pending_kind == 'c') {
		if (!strcmp(text, "yes"))
			reply = dbus_message_new_method_return(pending);
	} else if (pending_kind == 'p') {
		reply = dbus_message_new_method_return(pending);
		dbus_message_append_args(reply, DBUS_TYPE_STRING, &text, DBUS_TYPE_INVALID);
	} else if (text[0] != '\0' && strlen(text) <= 6 && strspn(text, "0123456789") == strlen(text)) {
		dbus_uint32_t passkey = (dbus_uint32_t)strtoul(text, NULL, 10);
		reply = dbus_message_new_method_return(pending);
		dbus_message_append_args(reply, DBUS_TYPE_UINT32, &passkey, DBUS_TYPE_INVALID);
	}
	if (reply == NULL)
		reply = dbus_message_new_error(pending, REJECTED, "Rejected");
	send(reply);
	drop_pending();
}

static void command(const char *line)
{
	char path[64];
	const char *address = strchr(line, ' ');
	DBusMessage *message;
	if (!strcmp(line, "scan on")) {
		call(method(ADAPTER, "org.bluez.Adapter1", "StartDiscovery"), line);
		return;
	}
	if (!strcmp(line, "scan off")) {
		call(method(ADAPTER, "org.bluez.Adapter1", "StopDiscovery"), line);
		return;
	}
	if (!strncmp(line, "answer ", 7)) {
		answer(line + 7);
		return;
	}
	if (address == NULL || !device_path(address + 1, path, sizeof path))
		return;
	if (!strncmp(line, "pair ", 5) || !strncmp(line, "connect ", 8)) {
		/* A new target replaces the old one and its prompt. */
		if (pending != NULL)
			send(dbus_message_new_error(pending, REJECTED, "Rejected"));
		drop_pending();
		snprintf(target, sizeof target, "%s", address + 1);
		call(method(path, "org.bluez.Device1", line[0] == 'p' ? "Pair" : "Connect"), line);
	} else if (!strncmp(line, "disconnect ", 11)) {
		call(method(path, "org.bluez.Device1", "Disconnect"), line);
	} else if (!strncmp(line, "remove ", 7)) {
		const char *object = path;
		message = method(ADAPTER, "org.bluez.Adapter1", "RemoveDevice");
		dbus_message_append_args(message, DBUS_TYPE_OBJECT_PATH, &object, DBUS_TYPE_INVALID);
		call(message, line);
	} else if (!strncmp(line, "trust ", 6)) {
		/* A trusted accessory can connect again without an agent. */
		const char *interface = "org.bluez.Device1", *property = "Trusted";
		dbus_bool_t trusted = TRUE;
		DBusMessageIter arguments, variant;
		message = method(path, "org.freedesktop.DBus.Properties", "Set");
		dbus_message_iter_init_append(message, &arguments);
		dbus_message_iter_append_basic(&arguments, DBUS_TYPE_STRING, &interface);
		dbus_message_iter_append_basic(&arguments, DBUS_TYPE_STRING, &property);
		dbus_message_iter_open_container(&arguments, DBUS_TYPE_VARIANT, "b", &variant);
		dbus_message_iter_append_basic(&variant, DBUS_TYPE_BOOLEAN, &trusted);
		dbus_message_iter_close_container(&arguments, &variant);
		call(message, line);
	}
}

/* Return 1 if MESSAGE comes from the program that owns org.bluez now. */
static int from_bluez(DBusMessage *message)
{
	const char *name = "org.bluez", *owner = NULL;
	DBusMessage *reply, *query = dbus_message_new_method_call("org.freedesktop.DBus", "/org/freedesktop/DBus",
		"org.freedesktop.DBus", "GetNameOwner");
	int same = 0;
	dbus_message_append_args(query, DBUS_TYPE_STRING, &name, DBUS_TYPE_INVALID);
	reply = dbus_connection_send_with_reply_and_block(bus, query, 5000, NULL);
	dbus_message_unref(query);
	if (reply == NULL)
		return 0;
	if (dbus_message_get_args(reply, NULL, DBUS_TYPE_STRING, &owner, DBUS_TYPE_INVALID))
		same = dbus_message_has_sender(message, owner);
	dbus_message_unref(reply);
	return same;
}

static void hold(DBusMessage *message, char kind)
{
	if (pending != NULL)
		send(dbus_message_new_error(pending, REJECTED, "Rejected"));
	drop_pending();
	pending = dbus_message_ref(message);
	pending_kind = kind;
}

static DBusHandlerResult agent(DBusConnection *connection, DBusMessage *message, void *data)
{
	const char *member = dbus_message_get_member(message);
	const char *path = "";
	char expected[64];
	DBusMessageIter arguments;
	(void)connection;
	(void)data;
	if (dbus_message_get_type(message) != DBUS_MESSAGE_TYPE_METHOD_CALL || member == NULL ||
		!dbus_message_has_interface(message, "org.bluez.Agent1"))
		return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
	/* Other programs on the system bus cannot use the agent. */
	if (!from_bluez(message)) {
		say("rejected sender %s", member);
		send(dbus_message_new_error(message, REJECTED, "Rejected"));
		return DBUS_HANDLER_RESULT_HANDLED;
	}
	if (!strcmp(member, "Cancel") || !strcmp(member, "Release")) {
		drop_pending();
		say("canceled");
		send(dbus_message_new_method_return(message));
		return DBUS_HANDLER_RESULT_HANDLED;
	}
	if (dbus_message_iter_init(message, &arguments) && dbus_message_iter_get_arg_type(&arguments) == DBUS_TYPE_OBJECT_PATH)
		dbus_message_iter_get_basic(&arguments, &path);
	/* Each request names its device. Only the selected target can continue. */
	if (!device_path(target, expected, sizeof expected) || strcmp(path, expected)) {
		say("rejected %s %s", path, member);
		send(dbus_message_new_error(message, REJECTED, "Rejected"));
		return DBUS_HANDLER_RESULT_HANDLED;
	}
	dbus_message_iter_next(&arguments);
	if (!strcmp(member, "RequestConfirmation") && dbus_message_iter_get_arg_type(&arguments) == DBUS_TYPE_UINT32) {
		dbus_uint32_t code;
		dbus_message_iter_get_basic(&arguments, &code);
		say("prompt confirm %s %06u", target, code);
		hold(message, 'c');
	} else if (!strcmp(member, "RequestPinCode")) {
		say("prompt pin %s", target);
		hold(message, 'p');
	} else if (!strcmp(member, "RequestPasskey")) {
		say("prompt passkey %s", target);
		hold(message, 'k');
	} else if (!strcmp(member, "DisplayPasskey") && dbus_message_iter_get_arg_type(&arguments) == DBUS_TYPE_UINT32) {
		dbus_uint32_t code;
		dbus_message_iter_get_basic(&arguments, &code);
		say("prompt display %s %06u", target, code);
		send(dbus_message_new_method_return(message));
	} else if (!strcmp(member, "DisplayPinCode") && dbus_message_iter_get_arg_type(&arguments) == DBUS_TYPE_STRING) {
		const char *code;
		dbus_message_iter_get_basic(&arguments, &code);
		/* The code comes from BlueZ. Print it only if it is plain text. */
		if (code[0] != '\0' && strlen(code) <= 16 &&
			strspn(code, "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz") == strlen(code))
			say("prompt display %s %s", target, code);
		send(dbus_message_new_method_return(message));
	} else if (!strcmp(member, "RequestAuthorization") || !strcmp(member, "AuthorizeService")) {
		/* No code to compare. The user selected this device and confirmed. */
		send(dbus_message_new_method_return(message));
	} else {
		send(dbus_message_new_error(message, REJECTED, "Rejected"));
	}
	return DBUS_HANDLER_RESULT_HANDLED;
}

static int manager(const char *name, int with_capability)
{
	const char *path = AGENT, *capability = "KeyboardDisplay";
	DBusMessage *message = method("/org/bluez", "org.bluez.AgentManager1", name), *reply;
	dbus_message_append_args(message, DBUS_TYPE_OBJECT_PATH, &path, DBUS_TYPE_INVALID);
	if (with_capability)
		dbus_message_append_args(message, DBUS_TYPE_STRING, &capability, DBUS_TYPE_INVALID);
	reply = dbus_connection_send_with_reply_and_block(bus, message, 5000, NULL);
	dbus_message_unref(message);
	if (reply == NULL)
		return 0;
	dbus_message_unref(reply);
	return 1;
}

int main(void)
{
	static const DBusObjectPathVTable table = { .message_function = agent };
	static char buffer[256];
	size_t used = 0;
	int bus_fd;
	bus = dbus_bus_get(DBUS_BUS_SYSTEM, NULL);
	if (bus == NULL || !dbus_connection_register_object_path(bus, AGENT, &table, NULL) ||
		!dbus_connection_get_unix_fd(bus, &bus_fd))
		return 1;
	/* The default agent also gets, and rejects, requests that start remotely. */
	if (!manager("RegisterAgent", 1) || !manager("RequestDefaultAgent", 0))
		return 1;
	say("ready");
	fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL) | O_NONBLOCK);
	for (;;) {
		struct pollfd fds[2] = { { STDIN_FILENO, POLLIN, 0 }, { bus_fd, POLLIN, 0 } };
		ssize_t count;
		dbus_connection_flush(bus);
		poll(fds, 2, -1);
		while ((count = read(STDIN_FILENO, buffer + used, sizeof buffer - 1 - used)) > 0) {
			char *end;
			used += (size_t)count;
			buffer[used] = '\0';
			while ((end = strchr(buffer, '\n')) != NULL) {
				*end = '\0';
				command(buffer);
				used -= (size_t)(end + 1 - buffer);
				memmove(buffer, end + 1, used + 1);
			}
			/* Drop a line that is too long to be a command. */
			if (used == sizeof buffer - 1)
				used = 0;
		}
		if (count == 0 || (errno != EAGAIN && errno != EINTR))
			return 0;
		if (!dbus_connection_read_write(bus, 0))
			return 1;
		while (dbus_connection_dispatch(bus) == DBUS_DISPATCH_DATA_REMAINS) {
		}
	}
}

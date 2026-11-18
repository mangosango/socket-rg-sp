// Create the private WPA2 configuration and manage the Wi-Fi process lifetime.
#define _POSIX_C_SOURCE 200809L
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <mbedtls/pkcs5.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/prctl.h>
#endif

static char *trim(char *s) {
	s += strspn(s, " \t");
	size_t n = strlen(s);
	while (n && strchr(" \t\r\n", s[n - 1])) s[--n] = 0;
	return s;
}

static void hex(FILE *f, const unsigned char *data, size_t size) {
	for (size_t i = 0; i < size; i++) fprintf(f, "%02x", data[i]);
}

static int write_config(const char *path, const char *ctrl) {
	char line[1024], ssid[33] = "", psk[65] = "";
	// Reject binary input and long lines before they can change a field.
	size_t used = 0;
	int c;
	do {
		c = getchar();
		if (c != EOF && c != '\n') {
			if (!c || used >= sizeof(line) - 1) return 1;
			line[used++] = (char)c;
			continue;
		}
		line[used] = 0;
		used = 0;
		char *field = trim(line), *value = strchr(field, '=');
		if (!value || *field == '#') continue;
		*value++ = 0;
		field = trim(field);
		value = trim(value);
		int is_ssid = !strcmp(field, "ssid");
		if (!is_ssid && strcmp(field, "psk")) continue;
		size_t size = strlen(value);
		if (!size || size >= (is_ssid ? sizeof(ssid) : sizeof(psk))) return 1;
		for (size_t i = 0; i < size; i++)
			if (iscntrl((unsigned char)value[i])) return 1;
		strcpy(is_ssid ? ssid : psk, value);
	} while (c != EOF);
	if (ferror(stdin) || !*ssid || strlen(psk) < 8) return 1;
	unsigned char key[32];
	int raw = strlen(psk) == 64;
	if (raw) {
		if (strspn(psk, "0123456789abcdefABCDEF") != 64) return 1;
	} else if (mbedtls_pkcs5_pbkdf2_hmac_ext(MBEDTLS_MD_SHA1, (unsigned char *)psk,
			strlen(psk), (unsigned char *)ssid, strlen(ssid), 4096, sizeof(key), key)) return 1;

	int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
	if (fd < 0) return 1;
	FILE *f = fdopen(fd, "w");
	if (!f) { close(fd); unlink(path); return 1; }
	fprintf(f, "ctrl_interface=%s\nnetwork={\n\tscan_ssid=1\n\tproto=RSN\n\tkey_mgmt=WPA-PSK\n\tssid=", ctrl);
	hex(f, (unsigned char *)ssid, strlen(ssid));
	fputs("\n\tpsk=", f);
	if (raw) fputs(psk, f);
	else hex(f, key, sizeof(key));
	fputs("\n}\n", f);
	int failed = ferror(f);
	if (fclose(f) || failed) { unlink(path); return 1; }
	return 0;
}

// BaseOS kills the client even if its worker dies before it can record the PID.
static int bind_parent(const char *expected) {
#ifdef __linux__
	if (prctl(PR_SET_PDEATHSIG, SIGKILL) < 0) return -1;
#endif
	return getppid() == strtol(expected, NULL, 10) ? 0 : -1;
}

static int session(const char *lock_path, const char *script, const char *action) {
	const char *parent = getenv("SOCKET_WIFI_PARENT");
	int stop = !strcmp(action, "stop");
	if (!stop && parent && bind_parent(parent)) return 1;
	int fd = open(lock_path, O_RDWR | O_CREAT, 0600);
	if (fd < 0) return 1;
	// This lock stays with the shell across exec. Its children never own it.
	struct flock lock = { .l_type = F_WRLCK, .l_whence = SEEK_SET };
	for (int n = 0; fcntl(fd, F_SETLK, &lock) < 0; n++) {
		if (errno != EACCES && errno != EAGAIN) return 1;
		if (!stop && !parent) return 0;
		if (n == 50) return stop ? 1 : 0;
		nanosleep(&(struct timespec){ .tv_nsec = 100000000 }, NULL);
	}
	execl("/bin/sh", "sh", script, "--locked", action, (char *)NULL);
	return 1;
}

int main(int argc, char **argv) {
	if (argc == 5 && !strcmp(argv[1], "--session"))
		return session(argv[2], argv[3], argv[4]);
	if (argc >= 4 && !strcmp(argv[1], "--child")) {
		if (bind_parent(argv[2])) return 1;
		execvp(argv[3], argv + 3);
		return 1;
	}
	return argc == 3 ? write_config(argv[1], argv[2]) : 1;
}

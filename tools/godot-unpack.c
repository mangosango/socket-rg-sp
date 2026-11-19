// Godot encrypted file: md5[16], LE plain_len[8], iv[16], padded AES-256-CFB data.
#define _XOPEN_SOURCE 700
#define OPENSSL_SUPPRESS_DEPRECATED
#include <openssl/aes.h>
#include <openssl/crypto.h>
#include <openssl/md5.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define LIB_LIMIT (256u << 20)
#define CFG_LIMIT (4u << 20)
#define ASSET_LIMIT (128u << 20)
#define HEADER 40u

static AES_KEY key;
static int ready;

void reset_unpack(void) {
	OPENSSL_cleanse(&key, sizeof(key));
	ready = 0;
}

static int plain_length(const unsigned char *in, size_t len) {
	if (!in || len < HEADER || len > ASSET_LIMIT) return -1;
	uint64_t n = 0;
	for (int i = 7; i >= 0; --i) n = (n << 8) | in[16 + i];
	if (n > len - HEADER || ((n + 15) & ~(uint64_t)15) != len - HEADER) return -1;
	return (int)n;
}

static int decrypt(const AES_KEY *k, const unsigned char *in, unsigned char *out, int n) {
	unsigned char iv[16], md[16];
	MD5_CTX ctx;
	int pos = 0;
	memcpy(iv, in + 24, sizeof(iv));
	AES_cfb128_encrypt(in + HEADER, out, n, k, iv, &pos, AES_DECRYPT);
	return MD5_Init(&ctx) && MD5_Update(&ctx, out, n) && MD5_Final(md, &ctx) && !memcmp(md, in, 16);
}

// Replaces any previous session, including on failure. The key never leaves C.
int start_unpack(const unsigned char *lib, size_t lib_len, const unsigned char *cfg, size_t cfg_len) {
	reset_unpack();
	if (!lib || lib_len < 32 || lib_len > LIB_LIMIT || cfg_len > CFG_LIMIT) return 0;
	int n = plain_length(cfg, cfg_len);
	if (n < 4) return 0;
	unsigned char expected[4];
	for (int i = 0; i < 4; ++i) expected[i] = cfg[HEADER + i] ^ "ECFG"[i];
	// Bound full config checks even if a hostile library repeats a matching prefix.
	unsigned checks = 0;
	for (size_t off = 0; off <= lib_len - 32; off += 8) {
		unsigned char block[16];
		if (AES_set_encrypt_key(lib + off, 256, &key)) break;
		AES_encrypt(cfg + 24, block, &key);
		if (memcmp(block, expected, sizeof(expected))) continue;
		if (++checks > 8) break;
		unsigned char *out = malloc(n);
		if (!out) break;
		ready = decrypt(&key, cfg, out, n);
		OPENSSL_cleanse(out, n);
		free(out);
		if (ready) return 1;
	}
	reset_unpack();
	return 0;
}

// On success plaintext occupies in[HEADER..HEADER+n). Caller owns the buffer.
int decrypt_asset(unsigned char *in, size_t len) {
	int n = plain_length(in, len);
	return ready && n >= 0 && decrypt(&key, in, in + HEADER, n) ? n : -1;
}

#ifndef __EMSCRIPTEN__
#include <ftw.h>
#include <stdio.h>
#include <sys/stat.h>

static unsigned char *slurp(const char *path, size_t *len, size_t limit) {
	FILE *f = fopen(path, "rb");
	if (!f) return NULL;
	unsigned char *buf = NULL;
	long n;
	if (!fseek(f, 0, SEEK_END) && (n = ftell(f)) >= 0 && (unsigned long)n <= limit && !fseek(f, 0, SEEK_SET)) {
		*len = (size_t)n;
		buf = malloc(n ? (size_t)n : 1);
		if (buf && fread(buf, 1, *len, f) != *len) { free(buf); buf = NULL; }
	}
	fclose(f);
	return buf;
}

static const char *src_root, *dst_root;
static int failures;

static void mkdirs(char *path) {
	for (char *p = path + 1; *p; p++) {
		if (*p == '/') { *p = 0; mkdir(path, 0755); *p = '/'; }
	}
}

static int decrypt_file(const char *path, const struct stat *st, int type, struct FTW *ftw) {
	(void)st; (void)ftw;
	if (type != FTW_F) return 0;
	size_t len = 0;
	unsigned char *in = slurp(path, &len, ASSET_LIMIT);
	int n = decrypt_asset(in, len);
	char dst[4096];
	if (n < 0 || snprintf(dst, sizeof(dst), "%s%s", dst_root, path + strlen(src_root)) >= (int)sizeof(dst)) {
		failures++;
	} else {
		mkdirs(dst);
		FILE *f = fopen(dst, "wb");
		if (!f) failures++;
		else {
			int ok = fwrite(in + HEADER, 1, n, f) == (size_t)n;
			if (fclose(f) || !ok) failures++;
		}
	}
	free(in);
	return 0;
}

int main(int argc, char **argv) {
	if (argc == 5 && !strcmp(argv[1], "extract")) {
		char config[4096];
		if (snprintf(config, sizeof(config), "%s/project.binary", argv[3]) >= (int)sizeof(config)) return 64;
		size_t ll = 0, cl = 0;
		unsigned char *lib = slurp(argv[2], &ll, LIB_LIMIT), *cfg = slurp(config, &cl, CFG_LIMIT);
		int ok = start_unpack(lib, ll, cfg, cl);
		free(lib);
		free(cfg);
		if (!ok) { fprintf(stderr, "invalid unpack inputs\n"); return 1; }
		src_root = argv[3];
		dst_root = argv[4];
		if (nftw(src_root, decrypt_file, 32, FTW_PHYS)) return 1;
		if (failures) fprintf(stderr, "could not extract all assets\n");
		return failures ? 2 : 0;
	}
	fprintf(stderr, "usage: godot-unpack extract <libgodot.so> <src-dir> <dst-dir>\n");
	return 64;
}
#endif

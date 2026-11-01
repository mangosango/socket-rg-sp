// Recover and decrypt the encrypted Godot 4 pack files of an exported project.
//
//   godot-unpack extract <libgodot.so> <src-dir> <dst-dir>
//
// Each encrypted file is: md5[16] plain_len[8] iv[16] AES-256-CFB data.
// The pack key stays in this process.
#define _XOPEN_SOURCE 700
#include <ftw.h>
#include <openssl/evp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

static unsigned char *slurp(const char *path, long *len) {
	FILE *f = fopen(path, "rb");
	if (!f) return NULL;
	fseek(f, 0, SEEK_END);
	*len = ftell(f);
	rewind(f);
	unsigned char *buf = malloc(*len ? *len : 1);
	if (fread(buf, 1, *len, f) != (size_t)*len) { free(buf); buf = NULL; }
	fclose(f);
	return buf;
}

static unsigned char key[32];

static int find_key(const char *lib_path, const char *cfg_path) {
	long lib_len, cfg_len;
	unsigned char *lib = slurp(lib_path, &lib_len), *cfg = slurp(cfg_path, &cfg_len);
	if (!lib || !cfg || cfg_len < 56) { fprintf(stderr, "cannot read inputs\n"); return 1; }
	EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
	// Keys are global arrays; 8-byte alignment covers AArch64 builds.
	for (long o = 0; o + 32 <= lib_len; o += 8) {
		unsigned char out[32];
		int n;
		EVP_EncryptInit_ex(ctx, EVP_aes_256_ecb(), NULL, lib + o, NULL);
		EVP_CIPHER_CTX_set_padding(ctx, 0);
		EVP_EncryptUpdate(ctx, out, &n, cfg + 24, 16); // CFB block 0 = E(iv) ^ c0.
		if ((out[0] ^ cfg[40]) == 'E' && (out[1] ^ cfg[41]) == 'C' && (out[2] ^ cfg[42]) == 'F' && (out[3] ^ cfg[43]) == 'G') {
			memcpy(key, lib + o, sizeof(key));
			EVP_CIPHER_CTX_free(ctx);
			free(lib);
			free(cfg);
			return 0;
		}
	}
	EVP_CIPHER_CTX_free(ctx);
	free(lib);
	free(cfg);
	fprintf(stderr, "no key found\n");
	return 1;
}

static const char *src_root, *dst_root;
static int failures;

static int mkdirs(char *path) {
	for (char *p = path + 1; *p; p++) {
		if (*p == '/') { *p = 0; mkdir(path, 0755); *p = '/'; }
	}
	return 0;
}

static int decrypt_file(const char *path, const struct stat *st, int type, struct FTW *ftw) {
	(void)st; (void)ftw;
	if (type != FTW_F) return 0;
	long len;
	unsigned char *in = slurp(path, &len);
	uint64_t plain_len = 0;
	if (in && len >= 40) memcpy(&plain_len, in + 16, 8);
	if (!in || len < 40 || plain_len > (uint64_t)(len - 40)) {
		fprintf(stderr, "skip %s: not an encrypted pack file\n", path);
		failures++;
		free(in);
		return 0;
	}
	unsigned char *out = malloc(len - 40 + 16), md[16];
	int n;
	EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
	EVP_DecryptInit_ex(ctx, EVP_aes_256_cfb128(), NULL, key, in + 24);
	EVP_DecryptUpdate(ctx, out, &n, in + 40, (int)(len - 40));
	EVP_CIPHER_CTX_free(ctx);
	EVP_Digest(out, plain_len, md, NULL, EVP_md5(), NULL);
	if (memcmp(md, in, 16) != 0) {
		fprintf(stderr, "skip %s: MD5 mismatch\n", path);
		failures++;
	} else {
		char dst[4096];
		snprintf(dst, sizeof(dst), "%s%s", dst_root, path + strlen(src_root));
		mkdirs(dst);
		FILE *f = fopen(dst, "wb");
		if (!f || fwrite(out, 1, plain_len, f) != plain_len) { fprintf(stderr, "cannot write %s\n", dst); failures++; }
		if (f) fclose(f);
	}
	free(in);
	free(out);
	return 0;
}

int main(int argc, char **argv) {
	if (argc == 5 && !strcmp(argv[1], "extract")) {
		char config[4096];
		if (snprintf(config, sizeof(config), "%s/project.binary", argv[3]) >= (int)sizeof(config)) return 64;
		if (find_key(argv[2], config)) return 1;
		src_root = argv[3];
		dst_root = argv[4];
		if (nftw(src_root, decrypt_file, 32, FTW_PHYS)) return 1;
		return failures ? 2 : 0;
	}
	fprintf(stderr, "usage: godot-unpack extract <libgodot.so> <src-dir> <dst-dir>\n");
	return 64;
}

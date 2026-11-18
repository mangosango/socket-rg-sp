#include <assert.h>
#include "../tools/retroarch-achievements.h"

static void write_account(const char *path, const char *text)
{
   FILE *file = fopen(path, "w");
   assert(file && fputs(text, file) >= 0 && fclose(file) == 0);
}

int main(int argc, char **argv)
{
   struct socket_account initial, stored;
   assert(argc == 2);
   write_account(argv[1], "# test\r\nusername = player\r\npassword = a #=\"b\\c\r\n");
   assert(socket_account_read(argv[1], &initial));
   assert(!strcmp(initial.password, "a #=\"b\\c"));
   assert(!socket_account_store(argv[1], &initial, "bad\ntoken"));
   assert(socket_account_store(argv[1], &initial, "sample-token"));
   assert(socket_account_read(argv[1], &stored));
   assert(!stored.password[0] && !strcmp(stored.username, "player") && !strcmp(stored.token, "sample-token"));
   assert(!socket_account_store(argv[1], &initial, "stale"));
   assert(socket_account_store(argv[1], &stored, "sample-token"));
   write_account(argv[1], "username = player\ntoken = one\npassword = two\n");
   assert(!socket_account_read(argv[1], &stored));
   return 0;
}

/* Check cheat file matching, listing names, URL text and download checks. */
#include <assert.h>
#define SOCKET_CHEATS_PURE_ONLY
#include "../tools/retroarch-cheats-menu.h"

int main(void)
{
   char text[256];
   const char *at;
   const char *listing = "{\"tree\": [{\"path\": \"Pokemon - Emerald Version (USA, Europe) (Code Breaker).cht\", \"type\": \"blob\"},"
      "{\"path\":\"../evil.cht\"},{\"path\": \"bad\\\"quote.cht\"},{\"path\": \"notes.txt\"},{\"path\": \"1942.cht\"}]}";

   assert(!strcmp(socket_cheats_system("gba"), "Nintendo - Game Boy Advance"));
   assert(!strcmp(socket_cheats_system("GBC"), "Nintendo - Game Boy Color"));
   assert(!strcmp(socket_cheats_system("gb"), "Nintendo - Game Boy"));
   assert(!socket_cheats_system("g") && !socket_cheats_system("gbax") && !socket_cheats_system("zip") && !socket_cheats_system(NULL));

   socket_cheats_key("Pokemon - Emerald Version (USA, Europe) (Code Breaker).cht", text, sizeof(text));
   assert(!strcmp(text, "pokemonemeraldversion"));
   /* RetroArch gives the ROM name without its extension. */
   socket_cheats_key("Pokemon - Emerald Version [T-En]", text, sizeof(text));
   assert(!strcmp(text, "pokemonemeraldversion"));
   socket_cheats_key("Tetris", text, sizeof(text));
   assert(!strcmp(text, "tetris"));
   socket_cheats_key("Tetris (World) (Rev 1).cht", text, sizeof(text));
   assert(!strcmp(text, "tetris"));
   socket_cheats_key("1942.cht", text, sizeof(text));
   assert(!strcmp(text, "1942"));
   socket_cheats_key("(USA).cht", text, sizeof(text));
   assert(!text[0]);

   assert((at = socket_cheats_next(listing, text, sizeof(text))));
   assert(!strcmp(text, "Pokemon - Emerald Version (USA, Europe) (Code Breaker).cht"));
   assert((at = socket_cheats_next(at, text, sizeof(text))) && !strcmp(text, "1942.cht"));
   assert(!socket_cheats_next(at, text, sizeof(text)));
   assert(!socket_cheats_name_ok(".cht") && !socket_cheats_name_ok(".hidden.cht") && !socket_cheats_name_ok("a/b.cht"));

   assert(socket_cheats_platform_ok("nes") && socket_cheats_platform_ok("mega-drive_2"));
   assert(!socket_cheats_platform_ok("") && !socket_cheats_platform_ok(NULL) && !socket_cheats_platform_ok(".."));
   assert(!socket_cheats_platform_ok("a/b") && !socket_cheats_platform_ok("123456789012345678901234567890123"));

   assert(socket_cheats_encode("Nintendo - Game Boy (A, B).cht", text, sizeof(text)));
   assert(!strcmp(text, "Nintendo%20-%20Game%20Boy%20%28A%2C%20B%29.cht"));
   assert(!socket_cheats_encode("a b", text, 5));

#define VALID(text) socket_cheats_valid(text, sizeof(text) - 1)
   assert(VALID("cheats = 1\ncheat0_desc = \"x\"\ncheat0_code = \"AB\"\ncheat0_enable = false"));
   assert(VALID("# note\r\ncheats = \"2\"\r\ncheat1_code = \"CD\"\r\ncheat0_code = \"AB\"\r\n"));
   assert(VALID("cheats=1\ncheat0_code = \"AB\""));
   /* A cut transfer: the last cheat is missing, or its code line is cut. */
   assert(!VALID("cheats = 2\ncheat0_desc = \"x\"\ncheat0_code = \"AB\"\n"));
   assert(!VALID("cheats = 1\ncheat0_code = \"A"));
   assert(!VALID("cheats = 12\ncheat1_code = \"AB\"\n"));
   /* RetroArch allocates memory for the count. */
   assert(!VALID("cheats = 4000000000\ncheat3999999999_code = \"AB\"\n"));
   assert(!VALID("cheats = 16385\ncheat16384_code = \"AB\"\n"));
   assert(!VALID("cheats = 0x10\ncheat15_code = \"AB\"\n"));
   assert(!VALID("cheats = 0\n") && !VALID("cheats = -1\n") && !VALID("cheats =\n"));
   /* RetroArch uses the last count line. */
   assert(!VALID("cheats = 1\ncheat0_code = \"AB\"\n  cheats = 99999999\n"));
   assert(!VALID("cheats = 1\ncheat0_code = \"AB\"\n#include \"/etc/passwd\"\n"));
   assert(!VALID("<html>Not cheats</html>\n") && !VALID("cheats_total = 1\ncheat0_code = \"AB\"\n"));
   assert(!socket_cheats_valid("", 0) && !socket_cheats_valid(NULL, 20));
   assert(!socket_cheats_valid("cheats = 1\ncheat0_code = \"AB\"\n\0", 31));
   return 0;
}

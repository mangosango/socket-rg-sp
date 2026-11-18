// Read the Socket card account without passing credentials to the shell.
#ifndef SOCKET_ACHIEVEMENTS_H
#define SOCKET_ACHIEVEMENTS_H

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct socket_account {
   char username[32];
   char password[256];
   char token[32];
};

static char *socket_account_trim(char *text)
{
   char *end;
   while (isspace((unsigned char)*text))
      ++text;
   end = text + strlen(text);
   while (end > text && isspace((unsigned char)end[-1]))
      *--end = '\0';
   return text;
}

static int socket_account_read(const char *path, struct socket_account *account)
{
   char line[512];
   FILE *file = fopen(path, "r");
   int valid = 1;
   memset(account, 0, sizeof(*account));
   if (!file)
      return 0;
   while (fgets(line, sizeof(line), file))
   {
      char *key, *value, *field;
      size_t capacity;
      if (!strchr(line, '\n') && !feof(file)) { valid = 0; break; }
      key = socket_account_trim(line);
      if (!*key || *key == '#')
         continue;
      value = strchr(key, '=');
      if (!value) { valid = 0; break; }
      *value++ = '\0';
      key = socket_account_trim(key);
      value = socket_account_trim(value);
      if (!strcmp(key, "username")) { field = account->username; capacity = sizeof(account->username); }
      else if (!strcmp(key, "password")) { field = account->password; capacity = sizeof(account->password); }
      else if (!strcmp(key, "token")) { field = account->token; capacity = sizeof(account->token); }
      else continue;
      if (*field || strlen(value) >= capacity || strpbrk(value, "\r\n")) { valid = 0; break; }
      strcpy(field, value);
   }
   valid = valid && !ferror(file) && account->username[0] &&
         (!!account->token[0] != !!account->password[0]);
   fclose(file);
   return valid;
}

// Replace only the credentials used for this login. Leave failed logins intact.
static int socket_account_store(const char *path, const struct socket_account *used, const char *token)
{
   struct socket_account current;
   char temporary[4096];
   int fd, saved;
   FILE *file;
   if (!token || !*token || strlen(token) >= sizeof(current.token) ||
       strpbrk(token, "\r\n") || !socket_account_read(path, &current) ||
       memcmp(&current, used, sizeof(current)) != 0)
      return 0;
   if (!strcmp(current.token, token))
      return 1;
   if (snprintf(temporary, sizeof(temporary), "%s.XXXXXX", path) >= (int)sizeof(temporary))
      return 0;
   fd = mkstemp(temporary);
   if (fd < 0)
      return 0;
   file = fdopen(fd, "w");
   if (!file) { close(fd); unlink(temporary); return 0; }
   saved = fprintf(file, "username = %s\ntoken = %s\n", current.username, token) > 0 &&
         fflush(file) == 0 && fsync(fd) == 0;
   if (fclose(file) || !saved || rename(temporary, path))
   {
      unlink(temporary);
      return 0;
   }
   return 1;
}

#endif

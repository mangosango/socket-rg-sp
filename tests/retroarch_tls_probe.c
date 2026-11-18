#include <netdb.h>
#include <stdint.h>
#include <time.h>
#include <features/features_cpu.h>
#include <net/net_socket_ssl.h>
#include <sys/socket.h>

// The socket timeout uses the frontend's microsecond clock.
retro_time_t cpu_features_get_time_usec(void)
{
   struct timespec ts;
   clock_gettime(CLOCK_MONOTONIC, &ts);
   return (retro_time_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}

int main(int argc, char **argv)
{
   struct addrinfo *addresses = NULL, *address;
   int ok = 0;
   if (argc != 4 || getaddrinfo(argv[1], argv[2], NULL, &addresses))
      return 2;
   for (address = addresses; address && !ok; address = address->ai_next)
   {
      void *context;
      int fd;
      if (address->ai_socktype != SOCK_STREAM)
         continue;
      fd = socket(address->ai_family, SOCK_STREAM, 0);
      if (fd < 0)
         continue;
      context = ssl_socket_init(fd, argv[3]);
      if (!context)
         return 2;
      ok = ssl_socket_connect(context, address, true, false) >= 0;
      ssl_socket_close(context);
      ssl_socket_free(context);
   }
   freeaddrinfo(addresses);
   return ok ? 0 : 1;
}

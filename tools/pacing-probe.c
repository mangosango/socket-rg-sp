/* Record RetroArch frame and audio timing on the device.
 *
 * Build: see tools/build-pacing-probe.sh. Use:
 *   LD_PRELOAD=pacing-probe.so SOCKET_PACING_LOG=/mnt/sdcard/Logs/socket-pacing.csv retroarch ...
 * Then on the Mac: python3 tools/pacing-report.py socket-pacing.csv
 *
 * Lines (times are CLOCK_MONOTONIC nanoseconds):
 *   F <panel Hz from fb0 timing, 0 if unknown>
 *   S <t>                          one presented video frame
 *   W <t> <frames> <avail> <buffer> one ALSA write; avail and buffer in frames
 *   U <t> <error>                  ALSA recovered from an error (-32 is underrun)
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>
#include <EGL/egl.h>
#include <alsa/asoundlib.h>

static FILE *log_file;
static long long last_flush;

static long long now_ns(void)
{
   struct timespec now;
   clock_gettime(CLOCK_MONOTONIC, &now);
   return now.tv_sec * 1000000000LL + now.tv_nsec;
}

static void flush_log(void)
{
   if (log_file)
      fflush(log_file);
}

static FILE *pacing_log(void)
{
   const char *path;
   if (log_file)
      return log_file;
   path = getenv("SOCKET_PACING_LOG");
   if (!path || !(log_file = fopen(path, "w")))
      return NULL;
   setvbuf(log_file, NULL, _IOFBF, 1 << 16);
   {
      struct fb_var_screeninfo info;
      double hz = 0;
      int fd = open("/dev/fb0", O_RDONLY);
      if (fd >= 0 && ioctl(fd, FBIOGET_VSCREENINFO, &info) == 0 && info.pixclock)
         hz = 1e12 / info.pixclock
            / (info.xres + info.left_margin + info.right_margin + info.hsync_len)
            / (info.yres + info.upper_margin + info.lower_margin + info.vsync_len);
      if (fd >= 0)
         close(fd);
      fprintf(log_file, "F %.4f\n", hz);
   }
   atexit(flush_log);
   return log_file;
}

/* Flush about once a second so a power cut keeps most of the record. */
static void record_done(long long t)
{
   if (t - last_flush > 1000000000LL)
   {
      fflush(log_file);
      last_flush = t;
   }
}

EGLBoolean eglSwapBuffers(EGLDisplay display, EGLSurface surface)
{
   static EGLBoolean (*real)(EGLDisplay, EGLSurface);
   EGLBoolean result;
   if (!real)
      real = dlsym(RTLD_NEXT, "eglSwapBuffers");
   result = real(display, surface);
   if (pacing_log())
   {
      long long t = now_ns();
      fprintf(log_file, "S %lld\n", t);
      record_done(t);
   }
   return result;
}

snd_pcm_sframes_t snd_pcm_writei(snd_pcm_t *pcm, const void *buffer, snd_pcm_uframes_t frames)
{
   static snd_pcm_sframes_t (*real)(snd_pcm_t *, const void *, snd_pcm_uframes_t);
   snd_pcm_uframes_t size = 0, period = 0;
   snd_pcm_sframes_t avail = snd_pcm_avail_update(pcm);
   if (!real)
      real = dlsym(RTLD_NEXT, "snd_pcm_writei");
   if (pacing_log())
   {
      long long t = now_ns();
      snd_pcm_get_params(pcm, &size, &period);
      fprintf(log_file, "W %lld %lu %ld %lu\n", t, (unsigned long)frames, (long)avail, (unsigned long)size);
      record_done(t);
   }
   return real(pcm, buffer, frames);
}

int snd_pcm_recover(snd_pcm_t *pcm, int error, int silent)
{
   static int (*real)(snd_pcm_t *, int, int);
   if (!real)
      real = dlsym(RTLD_NEXT, "snd_pcm_recover");
   if (pacing_log())
   {
      long long t = now_ns();
      fprintf(log_file, "U %lld %d\n", t, error);
      fflush(log_file);
   }
   return real(pcm, error, silent);
}

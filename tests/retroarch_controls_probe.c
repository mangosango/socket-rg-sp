/* Capture the real GL framebuffer and the floats sent to ALSA. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <unistd.h>
#include <time.h>
#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <alsa/asoundlib.h>

static double seconds(void)
{
   struct timespec now;
   clock_gettime(CLOCK_MONOTONIC, &now);
   return now.tv_sec + now.tv_nsec / 1e9;
}

EGLBoolean eglSwapBuffers(EGLDisplay display, EGLSurface surface)
{
   EGLBoolean (*real_swap)(EGLDisplay, EGLSurface) = dlsym(RTLD_NEXT, "eglSwapBuffers");
   if (access("/output/capture", F_OK) == 0)
   {
      unsigned char pixels[720 * 480 * 4];
      FILE *file;
      glReadPixels(0, 0, 720, 480, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
      file = fopen("/output/frame.rgba.tmp", "wb");
      fwrite(pixels, 1, sizeof(pixels), file);
      fclose(file);
      rename("/output/frame.rgba.tmp", "/output/frame.rgba");
      unlink("/output/capture");
   }
   return real_swap(display, surface);
}

snd_pcm_sframes_t snd_pcm_writei(snd_pcm_t *pcm, const void *buffer, snd_pcm_uframes_t frames)
{
   snd_pcm_sframes_t (*real_write)(snd_pcm_t *, const void *, snd_pcm_uframes_t) = dlsym(RTLD_NEXT, "snd_pcm_writei");
   const float *samples = buffer;
   float peak = 0;
   unsigned long i;
   FILE *file;
   for (i = 0; i < frames * 2; i++)
      if (fabsf(samples[i]) > peak) peak = fabsf(samples[i]);
   file = fopen("/output/audio.csv", "a");
   fprintf(file, "%.6f %.9f\n", seconds(), peak);
   fclose(file);
   return real_write(pcm, buffer, frames);
}

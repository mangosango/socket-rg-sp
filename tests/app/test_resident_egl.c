/* Use real Mesa GLES with pbuffers in place of the handheld framebuffer. */
#define _GNU_SOURCE
#include "../retroarch_headless_egl.c"
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <alsa/asoundlib.h>
#include <GLES3/gl3.h>

static void *pcm_open_target;
static void *pcm_close_target;
static EGLSurface current_surface;
static int surface_live;
static int surface_sequence;
static int surface_swaps;
static EGLSurface pending_surface;

static void record(const char *operation, void *object)
{
   const char *path = getenv("SOCKET_EGL_TRACE");
   FILE *file = path ? fopen(path, "a") : NULL;
   if (file)
   {
      fprintf(file, "%d %s %p\n", getpid(), operation, object);
      fclose(file);
   }
}

int open(const char *path, int flags, ...)
{
   mode_t mode = 0;
   if (flags & O_CREAT)
   {
      va_list args;
      va_start(args, flags);
      mode = va_arg(args, mode_t);
      va_end(args);
   }
   int (*real_open)(const char *, int, ...) = dlsym(RTLD_NEXT, "open");
   return real_open(strcmp(path, "/dev/fb0") == 0 ? "/dev/null" : path, flags, mode);
}

int open64(const char *path, int flags, ...) __attribute__((alias("open")));

static EGLSurface create_window(EGLDisplay display, EGLConfig config,
      EGLNativeWindowType window, const EGLint *attributes)
{
   EGLSurface surface = eglCreateWindowSurface(display, config, window, attributes);
   if (pending_surface)
   {
      PFNEGLDESTROYSURFACEPROC destroy = dlsym(RTLD_NEXT, "eglDestroySurface");
      destroy(display, pending_surface);
      record("deferred_surface_destroy", pending_surface);
      pending_surface = EGL_NO_SURFACE;
   }
   current_surface = surface;
   surface_live = surface != EGL_NO_SURFACE;
   surface_sequence++;
   surface_swaps = 0;
   record("surface_create", surface);
   return surface;
}

static EGLContext create_context(EGLDisplay display, EGLConfig config,
      EGLContext share, const EGLint *attributes)
{
   PFNEGLCREATECONTEXTPROC real = dlsym(RTLD_NEXT, "eglCreateContext");
   EGLContext context = real(display, config, share, attributes);
   record("context_create", context);
   return context;
}

static EGLBoolean destroy_surface(EGLDisplay display, EGLSurface surface)
{
   if (!surface_live || surface != current_surface)
      record("surface_invalid", surface);
   /* Mesa 20.3 can reuse a freed pbuffer as a 1x1 drawable in a retained context.
    * Keep it until the replacement exists. EGL termination frees the last one. */
   pending_surface = surface;
   surface_live = 0;
   record("surface_destroy", surface);
   return EGL_TRUE;
}

static EGLBoolean make_current(EGLDisplay display, EGLSurface draw,
      EGLSurface read, EGLContext context)
{
   if (draw != EGL_NO_SURFACE && (!surface_live || draw != current_surface || read != current_surface))
      record("surface_invalid", draw);
   PFNEGLMAKECURRENTPROC real = dlsym(RTLD_NEXT, "eglMakeCurrent");
   EGLBoolean result = real(display, draw, read, context);
   static EGLContext previous;
   if (previous != context || !result)
      record(result ? "context_current" : "context_current_failed", context);
   previous = context;
   return result;
}

static EGLBoolean swap_buffers(EGLDisplay display, EGLSurface surface)
{
#define glGetIntegerv ((PFNGLGETINTEGERVPROC)eglGetProcAddress("glGetIntegerv"))
#define glBindFramebuffer ((PFNGLBINDFRAMEBUFFERPROC)eglGetProcAddress("glBindFramebuffer"))
#define glBindBuffer ((PFNGLBINDBUFFERPROC)eglGetProcAddress("glBindBuffer"))
#define glPixelStorei ((PFNGLPIXELSTOREIPROC)eglGetProcAddress("glPixelStorei"))
#define glReadPixels ((PFNGLREADPIXELSPROC)eglGetProcAddress("glReadPixels"))
#define glGetError ((PFNGLGETERRORPROC)eglGetProcAddress("glGetError"))
   if (!surface_live || surface != current_surface || eglGetCurrentContext() == EGL_NO_CONTEXT)
      record("surface_invalid", surface);
   if (surface_swaps < 3)
   {
      GLint previous;
      GLint pack_buffer, pack_alignment, pack_row_length, pack_skip_rows, pack_skip_pixels;
      EGLint width = 0, height = 0;
      if (!eglQuerySurface(display, surface, EGL_WIDTH, &width) ||
          !eglQuerySurface(display, surface, EGL_HEIGHT, &height) || width != 720 || height != 480)
      {
         record("read_failed", surface);
         return EGL_FALSE;
      }
      glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &previous);
      glGetIntegerv(GL_PIXEL_PACK_BUFFER_BINDING, &pack_buffer);
      glGetIntegerv(GL_PACK_ALIGNMENT, &pack_alignment);
      glGetIntegerv(GL_PACK_ROW_LENGTH, &pack_row_length);
      glGetIntegerv(GL_PACK_SKIP_ROWS, &pack_skip_rows);
      glGetIntegerv(GL_PACK_SKIP_PIXELS, &pack_skip_pixels);
      glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
      glPixelStorei(GL_PACK_ALIGNMENT, 1);
      glPixelStorei(GL_PACK_ROW_LENGTH, 0);
      glPixelStorei(GL_PACK_SKIP_ROWS, 0);
      glPixelStorei(GL_PACK_SKIP_PIXELS, 0);
      glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);
      unsigned char *pixels = malloc(720 * height * 4);
      memset(pixels, 0x5a, 720 * height * 4);
      glReadPixels(0, 0, 720, height, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
      GLenum read_error = glGetError();
      int count = 0, min_x = 720, min_y = height, max_x = -1, max_y = -1;
      int sentinel = 0;
      for (int y = 0; y < height; y++)
         for (int x = 0; x < 720; x++)
         {
            unsigned char *p = pixels + (y * 720 + x) * 4;
            if (p[0] == 0x5a && p[1] == 0x5a && p[2] == 0x5a && p[3] == 0x5a) sentinel++;
            if (abs(p[0] - 204) <= 1 && abs(p[1] - 51) <= 1 && abs(p[2] - 102) <= 1 && p[3] == 255)
            {
               count++;
               if (x < min_x) min_x = x;
               if (x > max_x) max_x = x;
               if (y < min_y) min_y = y;
               if (y > max_y) max_y = y;
            }
         }
      free(pixels);
      glBindFramebuffer(GL_READ_FRAMEBUFFER, previous);
      glBindBuffer(GL_PIXEL_PACK_BUFFER, pack_buffer);
      glPixelStorei(GL_PACK_ALIGNMENT, pack_alignment);
      glPixelStorei(GL_PACK_ROW_LENGTH, pack_row_length);
      glPixelStorei(GL_PACK_SKIP_ROWS, pack_skip_rows);
      glPixelStorei(GL_PACK_SKIP_PIXELS, pack_skip_pixels);
      FILE *file = fopen(getenv("SOCKET_EGL_TRACE"), "a");
      if (file)
      {
         fprintf(file, "%d window_pixels %d %d %d %d %d %d %d %d %u\n", getpid(),
               surface_sequence, surface_swaps + 1, count, min_x, min_y, max_x, max_y, sentinel, read_error);
         fclose(file);
      }
   }
   surface_swaps++;
   PFNEGLSWAPBUFFERSPROC real = dlsym(RTLD_NEXT, "eglSwapBuffers");
   EGLBoolean result = real(display, surface);
   if (!result) record("swap_failed", surface);
   return result;
}

int snd_pcm_open(snd_pcm_t **pcm, const char *name, snd_pcm_stream_t stream, int mode)
{
   int (*real)(snd_pcm_t **, const char *, snd_pcm_stream_t, int) =
      pcm_open_target ? pcm_open_target : dlsym(RTLD_NEXT, "snd_pcm_open");
   int result = real(pcm, name, stream, mode);
   record(result == 0 ? "audio_open" : "audio_open_failed", result == 0 ? *pcm : NULL);
   return result;
}

int snd_pcm_close(snd_pcm_t *pcm)
{
   int (*real)(snd_pcm_t *) = pcm_close_target ? pcm_close_target : dlsym(RTLD_NEXT, "snd_pcm_close");
   record("audio_close", pcm);
   return real(pcm);
}

/* GLAD resolves EGL from a local dlopen handle, which bypasses LD_PRELOAD. */
void *dlsym(void *handle, const char *name)
{
   void *(*real)(void *, const char *) = dlvsym(RTLD_NEXT, "dlsym", "GLIBC_2.17");
   if (handle != RTLD_NEXT)
   {
      if (strcmp(name, "eglChooseConfig") == 0) return eglChooseConfig;
      if (strcmp(name, "eglCreateWindowSurface") == 0) return create_window;
      if (strcmp(name, "eglCreateContext") == 0) return create_context;
      if (strcmp(name, "eglDestroySurface") == 0) return destroy_surface;
      if (strcmp(name, "eglMakeCurrent") == 0) return make_current;
      if (strcmp(name, "eglSwapBuffers") == 0) return swap_buffers;
      if (strcmp(name, "snd_pcm_open") == 0) { pcm_open_target = real(handle, name); return snd_pcm_open; }
      if (strcmp(name, "snd_pcm_close") == 0) { pcm_close_target = real(handle, name); return snd_pcm_close; }
   }
   return real(handle, name);
}

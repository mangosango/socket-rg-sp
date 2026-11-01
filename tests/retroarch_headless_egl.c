/* Use Mesa pbuffers for the Mali framebuffer in runtime tests. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdarg.h>
#include <string.h>
#include <sys/ioctl.h>
#include <linux/fb.h>
#include <EGL/egl.h>

int ioctl(int fd, unsigned long request, ...)
{
   va_list args;
   void *value;
   va_start(args, request);
   value = va_arg(args, void *);
   va_end(args);
   if (request == FBIOGET_VSCREENINFO)
   {
      struct fb_var_screeninfo *info = value;
      memset(info, 0, sizeof(*info));
      info->xres = 720;
      info->yres = 480;
      info->bits_per_pixel = 32;
      return 0;
   }
   int (*real_ioctl)(int, unsigned long, ...) = dlsym(RTLD_NEXT, "ioctl");
   return real_ioctl(fd, request, value);
}

EGLBoolean eglChooseConfig(EGLDisplay display, const EGLint *attributes,
      EGLConfig *configs, EGLint size, EGLint *count)
{
   EGLint copy[64];
   unsigned i = 0;
   for (; attributes[i] != EGL_NONE; i += 2)
   {
      copy[i] = attributes[i];
      copy[i + 1] = attributes[i] == EGL_SURFACE_TYPE ? EGL_PBUFFER_BIT : attributes[i + 1];
   }
   copy[i] = EGL_NONE;
   EGLBoolean (*choose)(EGLDisplay, const EGLint *, EGLConfig *, EGLint, EGLint *) =
      dlsym(RTLD_NEXT, "eglChooseConfig");
   return choose(display, copy, configs, size, count);
}

EGLSurface eglCreateWindowSurface(EGLDisplay display, EGLConfig config,
      EGLNativeWindowType window, const EGLint *attributes)
{
   const EGLint size[] = {EGL_WIDTH, 720, EGL_HEIGHT, 480, EGL_NONE};
   return eglCreatePbufferSurface(display, config, size);
}

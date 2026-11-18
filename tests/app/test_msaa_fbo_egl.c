/* Count framebuffer objects in the engine. Emulate tile MSAA where Mesa has none.
 * The engine then uses the render path of the Mali driver for the 3D MSAA view.
 * The emulation attaches the texture with one sample: the image has no MSAA,
 * but the framebuffer calls are the same.
 *
 * SOCKET_TILE_DISCARD=<depth> also emulates the depth loss that the extension
 * permits. When the engine leaves a tile MSAA framebuffer and binds it again,
 * the helper sets its depth to <depth>. The engine clears depth to 0 and tests
 * with GL_GEQUAL, so 0 is far and 1 is near. A real driver can keep any
 * content there. The counts file gets the number of draws that
 * used the lost depth. A frame that starts with a depth clear adds none. */
#define _GNU_SOURCE
#include <dlfcn.h>
/* Keep the EGL and audio replacements of the resident test. Add to its dlsym. */
void *resident_dlsym(void *handle, const char *name);
#define dlsym resident_dlsym
#include "test_resident_egl.c"
#undef dlsym

#define TILE_MSAA "GL_EXT_multisampled_render_to_texture2"
#define real(type, name) ((type)eglGetProcAddress(name))

static unsigned generated, deleted, attaches, swaps;
static GLint native_extensions = -1;
static int emulated;

/* Depth loss of the tile MSAA framebuffers. */
#define TILED_MAX 16
static GLuint tiled[TILED_MAX], draw_fbo;
static int pending[TILED_MAX], lost;
static unsigned lost_draws;

static int tiled_slot(GLuint name)
{
   for (int i = 0; i < TILED_MAX; i++)
      if (name != 0 && tiled[i] == name)
         return i;
   return -1;
}

static void gen_framebuffers(GLsizei count, GLuint *names)
{
   real(PFNGLGENFRAMEBUFFERSPROC, "glGenFramebuffers")(count, names);
   generated += count;
}

static void delete_framebuffers(GLsizei count, const GLuint *names)
{
   for (GLsizei i = 0; i < count; i++)
   {
      int slot = tiled_slot(names[i]);
      deleted += names[i] != 0;
      if (slot >= 0)
         tiled[slot] = pending[slot] = 0;
   }
   real(PFNGLDELETEFRAMEBUFFERSPROC, "glDeleteFramebuffers")(count, names);
}

static void framebuffer_texture_msaa(GLenum target, GLenum attachment, GLenum texture_target,
      GLuint texture, GLint level, GLsizei samples)
{
   void (*driver)(GLenum, GLenum, GLenum, GLuint, GLint, GLsizei) =
      emulated ? NULL : real(void (*)(GLenum, GLenum, GLenum, GLuint, GLint, GLsizei), "glFramebufferTexture2DMultisampleEXT");
   attaches++;
   if (target != GL_READ_FRAMEBUFFER && tiled_slot(draw_fbo) < 0)
      for (int i = 0; i < TILED_MAX; i++)
         if (tiled[i] == 0)
         {
            tiled[i] = draw_fbo;
            break;
         }
   if (driver)
      driver(target, attachment, texture_target, texture, level, samples);
   else
      real(PFNGLFRAMEBUFFERTEXTURE2DPROC, "glFramebufferTexture2D")(target, attachment, texture_target, texture, level);
}

static void bind_framebuffer(GLenum target, GLuint name)
{
   const char *depth = getenv("SOCKET_TILE_DISCARD");
   int slot;
   real(PFNGLBINDFRAMEBUFFERPROC, "glBindFramebuffer")(target, name);
   if (target == GL_READ_FRAMEBUFFER || name == draw_fbo)
      return;
   if ((slot = tiled_slot(draw_fbo)) >= 0)
      pending[slot] = 1;
   draw_fbo = name;
   lost = 0;
   if (!depth || (slot = tiled_slot(name)) < 0 || !pending[slot])
      return;
   GLboolean mask, scissor = real(PFNGLISENABLEDPROC, "glIsEnabled")(GL_SCISSOR_TEST);
   GLfloat clear;
   real(PFNGLGETBOOLEANVPROC, "glGetBooleanv")(GL_DEPTH_WRITEMASK, &mask);
   real(PFNGLGETFLOATVPROC, "glGetFloatv")(GL_DEPTH_CLEAR_VALUE, &clear);
   real(PFNGLDISABLEPROC, "glDisable")(GL_SCISSOR_TEST);
   real(PFNGLDEPTHMASKPROC, "glDepthMask")(GL_TRUE);
   real(PFNGLCLEARDEPTHFPROC, "glClearDepthf")(atof(depth));
   real(PFNGLCLEARPROC, "glClear")(GL_DEPTH_BUFFER_BIT);
   real(PFNGLCLEARDEPTHFPROC, "glClearDepthf")(clear);
   real(PFNGLDEPTHMASKPROC, "glDepthMask")(mask);
   if (scissor)
      real(PFNGLENABLEPROC, "glEnable")(GL_SCISSOR_TEST);
   pending[slot] = 0;
   lost = 1;
}

static void clear_buffers(GLbitfield mask)
{
   if (mask & GL_DEPTH_BUFFER_BIT)
      lost = 0;
   real(PFNGLCLEARPROC, "glClear")(mask);
}

static void clear_buffer_fv(GLenum buffer, GLint index, const GLfloat *value)
{
   if (buffer == GL_DEPTH)
      lost = 0;
   real(PFNGLCLEARBUFFERFVPROC, "glClearBufferfv")(buffer, index, value);
}

static void clear_buffer_fi(GLenum buffer, GLint index, GLfloat depth, GLint stencil)
{
   lost = 0;
   real(PFNGLCLEARBUFFERFIPROC, "glClearBufferfi")(buffer, index, depth, stencil);
}

static void draw_elements(GLenum mode, GLsizei count, GLenum type, const void *indices)
{
   lost_draws += lost;
   real(PFNGLDRAWELEMENTSPROC, "glDrawElements")(mode, count, type, indices);
}

static void draw_arrays(GLenum mode, GLint first, GLsizei count)
{
   lost_draws += lost;
   real(PFNGLDRAWARRAYSPROC, "glDrawArrays")(mode, first, count);
}

static void draw_elements_instanced(GLenum mode, GLsizei count, GLenum type, const void *indices, GLsizei instances)
{
   lost_draws += lost;
   real(PFNGLDRAWELEMENTSINSTANCEDPROC, "glDrawElementsInstanced")(mode, count, type, indices, instances);
}

static void draw_arrays_instanced(GLenum mode, GLint first, GLsizei count, GLsizei instances)
{
   lost_draws += lost;
   real(PFNGLDRAWARRAYSINSTANCEDPROC, "glDrawArraysInstanced")(mode, first, count, instances);
}

static void find_extension(void)
{
   if (native_extensions >= 0)
      return;
   real(PFNGLGETINTEGERVPROC, "glGetIntegerv")(GL_NUM_EXTENSIONS, &native_extensions);
   emulated = 1;
   for (GLint i = 0; i < native_extensions; i++)
      if (strcmp((const char *)real(PFNGLGETSTRINGIPROC, "glGetStringi")(GL_EXTENSIONS, i), TILE_MSAA) == 0)
         emulated = 0;
}

static void get_integer(GLenum name, GLint *value)
{
   real(PFNGLGETINTEGERVPROC, "glGetIntegerv")(name, value);
   if (name != GL_NUM_EXTENSIONS && name != GL_MAX_SAMPLES)
      return;
   find_extension();
   if (name == GL_NUM_EXTENSIONS)
      *value = native_extensions + emulated;
   else if (emulated && *value < 2)
      *value = 2;
}

static const GLubyte *get_string_i(GLenum name, GLuint index)
{
   find_extension();
   if (name == GL_EXTENSIONS && emulated && index == (GLuint)native_extensions)
      return (const GLubyte *)TILE_MSAA;
   return real(PFNGLGETSTRINGIPROC, "glGetStringi")(name, index);
}

/* The test script reads this file between frames. */
static EGLBoolean count_swap(EGLDisplay display, EGLSurface surface)
{
   const char *path = getenv("SOCKET_FBO_COUNTS");
   FILE *file = path ? fopen(path, "w") : NULL;
   swaps++;
   if (file)
   {
      fprintf(file, "%u %u %u %u %d %u\n", generated, deleted, attaches, swaps, emulated, lost_draws);
      fclose(file);
   }
   return swap_buffers(display, surface);
}

static void *replacement(const char *name)
{
   if (strcmp(name, "glGenFramebuffers") == 0) return gen_framebuffers;
   if (strcmp(name, "glDeleteFramebuffers") == 0) return delete_framebuffers;
   if (strcmp(name, "glFramebufferTexture2DMultisampleEXT") == 0) return framebuffer_texture_msaa;
   if (strcmp(name, "glBindFramebuffer") == 0) return bind_framebuffer;
   if (strcmp(name, "glClear") == 0) return clear_buffers;
   if (strcmp(name, "glClearBufferfv") == 0) return clear_buffer_fv;
   if (strcmp(name, "glClearBufferfi") == 0) return clear_buffer_fi;
   if (strcmp(name, "glDrawElements") == 0) return draw_elements;
   if (strcmp(name, "glDrawArrays") == 0) return draw_arrays;
   if (strcmp(name, "glDrawElementsInstanced") == 0) return draw_elements_instanced;
   if (strcmp(name, "glDrawArraysInstanced") == 0) return draw_arrays_instanced;
   if (strcmp(name, "glGetIntegerv") == 0) return get_integer;
   if (strcmp(name, "glGetStringi") == 0) return get_string_i;
   return NULL;
}

/* The engine loads its GL entry points through this function. */
static __eglMustCastToProperFunctionPointerType get_proc(const char *name)
{
   void *function = replacement(name);
   return function ? (__eglMustCastToProperFunctionPointerType)function : eglGetProcAddress(name);
}

void *dlsym(void *handle, const char *name)
{
   if (handle != RTLD_NEXT)
   {
      if (strcmp(name, "eglGetProcAddress") == 0) return get_proc;
      if (strcmp(name, "eglSwapBuffers") == 0) return count_swap;
      if (replacement(name)) return replacement(name);
   }
   return resident_dlsym(handle, name);
}

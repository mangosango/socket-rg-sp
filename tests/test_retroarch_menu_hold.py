"""Compile the patched RetroArch paths with controlled input and file errors."""

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "work/RetroArch"


def function(source, signature):
    start = source.index(signature)
    return source[start:source.index("\n}\n", start) + 3]


@unittest.skipUnless((SOURCE / "runloop.c").exists() and shutil.which("cc"),
                     "Build the RetroArch source checkout and install a C compiler")
class MenuHoldTests(unittest.TestCase):
    def test_tap_hold_save_order_and_failures(self):
        runloop = (SOURCE / "runloop.c").read_text()
        start = runloop.index("   /* Check menu hotkey */")
        menu = runloop[start:runloop.index("\n#endif", start)]
        save = function((SOURCE / "tasks/task_save.c").read_text(),
                        "bool content_auto_save_state(const char *path)")
        command = function((SOURCE / "command.c").read_text(),
                           "size_t command_event_save_auto_state(void)")
        harness = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#undef strlcpy
#undef strlcat
#define strlcpy test_strlcpy
#define strlcat test_strlcat
#define HAVE_ZLIB 1
#define PATH_MAX_LENGTH 256
#define RETRO_VFS_FILE_ACCESS_WRITE 1
#define RETRO_VFS_FILE_ACCESS_HINT_NONE 0
#define RARCH_LOG(...) ((void)0)
#define RARCH_PATH_BASENAME 0
#define BIT256_GET(bits, key) (bits)
#define RARCH_MENU_TOGGLE 0
#define CORE_TYPE_DUMMY 0
#define RUNLOOP_FLAG_CORE_RUNNING 1
#define MENU_ST_FLAG_ALIVE 1
#define CMD_EVENT_QUIT 0
#define MESSAGE_QUEUE_ICON_DEFAULT 0
#define MESSAGE_QUEUE_CATEGORY_WARNING 0
#define string_is_equal(a,b) (!strcmp(a,b))
#define string_is_empty(s) (!(s)[0])
typedef int64_t retro_time_t;
typedef struct { struct { char menu_driver[16]; } arrays; struct { bool savestate_file_compression; } bools; } settings_t;
typedef struct { struct { char savestate[1024]; } name; int current_core_type, flags; } runloop_state_t;
typedef struct { FILE *file; } intfstream_t;
static settings_t settings_data = { { "rgui" } };
static runloop_state_t runloop_data = { { "game.state" }, 1, 1 };
#define INP_FLAG_MENU_PRESS_PENDING 1
#define INP_FLAG_MENU_PRESS_CANCEL 2
static struct { int flags, input_driver_flushing_input; } menu_data;
static struct { int flags; } input_data;
static struct { bool failed; } socket_sleep;
static int failure, saves, quits, warnings, waited, supports = 1;
static size_t strlcpy(char *out, const char *in, size_t size) {
 size_t len = strlen(in); if (size) { size_t n = len < size-1 ? len : size-1; memcpy(out,in,n); out[n]=0; } return len;
}
static size_t strlcat(char *out, const char *in, size_t size) {
 size_t len = strlen(out); return len + strlcpy(out+len,in,size-len);
}
static settings_t *config_get_ptr(void) { return &settings_data; }
static runloop_state_t *runloop_state_get_ptr(void) { return &runloop_data; }
static bool core_info_current_supports_savestate(void) { return supports; }
static size_t core_serialize_size(void) { return failure == 5 ? 0 : 9; }
static void *content_get_serialized_data(size_t *len) {
 void *p; assert(*len == 9); if (failure == 6) return NULL;
 p = malloc(9); memcpy(p,"new-state",9); return p;
}
static intfstream_t *intfstream_open_file(const char *path, int mode, int hint) {
 intfstream_t *s; (void)mode; (void)hint; assert(waited); saves++;
 if (failure == 1) return NULL;
 s=malloc(sizeof(*s)); s->file=fopen(path,"wb"); assert(s->file); return s;
}
static intfstream_t *intfstream_open_rzip_file(const char *path, int mode) {
 return intfstream_open_file(path, mode, 0);
}
static size_t intfstream_write(intfstream_t *s, const void *data, size_t len) {
 if (failure == 2) len--; return fwrite(data,1,len,s->file);
}
static int intfstream_close(intfstream_t *s) {
 int result=fclose(s->file); return failure == 3 ? -1 : result;
}
static int filestream_rename(const char *old, const char *new) {
 return failure == 4 ? -1 : rename(old,new);
}
static int filestream_delete(const char *path) { return unlink(path); }
static const char *path_get(int key) { (void)key; return "game.rom"; }
static const char *path_basename(const char *path) { return path; }
static void assert_state(const char *expected) {
 char data[32]={0}; FILE *f=fopen("game.state.auto","rb"); assert(f);
 assert(fread(data,1,sizeof(data),f)==strlen(expected)); fclose(f); assert(!strcmp(data,expected));
}
static bool command_event(int event, void *data) {
 (void)event; (void)data; assert_state("new-state"); assert(waited); quits++; return true;
}
static void content_wait_for_save_state_task(void) { waited++; }
static void runloop_msg_queue_push(const char *msg, size_t len, int priority,
 int duration, bool flush, void *title, int icon, int category) {
 (void)msg;(void)len;(void)priority;(void)duration;(void)flush;(void)title;(void)icon;(void)category; warnings++;
}
static void retroarch_menu_running(void) { menu_data.flags=1; }
static void retroarch_menu_running_finished(bool x) { (void)x; menu_data.flags=0; }
'''
        harness += save + command
        harness += '''
static void tick(bool current_bits, retro_time_t current_time) {
 settings_t *settings=&settings_data;
 runloop_state_t *runloop_st=&runloop_data;
 typeof(menu_data) *menu_st=&menu_data;
 typeof(input_data) *input_st=&input_data;
 bool rarch_is_initialized=true, menu_driver_binding_state=false;
 if (current_bits) {
  if (!(input_st->flags & INP_FLAG_MENU_PRESS_PENDING)) input_st->flags=INP_FLAG_MENU_PRESS_PENDING;
  current_bits=false;
 } else {
  current_bits=(input_st->flags & INP_FLAG_MENU_PRESS_PENDING) && !(input_st->flags & INP_FLAG_MENU_PRESS_CANCEL);
  input_st->flags=0;
 }
''' + menu + "\n}\n"
        harness += r'''
int main(void) {
 FILE *f; int i; retro_time_t now=100;
 /* A tap toggles only on release. */
 tick(true,now); assert(!menu_data.flags); tick(true,now+999999); assert(!menu_data.flags);
 tick(false,now+999999); assert(menu_data.flags); assert(!saves && !quits);
 now+=2000000; tick(true,now); tick(false,now+100); assert(!menu_data.flags);
 /* Each failed save preserves the old file and permits a later tap. */
 for (i=1;i<=6;i++) {
  f=fopen("game.state.auto","wb"); assert(f); fputs("old-state",f); fclose(f);
  settings_data.bools.savestate_file_compression = (i % 2) != 0;
  failure=i; now+=2000000; tick(true,now); tick(true,now+1000000);
  assert(!quits); assert(warnings==i); assert_state("old-state");
  { int previous=saves; tick(true,now+3000000); assert(saves==previous); }
  tick(false,now+3000001); assert(!menu_data.flags);
  assert(access("game.state.auto.tmp",F_OK)!=0);
  now+=4000000; tick(true,now); tick(false,now+1); assert(menu_data.flags);
  now+=10; tick(true,now); tick(false,now+1); assert(!menu_data.flags);
 }
 failure=0; supports=0; assert(!command_event_save_auto_state()); supports=1;
 memset(runloop_data.name.savestate,'x',sizeof(runloop_data.name.savestate)-1);
 assert(!command_event_save_auto_state());
 memset(runloop_data.name.savestate,'x',253); runloop_data.name.savestate[253]=0;
 assert(!command_event_save_auto_state());
 strcpy(runloop_data.name.savestate,"game.state");
 now+=2000000; tick(true,now); tick(true,now+999999); assert(!quits);
 tick(true,now+1000000); assert(quits==1); assert_state("new-state");
 tick(true,now+2000000); tick(false,now+2000001); assert(quits==1 && !menu_data.flags);
 /* A failed boot restore exits without saving over a good automatic state. */
 socket_sleep.failed=true;
 { int previous=saves; now+=3000000; tick(true,now); tick(true,now+1000000);
   tick(false,now+1000001); assert(quits==2 && saves==previous); }
 socket_sleep.failed=false;
 /* Holding MENU without a game cannot save or quit. */
 runloop_data.current_core_type=CORE_TYPE_DUMMY;
 now+=3000000; tick(true,now); tick(true,now+1000000); tick(false,now+1000001);
 assert(quits==2);
 return 0;
}
'''
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "test.c"
            binary = Path(directory) / "test"
            source.write_text(harness)
            result = subprocess.run(["cc", "-std=gnu99", "-Wall", "-Werror", str(source), "-o", str(binary)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(binary)], cwd=directory, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()

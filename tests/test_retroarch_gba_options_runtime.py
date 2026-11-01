"""Check the GBA core options and audio status that ARM64 RetroArch gives a core."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

CORE = r'''
#include <libretro.h>
#include <stdio.h>
#include <string.h>
static retro_environment_t environment;
static retro_video_refresh_t video;
static retro_audio_sample_batch_t audio;
static unsigned frames, active, underruns, low = 100, high;
static void status(bool on, unsigned occupancy, bool underrun) {
   if (!on) return;
   active++; underruns += underrun;
   if (occupancy < low) low = occupancy;
   if (occupancy > high) high = occupancy;
}
void retro_set_environment(retro_environment_t cb) { environment = cb; }
void retro_set_video_refresh(retro_video_refresh_t cb) { video = cb; }
void retro_set_audio_sample_batch(retro_audio_sample_batch_t cb) { audio = cb; }
void retro_set_audio_sample(retro_audio_sample_t cb) { (void)cb; }
void retro_set_input_poll(retro_input_poll_t cb) { (void)cb; }
void retro_set_input_state(retro_input_state_t cb) { (void)cb; }
void retro_init(void) {
   static struct retro_variable options[] = {
      {"mgba_frameskip", "Frameskip; disabled|auto|auto_threshold|fixed_interval"},
      {"mgba_color_correction", "Color correction; OFF|GBA|GBC|Auto"},
      {"mgba_interframe_blending", "Blending; OFF|mix"},
      {"mgba_force_gbp", "Force GBP; OFF|ON"}, {NULL, NULL}};
   environment(RETRO_ENVIRONMENT_SET_VARIABLES, options);
}
void retro_deinit(void) {}
unsigned retro_api_version(void) { return RETRO_API_VERSION; }
void retro_get_system_info(struct retro_system_info *info) {
   memset(info, 0, sizeof(*info));
   info->library_name = "mGBA"; info->library_version = "probe"; info->valid_extensions = "gba";
}
void retro_get_system_av_info(struct retro_system_av_info *info) {
   memset(info, 0, sizeof(*info));
   info->geometry.base_width = info->geometry.max_width = 240;
   info->geometry.base_height = info->geometry.max_height = 160;
   info->geometry.aspect_ratio = 1.5;
   info->timing.fps = 59.7275;
   info->timing.sample_rate = 65536;
}
bool retro_load_game(const struct retro_game_info *game) {
   enum retro_pixel_format format = RETRO_PIXEL_FORMAT_XRGB8888;
   struct retro_audio_buffer_status_callback callback = { status };
   (void)game;
   environment(RETRO_ENVIRONMENT_SET_AUDIO_BUFFER_STATUS_CALLBACK, &callback);
   return environment(RETRO_ENVIRONMENT_SET_PIXEL_FORMAT, &format);
}
void retro_run(void) {
   static uint32_t pixels[240 * 160];
   static int16_t samples[2 * 1100];
   const char *keys[] = {"mgba_frameskip", "mgba_color_correction", "mgba_interframe_blending", "mgba_force_gbp"};
   unsigned i;
   FILE *file;
   video(pixels, 240, 160, 240 * 4);
   audio(samples, 1097);
   if (++frames % 30) return;
   file = fopen("/output/seen.json.tmp", "w");
   fprintf(file, "{\"frames\":%u,\"active\":%u,\"underruns\":%u,\"low\":%u,\"high\":%u", frames, active, underruns, low, high);
   for (i = 0; i < 4; i++) {
      struct retro_variable variable = {keys[i], NULL};
      environment(RETRO_ENVIRONMENT_GET_VARIABLE, &variable);
      fprintf(file, ",\"%s\":\"%s\"", keys[i], variable.value ? variable.value : "");
   }
   fprintf(file, "}");
   fclose(file);
   rename("/output/seen.json.tmp", "/output/seen.json");
}
void retro_reset(void) {}
void retro_unload_game(void) {}
size_t retro_serialize_size(void) { return 0; }
bool retro_serialize(void *p, size_t n) { (void)p; (void)n; return false; }
bool retro_unserialize(const void *p, size_t n) { (void)p; (void)n; return false; }
void retro_cheat_reset(void) {}
void retro_cheat_set(unsigned i, bool b, const char *c) { (void)i; (void)b; (void)c; }
unsigned retro_get_region(void) { return RETRO_REGION_NTSC; }
void *retro_get_memory_data(unsigned id) { (void)id; return 0; }
size_t retro_get_memory_size(unsigned id) { (void)id; return 0; }
bool retro_load_game_special(unsigned id, const struct retro_game_info *g, size_t n) { (void)id; (void)g; (void)n; return false; }
void retro_set_controller_port_device(unsigned port, unsigned device) { (void)port; (void)device; }
'''

# Install the card files. Put device overrides first: RetroArch keeps the first key.
SCRIPT = r'''set -eu
cc -shared -fPIC /project/tests/retroarch_headless_egl.c -o /output/headless.so -ldl -lEGL
cc -shared -fPIC -I/project/work/RetroArch/libretro-common/include /output/core.c -o /output/core.so
system=/mnt/sdcard/System/socket
mkdir -p $system/cores
cp -R /project/card/System/socket/retroarch $system/retroarch
cp /output/core.so $system/cores/mgba_libretro.so
ln -s /project/work/RetroArch/retroarch $system/retroarch/retroarch
{ cat /output/overrides.cfg; cat /project/card/System/socket/retroarch/retroarch.cfg; } > $system/retroarch/retroarch.cfg
sed 's|"$SYS/retroarch/retroarch"|"$SYS/retroarch/retroarch" --max-frames 300|' \
	/project/card/System/socket/launch_game.sh > $system/launch_game.sh
SOCKET_RUN=/output SOCKET_RESUME_MANIFEST=/output/resume-game EGL_PLATFORM=surfaceless \
	LD_PRELOAD=/output/headless.so sh $system/launch_game.sh mgba /output/probe.gba gba > /output/runtime.log 2>&1
cp /output/retroarch-core-options.cfg /output/effective-options.cfg
'''


@unittest.skipUnless(os.environ.get('RETROARCH_GBA_OPTIONS_SMOKE') == '1',
                     'Set RETROARCH_GBA_OPTIONS_SMOKE=1 for ARM64 runtime tests')
class GbaOptionsRuntimeTests(unittest.TestCase):
    def test_card_options_reach_the_core_with_audio_status(self):
        with tempfile.TemporaryDirectory(prefix='ra-gba-options-') as directory:
            output = Path(directory)
            (output/'core.c').write_text(CORE)
            rom = bytearray(400)
            rom[172] = 77  # A non-Boktai game code keeps the Game Boy Player option off.
            (output/'probe.gba').write_bytes(rom)
            (output/'overrides.cfg').write_text(''.join(f'{k} = "{v}"\n' for k, v in {
                'video_context_driver': 'mali-fbdev', 'audio_device': 'null',
                'input_driver': 'null', 'input_joypad_driver': 'null',
                'savefile_directory': '/output', 'savestate_directory': '/output'}.items()))
            result = subprocess.run(['docker', 'run', '--rm', '--platform', 'linux/arm64',
                '-v', f'{ROOT}:/project:ro', '-v', f'{output}:/output', 'socket-baseos-godot',
                'sh', '-c', SCRIPT], capture_output=True, text=True, timeout=120)
            log = (output/'runtime.log').read_text() if (output/'runtime.log').exists() else ''
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr + log)
            seen = json.loads((output/'seen.json').read_text())
            self.assertEqual(seen['mgba_frameskip'], 'auto', seen)
            self.assertEqual(seen['mgba_color_correction'], 'Auto', seen)
            self.assertEqual(seen['mgba_interframe_blending'], 'OFF', seen)
            self.assertEqual(seen['mgba_force_gbp'], 'OFF', seen)
            # RetroArch must report ALSA buffer status, or "auto" never skips.
            self.assertGreater(seen['active'], 200, seen)
            self.assertIn('SET_AUDIO_BUFFER_STATUS_CALLBACK', log)
            print(json.dumps(seen))


if __name__ == '__main__':
    unittest.main()

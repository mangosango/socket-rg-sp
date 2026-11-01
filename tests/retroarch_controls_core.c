/* Deterministic video and audio for the real RetroArch runtime test. */
#include <libretro.h>
#include <string.h>
#include <unistd.h>
static retro_environment_t environment;
static retro_video_refresh_t video;
static retro_audio_sample_batch_t audio;
void retro_set_environment(retro_environment_t cb) { environment = cb; }
void retro_set_video_refresh(retro_video_refresh_t cb) { video = cb; }
void retro_set_audio_sample_batch(retro_audio_sample_batch_t cb) { audio = cb; }
void retro_set_audio_sample(retro_audio_sample_t cb) { (void)cb; }
void retro_set_input_poll(retro_input_poll_t cb) { (void)cb; }
void retro_set_input_state(retro_input_state_t cb) { (void)cb; }
void retro_init(void) { bool yes = true; environment(RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME, &yes); }
void retro_deinit(void) {}
unsigned retro_api_version(void) { return RETRO_API_VERSION; }
void retro_get_system_info(struct retro_system_info *info)
{
   memset(info, 0, sizeof(*info));
   info->library_name = "Socket controls probe";
   info->library_version = "1";
   info->valid_extensions = "bin";
}
void retro_get_system_av_info(struct retro_system_av_info *info)
{
   memset(info, 0, sizeof(*info));
   info->geometry.base_width = info->geometry.max_width = 720;
   info->geometry.base_height = info->geometry.max_height = 480;
   info->geometry.aspect_ratio = 1.5;
   info->timing.fps = 60;
   info->timing.sample_rate = 48000;
}
bool retro_load_game(const struct retro_game_info *game)
{
   enum retro_pixel_format format = RETRO_PIXEL_FORMAT_XRGB8888;
   (void)game;
   return environment(RETRO_ENVIRONMENT_SET_PIXEL_FORMAT, &format);
}
void retro_run(void)
{
   static uint32_t pixels[720 * 480];
   static int16_t samples[1600];
   unsigned i;
   for (i = 0; i < 720 * 480; i++) pixels[i] = 0x64788c;
   for (i = 0; i < 1600; i++) samples[i] = 16384;
   video(pixels, 720, 480, 720 * 4);
   audio(samples, 800);
   usleep(16000);
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
bool retro_load_game_special(unsigned id, const struct retro_game_info *g, size_t n)
{ (void)id; (void)g; (void)n; return false; }
void retro_set_controller_port_device(unsigned port, unsigned device) { (void)port; (void)device; }

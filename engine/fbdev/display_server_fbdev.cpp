/**************************************************************************/
/*  display_server_fbdev.cpp                                              */
/**************************************************************************/

#include "display_server_fbdev.h"

#ifdef FBDEV_ENABLED

#include "core/input/input.h"
#include "core/os/os.h"
#include "drivers/gles3/rasterizer_gles3.h"
#include "servers/audio/audio_server.h"
#include "servers/rendering/rendering_server.h"

#include <fcntl.h>
#include <linux/fb.h>
#include <linux/input.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define EGL_OPENGL_ES3_BIT_KHR 0x40

// H700 gamepad key codes, as mapped by slot (crates/slot/src/input/evdev.rs).
// Godot buttons follow the printed labels, like Socket on Anbernic Android.
static const struct {
	uint16_t code;
	JoyButton button;
} pad_buttons[] = {
	{ 0x130, JoyButton::A },
	{ 0x131, JoyButton::B },
	{ 0x132, JoyButton::Y },
	{ 0x133, JoyButton::X },
	{ 0x134, JoyButton::LEFT_SHOULDER },
	{ 0x135, JoyButton::RIGHT_SHOULDER },
	{ 0x136, JoyButton::BACK },
	{ 0x137, JoyButton::START },
	{ 0x138, JoyButton::GUIDE },
	{ 0x2c0, JoyButton::PADDLE1 },
	{ 0x2c1, JoyButton::PADDLE2 },
};
static const uint16_t PAD_L2 = 0x13a;
static const uint16_t PAD_R2 = 0x13b;
// slot reads the left stick from these axes.
static const uint16_t PAD_LSX = ABS_Z;
static const uint16_t PAD_LSY = ABS_RX;

static bool test_bit(const unsigned long *p_bits, int p_bit) {
	const int width = sizeof(unsigned long) * 8;
	return (p_bits[p_bit / width] >> (p_bit % width)) & 1UL;
}

Vector<String> DisplayServerFbdev::get_rendering_drivers_func() {
	Vector<String> drivers;
	drivers.push_back("opengl3_es");
	return drivers;
}

DisplayServer *DisplayServerFbdev::create_func(const String &p_rendering_driver, DisplayServerEnums::WindowMode p_mode, DisplayServerEnums::VSyncMode p_vsync_mode, uint32_t p_flags, const Vector2i *p_position, const Vector2i &p_resolution, int p_screen, DisplayServerEnums::Context p_context, int64_t p_parent_window, Error &r_error) {
	DisplayServer *ds = memnew(DisplayServerFbdev(p_vsync_mode, r_error));
	if (r_error != OK) {
		OS::get_singleton()->alert("Could not start OpenGL ES 3.0 on the Mali fbdev driver.", "Unable to initialize video driver");
	}
	return ds;
}

void DisplayServerFbdev::register_fbdev_driver() {
	register_create_function("fbdev", create_func, get_rendering_drivers_func);
}

Error DisplayServerFbdev::_init_egl() {
	struct fb_var_screeninfo info = {};
	int fb = open("/dev/fb0", O_RDONLY | O_CLOEXEC);
	ERR_FAIL_COND_V_MSG(fb < 0, ERR_CANT_OPEN, "fbdev: cannot open /dev/fb0.");
	int rc = ioctl(fb, FBIOGET_VSCREENINFO, &info);
	close(fb);
	ERR_FAIL_COND_V_MSG(rc != 0 || info.xres == 0 || info.yres == 0, ERR_CANT_OPEN, "fbdev: FBIOGET_VSCREENINFO failed.");
	native_window.width = info.xres;
	native_window.height = info.yres;

	ERR_FAIL_COND_V_MSG(!gladLoaderLoadEGL(EGL_NO_DISPLAY), ERR_CANT_CREATE, "fbdev: cannot load libEGL.");
	egl_display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
	ERR_FAIL_COND_V_MSG(egl_display == EGL_NO_DISPLAY, ERR_CANT_CREATE, "fbdev: eglGetDisplay failed.");
	ERR_FAIL_COND_V_MSG(!eglInitialize(egl_display, nullptr, nullptr), ERR_CANT_CREATE, "fbdev: eglInitialize failed.");
	// Load the entry points that need an initialized display.
	gladLoaderLoadEGL(egl_display);
	ERR_FAIL_COND_V_MSG(!eglBindAPI(EGL_OPENGL_ES_API), ERR_CANT_CREATE, "fbdev: eglBindAPI failed.");

	const EGLint config_attribs[] = {
		EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
		EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT_KHR,
		EGL_RED_SIZE, 8,
		EGL_GREEN_SIZE, 8,
		EGL_BLUE_SIZE, 8,
		EGL_DEPTH_SIZE, 24,
		EGL_NONE
	};
	EGLConfig config = nullptr;
	EGLint found = 0;
	ERR_FAIL_COND_V_MSG(!eglChooseConfig(egl_display, config_attribs, &config, 1, &found) || found == 0, ERR_CANT_CREATE, "fbdev: no GLES3 window config with RGB888 and 24-bit depth.");
	egl_config = config;

	egl_surface = eglCreateWindowSurface(egl_display, config, (EGLNativeWindowType)&native_window, nullptr);
	ERR_FAIL_COND_V_MSG(egl_surface == EGL_NO_SURFACE, ERR_CANT_CREATE, vformat("fbdev: eglCreateWindowSurface failed: 0x%x.", eglGetError()));

	const EGLint context_attribs[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
	egl_context = eglCreateContext(egl_display, config, EGL_NO_CONTEXT, context_attribs);
	ERR_FAIL_COND_V_MSG(egl_context == EGL_NO_CONTEXT, ERR_CANT_CREATE, vformat("fbdev: eglCreateContext (GLES 3) failed: 0x%x.", eglGetError()));
	ERR_FAIL_COND_V_MSG(!eglMakeCurrent(egl_display, egl_surface, egl_surface, egl_context), ERR_CANT_CREATE, "fbdev: eglMakeCurrent failed.");

	EGLint w = 0, h = 0;
	eglQuerySurface(egl_display, egl_surface, EGL_WIDTH, &w);
	eglQuerySurface(egl_display, egl_surface, EGL_HEIGHT, &h);
	size = (w > 0 && h > 0) ? Size2i(w, h) : Size2i(info.xres, info.yres);
	print_line(vformat("fbdev: %dx%d panel, %s", size.width, size.height, String::utf8(eglQueryString(egl_display, EGL_VENDOR))));
	return OK;
}

void DisplayServerFbdev::_open_inputs() {
	for (int i = 0; i < 32; i++) {
		int fd = open(vformat("/dev/input/event%d", i).utf8().get_data(), O_RDONLY | O_NONBLOCK | O_CLOEXEC);
		if (fd < 0) {
			continue;
		}
		unsigned long keys[KEY_MAX / (sizeof(unsigned long) * 8) + 1] = {};
		ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(keys)), keys);
		char name[128] = {};
		ioctl(fd, EVIOCGNAME(sizeof(name)), name);
		bool is_pad = test_bit(keys, pad_buttons[0].code);
		if (!is_pad || String::utf8(name) != "Socket H700 Gamepad") {
			close(fd);
			continue;
		}
		Pad pad;
		pad.fd = fd;
		const uint16_t axes[2] = { PAD_LSX, PAD_LSY };
		for (int a = 0; a < 2; a++) {
			struct input_absinfo abs = {};
			if (ioctl(fd, EVIOCGABS(axes[a]), &abs) == 0 && abs.maximum > abs.minimum) {
				pad.abs_min[a] = abs.minimum;
				pad.abs_max[a] = abs.maximum;
			}
		}
		inputs.push_back(pad);
		if (is_pad && !joy_connected) {
			Dictionary info;
			info["mapping_handled"] = true;
			Input::get_singleton()->joy_connection_changed(0, true, "H700 Gamepad", "", info);
			joy_connected = true;
		}
	}
}

void DisplayServerFbdev::_read_input(Pad &p_pad) {
	Input *input = Input::get_singleton();
	struct input_event ev;
	while (read(p_pad.fd, &ev, sizeof(ev)) == sizeof(ev)) {
		if (ev.type == EV_KEY) {
			if (ev.value > 1) {
				continue; // Key repeat.
			}
			if (ev.code == PAD_L2 || ev.code == PAD_R2) {
				input->joy_axis(0, ev.code == PAD_L2 ? JoyAxis::TRIGGER_LEFT : JoyAxis::TRIGGER_RIGHT, ev.value ? 1.0 : 0.0);
				continue;
			}
			for (const auto &b : pad_buttons) {
				if (b.code == ev.code) {
					input->joy_button(0, b.button, ev.value != 0);
				}
			}
		} else if (ev.type == EV_ABS) {
			if (ev.code == ABS_HAT0X || ev.code == ABS_HAT0Y) {
				hat[ev.code - ABS_HAT0X] = SIGN(ev.value);
				BitField<HatMask> mask = HatMask::CENTER;
				mask.set_flag(hat[0] < 0 ? HatMask::LEFT : hat[0] > 0 ? HatMask::RIGHT : HatMask::CENTER);
				mask.set_flag(hat[1] < 0 ? HatMask::UP : hat[1] > 0 ? HatMask::DOWN : HatMask::CENTER);
				input->joy_hat(0, mask);
			} else if (ev.code == PAD_LSX || ev.code == PAD_LSY) {
				int a = ev.code == PAD_LSX ? 0 : 1;
				float v = (ev.value - p_pad.abs_min[a]) / (p_pad.abs_max[a] - p_pad.abs_min[a]) * 2.0f - 1.0f;
				input->joy_axis(0, a == 0 ? JoyAxis::LEFT_X : JoyAxis::LEFT_Y, CLAMP(v, -1.0f, 1.0f));
			}
		}
	}
}

Vector<DisplayServerEnums::WindowID> DisplayServerFbdev::get_window_list() const {
	Vector<DisplayServerEnums::WindowID> list;
	list.push_back(DisplayServerEnums::MAIN_WINDOW_ID);
	return list;
}

void DisplayServerFbdev::window_set_vsync_mode(DisplayServerEnums::VSyncMode p_vsync_mode, DisplayServerEnums::WindowID p_window) {
	vsync_mode = p_vsync_mode;
	eglSwapInterval(egl_display, p_vsync_mode == DisplayServerEnums::VSYNC_DISABLED ? 0 : 1);
}

void DisplayServerFbdev::process_events() {
	for (Pad &pad : inputs) {
		_read_input(pad);
	}
	Input::get_singleton()->flush_buffered_events();
}

void DisplayServerFbdev::window_set_mode(DisplayServerEnums::WindowMode p_mode, DisplayServerEnums::WindowID p_window) {
	bool suspend = p_mode == DisplayServerEnums::WINDOW_MODE_MINIMIZED;
	if (suspend == minimized) {
		return;
	}
	// The launcher uses the Safe render mode, so EGL stays on this thread.
	RenderingServer::get_singleton()->sync();
	if (suspend) {
		ERR_FAIL_COND_MSG(!eglMakeCurrent(egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT), "fbdev: cannot release the display for the game.");
		if (!eglDestroySurface(egl_display, egl_surface)) {
			eglMakeCurrent(egl_display, egl_surface, egl_surface, egl_context);
			ERR_FAIL_MSG("fbdev: cannot release the window surface.");
		}
		egl_surface = EGL_NO_SURFACE;
		AudioDriver::get_singleton()->finish();
		for (Pad &pad : inputs) {
			close(pad.fd);
		}
		inputs.clear();
		Input *input = Input::get_singleton();
		for (const auto &button : pad_buttons) {
			input->joy_button(0, button.button, false);
		}
		input->joy_hat(0, HatMask::CENTER);
		input->joy_axis(0, JoyAxis::TRIGGER_LEFT, 0);
		input->joy_axis(0, JoyAxis::TRIGGER_RIGHT, 0);
		input->joy_axis(0, JoyAxis::LEFT_X, 0);
		input->joy_axis(0, JoyAxis::LEFT_Y, 0);
		hat[0] = hat[1] = 0;
		input->flush_buffered_events();
		minimized = true;
	} else {
		egl_surface = eglCreateWindowSurface(egl_display, egl_config, (EGLNativeWindowType)&native_window, nullptr);
		ERR_FAIL_COND_MSG(egl_surface == EGL_NO_SURFACE, "fbdev: cannot restore the window surface.");
		if (!eglMakeCurrent(egl_display, egl_surface, egl_surface, egl_context)) {
			eglDestroySurface(egl_display, egl_surface);
			egl_surface = EGL_NO_SURFACE;
			ERR_FAIL_MSG("fbdev: cannot restore the rendering context.");
		}
		eglSwapInterval(egl_display, vsync_mode == DisplayServerEnums::VSYNC_DISABLED ? 0 : 1);
		Error audio_error = AudioDriver::get_singleton()->init();
		if (audio_error != OK) {
			OS::get_singleton()->delay_usec(100000);
			audio_error = AudioDriver::get_singleton()->init();
		}
		if (audio_error == OK) {
			AudioDriver::get_singleton()->start();
		} else {
			ERR_PRINT("fbdev: cannot restore audio after the game.");
		}
		_open_inputs();
		minimized = false;
	}
}

void DisplayServerFbdev::release_rendering_thread() {
	eglMakeCurrent(egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
}

void DisplayServerFbdev::gl_window_make_current(DisplayServerEnums::WindowID p_window_id) {
	eglMakeCurrent(egl_display, egl_surface, egl_surface, egl_context);
}

void DisplayServerFbdev::swap_buffers() {
	if (!minimized) {
		eglSwapBuffers(egl_display, egl_surface);
	}
}

DisplayServerFbdev::DisplayServerFbdev(DisplayServerEnums::VSyncMode p_vsync_mode, Error &r_error) {
	r_error = _init_egl();
	if (r_error != OK) {
		return;
	}
	window_set_vsync_mode(p_vsync_mode);
	RasterizerGLES3::make_current(false);
	_open_inputs();
}

DisplayServerFbdev::~DisplayServerFbdev() {
	for (Pad &pad : inputs) {
		close(pad.fd);
	}
	if (egl_display != EGL_NO_DISPLAY) {
		eglMakeCurrent(egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
		if (egl_context != EGL_NO_CONTEXT) {
			eglDestroyContext(egl_display, egl_context);
		}
		if (egl_surface != EGL_NO_SURFACE) {
			eglDestroySurface(egl_display, egl_surface);
		}
		eglTerminate(egl_display);
	}
}

#endif // FBDEV_ENABLED

/**************************************************************************/
/*  display_server_fbdev.h                                                */
/**************************************************************************/
/* Fullscreen DisplayServer for Mali fbdev EGL on Anbernic H700 (BaseOS). */
/* It has one window, the panel. It reads the Socket virtual gamepad.     */
/**************************************************************************/

#pragma once

#ifdef FBDEV_ENABLED

#include "core/templates/local_vector.h"
#include "servers/display/display_server_headless.h"

#include <platform_egl.h>

class DisplayServerFbdev : public DisplayServerHeadless {
	GDSOFTCLASS(DisplayServerFbdev, DisplayServerHeadless);

	// The Mali fbdev winsys reads this struct as its native window.
	struct FbdevWindow {
		unsigned short width;
		unsigned short height;
	};

	struct Pad {
		int fd = -1;
		float abs_min[2] = { -32768, -32768 };
		float abs_max[2] = { 32767, 32767 };
	};

	FbdevWindow native_window = {};
	EGLDisplay egl_display = EGL_NO_DISPLAY;
	EGLSurface egl_surface = EGL_NO_SURFACE;
	EGLContext egl_context = EGL_NO_CONTEXT;
	EGLConfig egl_config = nullptr;
	bool minimized = false;
	Size2i size;
	DisplayServerEnums::VSyncMode vsync_mode = DisplayServerEnums::VSYNC_ENABLED;

	LocalVector<Pad> inputs;
	int hat[2] = { 0, 0 };
	bool joy_connected = false;

	static Vector<String> get_rendering_drivers_func();
	static DisplayServer *create_func(const String &p_rendering_driver, DisplayServerEnums::WindowMode p_mode, DisplayServerEnums::VSyncMode p_vsync_mode, uint32_t p_flags, const Vector2i *p_position, const Vector2i &p_resolution, int p_screen, DisplayServerEnums::Context p_context, int64_t p_parent_window, Error &r_error);

	Error _init_egl();
	void _open_inputs();
	void _read_input(Pad &p_pad);

public:
	static void register_fbdev_driver();

	String get_name() const override { return "fbdev"; }

	int get_screen_count() const override { return 1; }
	Size2i screen_get_size(int p_screen = DisplayServerEnums::SCREEN_OF_MAIN_WINDOW) const override { return size; }
	Rect2i screen_get_usable_rect(int p_screen = DisplayServerEnums::SCREEN_OF_MAIN_WINDOW) const override { return Rect2i(Point2i(), size); }

	Vector<DisplayServerEnums::WindowID> get_window_list() const override;
	int window_get_current_screen(DisplayServerEnums::WindowID p_window = DisplayServerEnums::MAIN_WINDOW_ID) const override { return 0; }
	Size2i window_get_size(DisplayServerEnums::WindowID p_window = DisplayServerEnums::MAIN_WINDOW_ID) const override { return size; }
	Size2i window_get_size_with_decorations(DisplayServerEnums::WindowID p_window = DisplayServerEnums::MAIN_WINDOW_ID) const override { return size; }
	DisplayServerEnums::WindowMode window_get_mode(DisplayServerEnums::WindowID p_window = DisplayServerEnums::MAIN_WINDOW_ID) const override { return minimized ? DisplayServerEnums::WINDOW_MODE_MINIMIZED : DisplayServerEnums::WINDOW_MODE_EXCLUSIVE_FULLSCREEN; }
	void window_set_mode(DisplayServerEnums::WindowMode p_mode, DisplayServerEnums::WindowID p_window = DisplayServerEnums::MAIN_WINDOW_ID) override;
	void window_set_vsync_mode(DisplayServerEnums::VSyncMode p_vsync_mode, DisplayServerEnums::WindowID p_window = DisplayServerEnums::MAIN_WINDOW_ID) override;
	DisplayServerEnums::VSyncMode window_get_vsync_mode(DisplayServerEnums::WindowID p_window) const override { return vsync_mode; }
	bool window_can_draw(DisplayServerEnums::WindowID p_window = DisplayServerEnums::MAIN_WINDOW_ID) const override { return !minimized; }
	bool can_any_window_draw() const override { return !minimized; }

	void process_events() override;
	void release_rendering_thread() override;
	void gl_window_make_current(DisplayServerEnums::WindowID p_window_id) override;
	void swap_buffers() override;

	DisplayServerFbdev(DisplayServerEnums::VSyncMode p_vsync_mode, Error &r_error);
	~DisplayServerFbdev();
};

#endif // FBDEV_ENABLED

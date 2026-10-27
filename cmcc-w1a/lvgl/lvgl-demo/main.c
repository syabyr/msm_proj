/* lvgl-demo - minimal LVGL 10 kiosk on the W1A framebuffer.
 * usage: lvgl-demo [/dev/input/eventN]
 *
 * Uses the in-tree LVGL Linux fbdev driver (/dev/fb0, XRGB8888) and
 * the evdev touchscreen driver (FT3267).  Meant to run inside the
 * display-mode initramfs where no compositor owns the display.
 */
#include "lvgl/lvgl.h"

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static void anim_cb(lv_timer_t *t)
{
	lv_obj_t *arc = lv_timer_get_user_data(t);
	int32_t v = lv_arc_get_value(arc) + 3;

	if (v > 100)
		v = 0;
	lv_arc_set_value(arc, v);
}

static void btn_cb(lv_event_t *e)
{
	static unsigned int taps;
	lv_obj_t *btn = lv_event_get_target(e);
	lv_obj_t *label = lv_obj_get_child(btn, 0);

	taps++;
	lv_label_set_text_fmt(label, "Tapped %u", taps);
}

int main(int argc, char **argv)
{
	const char *evdev = argc > 1 ? argv[1] : "/dev/input/event1";
	lv_display_t *disp;
	lv_indev_t *indev;
	lv_obj_t *scr, *label, *btn, *bl, *arc;
	lv_result_t r;

	setvbuf(stdout, NULL, _IONBF, 0);

	lv_init();

	disp = lv_linux_fbdev_create();
	if (!disp) {
		fprintf(stderr, "lvgl-demo: display create failed\n");
		return 1;
	}
	r = lv_linux_fbdev_set_file(disp, "/dev/fb0");
	if (r != LV_RESULT_OK) {
		fprintf(stderr, "lvgl-demo: fb set_file failed (%d)\n", (int)r);
		return 1;
	}

	indev = lv_evdev_create(LV_INDEV_TYPE_POINTER, evdev);
	if (!indev)
		fprintf(stderr, "lvgl-demo: evdev create failed (%s)\n", evdev);
	else
		lv_indev_set_display(indev, disp);

	scr = lv_screen_active();
	lv_obj_set_style_bg_color(scr, lv_color_hex(0x0a0a14), 0);

	label = lv_label_create(scr);
	lv_label_set_text(label, "LVGL on W1A");
	lv_obj_set_style_text_color(label, lv_color_white(), 0);
	lv_obj_align(label, LV_ALIGN_TOP_MID, 0, 30);

	arc = lv_arc_create(scr);
	lv_obj_set_size(arc, 300, 300);
	lv_obj_align(arc, LV_ALIGN_CENTER, 0, 0);
	lv_arc_set_range(arc, 0, 100);
	lv_arc_set_value(arc, 50);
	lv_obj_set_style_arc_color(arc, lv_color_hex(0x00c0ff), LV_PART_INDICATOR);
	lv_obj_set_style_arc_width(arc, 12, LV_PART_INDICATOR);
	lv_obj_set_style_arc_width(arc, 12, LV_PART_MAIN);

	btn = lv_button_create(scr);
	lv_obj_set_size(btn, 200, 80);
	lv_obj_align(btn, LV_ALIGN_CENTER, 0, 0);
	lv_obj_add_event_cb(btn, btn_cb, LV_EVENT_CLICKED, NULL);
	bl = lv_label_create(btn);
	lv_label_set_text(bl, "Tap me");
	lv_obj_center(bl);

#if LV_USE_SYSMON && LV_USE_PERF_MONITOR
	lv_sysmon_show_performance(disp);
#endif

	/* continuous animation so the perf monitor measures real refresh */
	lv_timer_create(anim_cb, 16, arc);

	printf("lvgl-demo: ready (fb=/dev/fb0, indev=%s)\n", evdev);
	fflush(stdout);

	for (;;) {
		uint32_t t = lv_timer_handler();

		if (t > 10)
			t = 10;
		usleep(t * 1000);
	}

	return 0;
}

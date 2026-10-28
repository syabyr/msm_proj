/* Headless host renderer: draws the dashboard once into a PPM so the
 * layout can be checked without the watch.  Built with `make sim`.
 */
#define main app_main
#include "main.c"
#undef main

#define SIM_W 400
#define SIM_H 400

static uint32_t sim_buf[SIM_W * SIM_H];

static void sim_flush(lv_display_t *disp, const lv_area_t *area,
		      uint8_t *px)
{
	(void)area;
	(void)px;
	lv_display_flush_ready(disp);
}

static void dump_ppm(const char *path)
{
	FILE *f = fopen(path, "wb");
	int i, n = SIM_W * SIM_H;

	if (!f)
		return;
	fprintf(f, "P6\n%d %d\n255\n", SIM_W, SIM_H);
	for (i = 0; i < n; i++) {
		uint32_t v = sim_buf[i];

		fputc((v >> 16) & 0xff, f);
		fputc((v >> 8) & 0xff, f);
		fputc(v & 0xff, f);
	}
	fclose(f);
}

int main(void)
{
	lv_display_t *disp;
	struct sample s;

	memset(&s, 0, sizeof s);
	s.accel.ok = 1;
	s.accel.x = 0.07;
	s.accel.y = -0.08;
	s.accel.z = -9.69;
	s.gyro.ok = 1;
	s.gyro.x = 0.003;
	s.gyro.y = -0.071;
	s.gyro.z = -0.040;
	s.mag.ok = 1;
	s.mag.x = -1.203;
	s.mag.y = -16.025;
	s.mag.z = 20.618;
	s.baro_ok = 1;
	s.baro_kpa = 100.907;
	s.baro_temp = 34.0;
	s.baro_alt = 35.0;
	s.batt_ok = 1;
	s.batt_pct = 100;
	s.batt_v = 4.286;
	s.batt_ma = 0.0;
	snprintf(s.batt_status, sizeof s.batt_status, "Full");
	s.chgr_ok = 1;
	s.chgr_online = 1;
	s.ntherm = 4;
	snprintf(s.therm[0].name, sizeof s.therm[0].name, "camera");
	s.therm[0].c = 45.0;
	snprintf(s.therm[1].name, sizeof s.therm[1].name, "cpu0_2");
	s.therm[1].c = 45.0;
	snprintf(s.therm[2].name, sizeof s.therm[2].name, "gpu");
	s.therm[2].c = 41.0;
	snprintf(s.therm[3].name, sizeof s.therm[3].name, "modem");
	s.therm[3].c = 42.0;
	s.accel_hz = 12.5;
	s.gyro_hz = 12.5;

	lv_init();
	disp = lv_display_create(SIM_W, SIM_H);
	lv_display_set_color_format(disp, LV_COLOR_FORMAT_XRGB8888);
	lv_display_set_buffers(disp, sim_buf, NULL, sizeof sim_buf,
			       LV_DISPLAY_RENDER_MODE_DIRECT);
	lv_display_set_flush_cb(disp, sim_flush);

	build_ui(disp);
	update_cards(&s);
	lv_label_set_text_fmt(g_sys_val, "12:34:56\n12.5Hz 2.04s");
	lv_label_set_text(g_input_val, "VOLUP down\ntouch 120,120 D");
	lv_obj_set_hidden(g_dot, false);
	lv_obj_set_pos(g_dot, 30 - DOT_SIZE / 2, 200 - DOT_SIZE / 2);

	lv_obj_invalidate(lv_screen_active());
	lv_refr_now(disp);
	dump_ppm("/tmp/lvgl-sensors.ppm");
	printf("wrote /tmp/lvgl-sensors.ppm\n");
	return 0;
}

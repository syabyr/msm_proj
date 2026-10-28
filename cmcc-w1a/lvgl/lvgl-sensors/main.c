/* lvgl-sensors - LVGL sensor dashboard for the CMCC W1A.
 *
 * Round-safe 400x400 layout: eight cards fed by a background thread that
 * reads the sysfs sensors (accel/gyro ~2 s per full sample at 12.5 Hz),
 * plus an evdev thread for the keys/headset jack.  Touch is owned by
 * LVGL's evdev driver and drawn as a cursor dot.
 */
#define _GNU_SOURCE

#include "lvgl/lvgl.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#include <linux/input.h>

#define PATHLEN   256
#define MAX_IIO   16
#define MAX_THERM 8
#define MAX_EV    16

#define PI        3.14159265358979323846
#define RAD2DEG   (180.0 / PI)
#define G0        9.80665
#define P0_KPA    101.325

#define CARD_W    136
#define CARD_H    67
#define CARD_GAP  4
#define GRID_W    (2 * CARD_W + CARD_GAP)
#define GRID_H    (4 * CARD_H + 3 * CARD_GAP)
#define DOT_SIZE  30

#define NBITS(x)  (((x) - 1) / (8 * sizeof(unsigned long)) + 1)
#define BIT_ISSET(b, bits) \
	(((bits)[(b) / (8 * sizeof(unsigned long))] >> \
	  ((b) % (8 * sizeof(unsigned long)))) & 1UL)

enum {
	K_MAG   = 1 << 0,
	K_ACCEL = 1 << 1,
	K_GYRO  = 1 << 2,
	K_BARO  = 1 << 3,
};

struct iio_dev {
	char dir[128];
	char name[64];
	unsigned kinds;
};

struct therm {
	char name[32];
	double c;
};

struct xyz {
	int ok;
	double x, y, z;
	double scale;
};

struct sample {
	struct xyz mag, accel, gyro;
	double baro_kpa, baro_temp, baro_alt;
	int baro_ok;
	double batt_pct, batt_v, batt_ma, chgr_online;
	int batt_ok, batt_present, chgr_ok;
	char batt_status[32], batt_type[16];
	int ntherm;
	struct therm therm[MAX_THERM];
	double accel_hz, gyro_hz;
};

struct snap {
	struct sample s;
	unsigned long gen;
	double took;
	int valid;
};

static struct iio_dev iios[MAX_IIO];
static int niio;

static struct snap g_snap;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

static char g_in_val[48] = "--";

/* previous values so the UI only redraws on change */
static unsigned long last_sample_gen;
static char last_input_combo[80];
static int last_touch_x = -1, last_touch_y = -1;
static int touch_seen;

static lv_indev_t *g_touch;
static lv_obj_t *g_dot;
static lv_obj_t *g_accel_val, *g_gyro_val, *g_mag_val, *g_baro_val;
static lv_obj_t *g_power_val, *g_temp_val, *g_input_val, *g_sys_val;

static volatile sig_atomic_t stop;

/* ------------------------------------------------------------------ sysfs */

static int read_str(const char *path, char *out, size_t n)
{
	FILE *f = fopen(path, "r");
	size_t l;

	if (!f)
		return -1;
	if (!fgets(out, n, f)) {
		fclose(f);
		return -1;
	}
	fclose(f);
	l = strlen(out);
	while (l && (out[l - 1] == '\n' || out[l - 1] == '\r'))
		out[--l] = 0;
	return 0;
}

static int read_long_file(const char *path, long *v)
{
	char buf[64], *end;

	if (read_str(path, buf, sizeof buf))
		return -1;
	errno = 0;
	*v = strtol(buf, &end, 10);
	return (end == buf || errno) ? -1 : 0;
}

static int read_double_file(const char *path, double *v)
{
	char buf[64], *end;

	if (read_str(path, buf, sizeof buf))
		return -1;
	errno = 0;
	*v = strtod(buf, &end);
	return (end == buf || errno) ? -1 : 0;
}

static int attr_exists(const char *dir, const char *name)
{
	char p[PATHLEN];

	snprintf(p, sizeof p, "%s/%s", dir, name);
	return access(p, F_OK) == 0;
}

static int axis_scale(const char *dir, const char *prefix,
		      const char *axis, double *scale)
{
	char p[PATHLEN];

	snprintf(p, sizeof p, "%s/in_%s_%s_scale", dir, prefix, axis);
	if (read_double_file(p, scale) == 0)
		return 0;
	snprintf(p, sizeof p, "%s/in_%s_scale", dir, prefix);
	return read_double_file(p, scale);
}

static int read_xyz(const char *dir, const char *prefix, struct xyz *out)
{
	static const char *axes[3] = { "x", "y", "z" };
	double v[3];
	int i;

	for (i = 0; i < 3; i++) {
		char p[PATHLEN];
		long raw;
		double scale;

		snprintf(p, sizeof p, "%s/in_%s_%s_raw", dir, prefix, axes[i]);
		if (read_long_file(p, &raw))
			return -1;
		if (axis_scale(dir, prefix, axes[i], &scale))
			scale = 1.0;
		v[i] = raw * scale;
		if (i == 0)
			out->scale = scale;
	}
	out->x = v[0];
	out->y = v[1];
	out->z = v[2];
	out->ok = 1;
	return 0;
}

static int read_baro(const char *dir, double *kpa, double *temp_c)
{
	char p[PATHLEN];
	double v;

	snprintf(p, sizeof p, "%.100s/in_pressure_input", dir);
	if (read_double_file(p, &v) == 0) {
		*kpa = v;
	} else {
		double raw, scale;

		snprintf(p, sizeof p, "%.100s/in_pressure_raw", dir);
		if (read_double_file(p, &raw))
			return -1;
		snprintf(p, sizeof p, "%.100s/in_pressure_scale", dir);
		if (read_double_file(p, &scale))
			return -1;
		*kpa = raw * scale;
	}

	snprintf(p, sizeof p, "%.100s/in_temp_input", dir);
	if (read_double_file(p, &v) == 0)
		*temp_c = v / 1000.0;
	else
		*temp_c = NAN;
	return 0;
}

static void scan_iio(void)
{
	DIR *d = opendir("/sys/bus/iio/devices");
	struct dirent *e;

	if (!d)
		return;
	while ((e = readdir(d)) && niio < MAX_IIO) {
		struct iio_dev *dev;
		char p[PATHLEN], nm[64];

		if (strncmp(e->d_name, "iio:device", 10) != 0)
			continue;
		snprintf(nm, sizeof nm, "%.63s", e->d_name);
		dev = &iios[niio];
		memset(dev, 0, sizeof *dev);
		snprintf(dev->dir, sizeof dev->dir,
			 "/sys/bus/iio/devices/%s", nm);
		snprintf(p, sizeof p, "%s/name", dev->dir);
		if (read_str(p, dev->name, sizeof dev->name))
			snprintf(dev->name, sizeof dev->name, "%.63s", nm);

		if (attr_exists(dev->dir, "in_magn_x_raw"))
			dev->kinds |= K_MAG;
		if (attr_exists(dev->dir, "in_accel_x_raw"))
			dev->kinds |= K_ACCEL;
		if (attr_exists(dev->dir, "in_anglvel_x_raw"))
			dev->kinds |= K_GYRO;
		if (attr_exists(dev->dir, "in_pressure_input") ||
		    attr_exists(dev->dir, "in_pressure_raw"))
			dev->kinds |= K_BARO;
		if (dev->kinds)
			niio++;
	}
	closedir(d);
}

static void read_battery(struct sample *s)
{
	DIR *d = opendir("/sys/class/power_supply");
	struct dirent *e;

	if (!d)
		return;
	while ((e = readdir(d))) {
		char dir[128], p[PATHLEN], type[32] = "", nm[64];
		double v;

		if (e->d_name[0] == '.')
			continue;
		snprintf(nm, sizeof nm, "%.63s", e->d_name);
		snprintf(dir, sizeof dir, "/sys/class/power_supply/%s", nm);
		snprintf(p, sizeof p, "%s/type", dir);
		if (read_str(p, type, sizeof type))
			continue;

		if (!strcmp(type, "Battery") && !s->batt_ok) {
			long present;

			snprintf(p, sizeof p, "%s/capacity", dir);
			if (read_double_file(p, &v) == 0)
				s->batt_pct = v;
			snprintf(p, sizeof p, "%s/voltage_now", dir);
			if (read_double_file(p, &v) == 0)
				s->batt_v = v / 1e6;
			snprintf(p, sizeof p, "%s/current_now", dir);
			if (read_double_file(p, &v) == 0)
				s->batt_ma = v / 1e3;
			snprintf(p, sizeof p, "%s/status", dir);
			read_str(p, s->batt_status, sizeof s->batt_status);
			snprintf(p, sizeof p, "%s/present", dir);
			if (read_long_file(p, &present) == 0)
				s->batt_present = present;
			snprintf(s->batt_type, sizeof s->batt_type, "%.15s",
				 nm);
			s->batt_ok = 1;
		} else if (!strcmp(type, "USB") && !s->chgr_ok) {
			long online;

			snprintf(p, sizeof p, "%s/online", dir);
			if (read_long_file(p, &online) == 0)
				s->chgr_online = online;
			s->chgr_ok = 1;
		}
	}
	closedir(d);
}

static int therm_cmp(const void *a, const void *b)
{
	const struct therm *ta = a, *tb = b;

	return strcmp(ta->name, tb->name);
}

static void read_thermals(struct sample *s)
{
	DIR *d = opendir("/sys/class/hwmon");
	struct dirent *e;

	s->ntherm = 0;
	if (!d)
		return;
	while ((e = readdir(d)) && s->ntherm < MAX_THERM) {
		char dir[128], nm[32];
		int n;

		if (strncmp(e->d_name, "hwmon", 5) != 0)
			continue;
		snprintf(nm, sizeof nm, "%.31s", e->d_name);
		snprintf(dir, sizeof dir, "/sys/class/hwmon/%s", nm);
		for (n = 1; n <= 4; n++) {
			char p[PATHLEN], name[32] = "";
			double v;

			snprintf(p, sizeof p, "%s/temp%d_input", dir, n);
			if (read_double_file(p, &v))
				continue;
			snprintf(p, sizeof p, "%s/name", dir);
			if (read_str(p, name, sizeof name))
				snprintf(name, sizeof name, "%.31s", nm);
			snprintf(s->therm[s->ntherm].name,
				 sizeof s->therm[s->ntherm].name, "%s", name);
			s->therm[s->ntherm].c = v / 1000.0;
			s->ntherm++;
			break;
		}
	}
	closedir(d);
	qsort(s->therm, s->ntherm, sizeof s->therm[0], therm_cmp);
}

static void read_sampling(unsigned kind, double *out)
{
	int i;

	for (i = 0; i < niio; i++) {
		char p[PATHLEN];

		if (!(iios[i].kinds & kind))
			continue;
		snprintf(p, sizeof p, "%.100s/sampling_frequency",
			 iios[i].dir);
		read_double_file(p, out);
		return;
	}
}

static void read_sample(struct sample *s)
{
	int i;

	memset(s, 0, sizeof *s);
	s->baro_kpa = NAN;
	s->baro_temp = NAN;
	s->baro_alt = NAN;
	for (i = 0; i < niio; i++) {
		struct iio_dev *dev = &iios[i];

		if ((dev->kinds & K_MAG) && !s->mag.ok)
			read_xyz(dev->dir, "magn", &s->mag);
		if ((dev->kinds & K_ACCEL) && !s->accel.ok)
			read_xyz(dev->dir, "accel", &s->accel);
		if ((dev->kinds & K_GYRO) && !s->gyro.ok)
			read_xyz(dev->dir, "anglvel", &s->gyro);
		if ((dev->kinds & K_BARO) && !s->baro_ok) {
			s->baro_ok = read_baro(dev->dir, &s->baro_kpa,
					       &s->baro_temp) == 0;
			if (s->baro_ok)
				s->baro_alt = 44330.0 *
					(1.0 - pow(s->baro_kpa / P0_KPA,
						   1.0 / 5.255));
		}
	}
	read_sampling(K_ACCEL, &s->accel_hz);
	read_sampling(K_GYRO, &s->gyro_hz);
	read_battery(s);
	read_thermals(s);
}

static double now_sec(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* ------------------------------------------------------------ sensor thread */

static void *sensor_thread(void *arg)
{
	(void)arg;

	for (;;) {
		struct sample s;
		double t0 = now_sec();

		read_sample(&s);
		pthread_mutex_lock(&g_lock);
		g_snap.s = s;
		g_snap.took = now_sec() - t0;
		g_snap.gen++;
		g_snap.valid = 1;
		pthread_mutex_unlock(&g_lock);
		usleep(200000);
	}
	return NULL;
}

/* ------------------------------------------------------------- input thread */

static const char *key_name(unsigned code, char *buf, size_t n)
{
	switch (code) {
	case KEY_POWER:		return "POWER";
	case KEY_VOLUMEUP:	return "VOLUP";
	case KEY_VOLUMEDOWN:	return "VOLDN";
	case KEY_PLAYPAUSE:	return "PLAY";
	case KEY_NEXTSONG:	return "NEXT";
	case KEY_PREVIOUSSONG:	return "PREV";
	case KEY_PHONE:		return "PHONE";
	default:
		snprintf(buf, n, "KEY_%u", code);
		return buf;
	}
}

static const char *sw_name(unsigned code, char *buf, size_t n)
{
	switch (code) {
	case SW_HEADPHONE_INSERT:	return "HEADPHONE";
	case SW_MICROPHONE_INSERT:	return "MIC";
	case SW_LINEOUT_INSERT:		return "LINEOUT";
	case SW_JACK_PHYSICAL_INSERT:	return "JACK";
	case SW_LID:			return "LID";
	default:
		snprintf(buf, n, "SW_%u", code);
		return buf;
	}
}

struct kdev {
	int fd;
};

static int open_key_devices(struct kdev *devs, int max)
{
	DIR *d = opendir("/dev/input");
	struct dirent *e;
	int n = 0;

	if (!d)
		return 0;
	while ((e = readdir(d)) && n < max) {
		unsigned long evbits[NBITS(EV_CNT)] = { 0 };
		unsigned long keybits[NBITS(KEY_CNT)] = { 0 };
		unsigned long swbits[NBITS(SW_CNT)] = { 0 };
		unsigned long absbits[NBITS(ABS_CNT)] = { 0 };
		char path[PATHLEN];
		int fd, i, useful = 0;

		if (strncmp(e->d_name, "event", 5) != 0)
			continue;
		snprintf(path, sizeof path, "/dev/input/%.100s", e->d_name);
		fd = open(path, O_RDONLY | O_NONBLOCK);
		if (fd < 0)
			continue;
		ioctl(fd, EVIOCGBIT(EV_KEY, sizeof keybits), keybits);
		ioctl(fd, EVIOCGBIT(EV_SW, sizeof swbits), swbits);
		ioctl(fd, EVIOCGBIT(EV_ABS, sizeof absbits), absbits);
		ioctl(fd, EVIOCGBIT(0, sizeof evbits), evbits);

		/* skip the touchscreen; LVGL's evdev driver owns it */
		if (BIT_ISSET(ABS_MT_POSITION_X, absbits) ||
		    BIT_ISSET(ABS_X, absbits)) {
			close(fd);
			continue;
		}
		for (i = 0; i < KEY_CNT; i++)
			if (BIT_ISSET(i, keybits) && i != BTN_TOUCH)
				useful = 1;
		for (i = 0; i < SW_CNT; i++)
			if (BIT_ISSET(i, swbits))
				useful = 1;
		if (!useful) {
			close(fd);
			continue;
		}
		devs[n++].fd = fd;
	}
	closedir(d);
	return n;
}

static void *input_thread(void *arg)
{
	struct kdev devs[MAX_EV];
	struct pollfd pfds[MAX_EV];
	int n, i;

	(void)arg;
	n = open_key_devices(devs, MAX_EV);
	for (i = 0; i < n; i++) {
		pfds[i].fd = devs[i].fd;
		pfds[i].events = POLLIN;
		pfds[i].revents = 0;
	}

	while (!stop) {
		struct input_event ev;
		char b[32];

		if (n <= 0) {
			usleep(200000);
			continue;
		}
		if (poll(pfds, n, 200) <= 0)
			continue;
		for (i = 0; i < n; i++) {
			if (!(pfds[i].revents & POLLIN))
				continue;
			while (read(devs[i].fd, &ev, sizeof ev) ==
			       (ssize_t)sizeof ev) {
				char val[48];

				if (ev.type == EV_KEY && ev.code != BTN_TOUCH) {
					snprintf(val, sizeof val, "%s %s",
						 key_name(ev.code, b, sizeof b),
						 ev.value ? "down" : "up");
				} else if (ev.type == EV_SW) {
					snprintf(val, sizeof val, "%s %s",
						 sw_name(ev.code, b, sizeof b),
						 ev.value ? "on" : "off");
				} else {
					continue;
				}
				pthread_mutex_lock(&g_lock);
				snprintf(g_in_val, sizeof g_in_val, "%s", val);
				pthread_mutex_unlock(&g_lock);
			}
		}
	}
	return NULL;
}

/* --------------------------------------------------------------------- UI */

static lv_obj_t *make_card(lv_obj_t *parent, const char *title,
			   uint32_t accent, int x, int y)
{
	lv_obj_t *card, *t, *v;

	card = lv_obj_create(parent);
	lv_obj_set_pos(card, x, y);
	lv_obj_set_size(card, CARD_W, CARD_H);
	lv_obj_set_style_radius(card, 12, 0);
	lv_obj_set_style_bg_color(card, lv_color_hex(0x0f172a), 0);
	lv_obj_set_style_bg_opa(card, LV_OPA_COVER, 0);
	lv_obj_set_style_border_width(card, 1, 0);
	lv_obj_set_style_border_color(card, lv_color_hex(0x1e293b), 0);
	lv_obj_set_style_shadow_width(card, 0, 0);
	lv_obj_set_style_outline_width(card, 0, 0);
	lv_obj_set_style_pad_all(card, 5, 0);
	lv_obj_set_style_pad_row(card, 0, 0);
	lv_obj_set_scrollbar_mode(card, LV_SCROLLBAR_MODE_OFF);
	lv_obj_set_scrollable(card, false);
	lv_obj_set_clickable(card, false);

	t = lv_label_create(card);
	lv_label_set_text(t, title);
	lv_obj_set_style_text_color(t, lv_color_hex(accent), 0);
	lv_obj_set_style_text_font(t, &lv_font_montserrat_14, 0);
	lv_obj_set_pos(t, 0, -1);

	v = lv_label_create(card);
	lv_label_set_text(v, "--");
	lv_obj_set_style_text_color(v, lv_color_hex(0xe5e7eb), 0);
	lv_obj_set_style_text_font(v, &lv_font_montserrat_14, 0);
	lv_obj_set_style_text_line_space(v, -2, 0);
	lv_obj_set_pos(v, 0, 16);
	lv_obj_set_width(v, CARD_W - 10);
	lv_label_set_long_mode(v, LV_LABEL_LONG_MODE_CLIP);

	return v;
}

static double therm_get(const struct sample *s, const char *name)
{
	int i;

	for (i = 0; i < s->ntherm; i++)
		if (!strcmp(s->therm[i].name, name))
			return s->therm[i].c;
	return NAN;
}

static void fmt_temp(double c, char *out, size_t n)
{
	if (isnan(c))
		snprintf(out, n, "--");
	else
		snprintf(out, n, "%.0f", c);
}

static void update_cards(const struct sample *s)
{
	char b[96], t1[8], t2[8], t3[8], t4[8];

	if (s->accel.ok) {
		double m = sqrt(s->accel.x * s->accel.x +
				s->accel.y * s->accel.y +
				s->accel.z * s->accel.z);

		snprintf(b, sizeof b, "%.2f %.2f %.2f\n|a| %.2f  %.2fg",
			 s->accel.x, s->accel.y, s->accel.z, m, m / G0);
	} else {
		snprintf(b, sizeof b, "no data");
	}
	lv_label_set_text(g_accel_val, b);

	if (s->gyro.ok) {
		double x = s->gyro.x * RAD2DEG;
		double y = s->gyro.y * RAD2DEG;
		double z = s->gyro.z * RAD2DEG;
		double m = sqrt(x * x + y * y + z * z);

		snprintf(b, sizeof b, "%.1f %.1f %.1f\n|w| %.1f dps", x, y, z, m);
	} else {
		snprintf(b, sizeof b, "no data");
	}
	lv_label_set_text(g_gyro_val, b);

	if (s->mag.ok) {
		double hdg = atan2(s->mag.y, s->mag.x) * RAD2DEG;
		double m = sqrt(s->mag.x * s->mag.x + s->mag.y * s->mag.y +
				s->mag.z * s->mag.z) * 100.0;

		if (hdg < 0)
			hdg += 360.0;
		snprintf(b, sizeof b, "hdg %.0f deg\nB %.0f uT", hdg, m);
	} else {
		snprintf(b, sizeof b, "no data");
	}
	lv_label_set_text(g_mag_val, b);

	if (s->baro_ok) {
		snprintf(b, sizeof b, "%.2f kPa\n%.1fC alt %.0fm",
			 s->baro_kpa, s->baro_temp, s->baro_alt);
	} else {
		snprintf(b, sizeof b, "no data");
	}
	lv_label_set_text(g_baro_val, b);

	if (s->batt_ok) {
		snprintf(b, sizeof b, "%.0f%% %.3fV%s\n%.1fmA %s",
			 s->batt_pct, s->batt_v,
			 s->chgr_ok && s->chgr_online ? "+" : "",
			 s->batt_ma, s->batt_status);
	} else {
		snprintf(b, sizeof b, "no battery");
	}
	lv_label_set_text(g_power_val, b);

	fmt_temp(therm_get(s, "camera"), t1, sizeof t1);
	fmt_temp(therm_get(s, "cpu0_2"), t2, sizeof t2);
	fmt_temp(therm_get(s, "gpu"), t3, sizeof t3);
	fmt_temp(therm_get(s, "modem"), t4, sizeof t4);
	snprintf(b, sizeof b, "cam %s cpu %s\ngpu %s mod %s", t1, t2, t3, t4);
	lv_label_set_text(g_temp_val, b);
}

/* fast timer: key/switch events, touch cursor and coordinates */
static void input_timer_cb(lv_timer_t *t)
{
	int down = 0, tx = -1, ty = -1;
	char in[48], touch[24], combo[80];
	lv_point_t p;

	(void)t;
	pthread_mutex_lock(&g_lock);
	snprintf(in, sizeof in, "%s", g_in_val);
	pthread_mutex_unlock(&g_lock);

	if (g_touch) {
		down = lv_indev_get_state(g_touch) == LV_INDEV_STATE_PRESSED;
		lv_indev_get_point(g_touch, &p);
		if (down) {
			touch_seen = 1;
			tx = p.x;
			ty = p.y;
			last_touch_x = tx;
			last_touch_y = ty;
		}
	}
	if (down) {
		lv_obj_set_pos(g_dot, tx - DOT_SIZE / 2, ty - DOT_SIZE / 2);
		lv_obj_set_hidden(g_dot, false);
	} else {
		lv_obj_set_hidden(g_dot, true);
	}

	if (touch_seen)
		snprintf(touch, sizeof touch, "touch %d,%d %c",
			 down ? tx : last_touch_x,
			 down ? ty : last_touch_y,
			 down ? 'D' : 'U');
	else
		snprintf(touch, sizeof touch, "touch --");

	snprintf(combo, sizeof combo, "%s\n%s", in, touch);
	if (strcmp(combo, last_input_combo)) {
		snprintf(last_input_combo, sizeof last_input_combo, "%s",
			 combo);
		lv_label_set_text(g_input_val, combo);
	}
}

static void ui_timer_cb(lv_timer_t *t)
{
	struct sample s;
	unsigned long gen;
	double took;
	int valid;
	static unsigned tick;

	(void)t;
	pthread_mutex_lock(&g_lock);
	s = g_snap.s;
	gen = g_snap.gen;
	took = g_snap.took;
	valid = g_snap.valid;
	pthread_mutex_unlock(&g_lock);

	if (valid && gen != last_sample_gen) {
		last_sample_gen = gen;
		update_cards(&s);
	}

	/* RTC + sampling once a second */
	if (++tick % 4 == 0) {
		char rtc[16] = "--:--:--";

		read_str("/sys/class/rtc/rtc0/time", rtc, sizeof rtc);
		if (valid)
			lv_label_set_text_fmt(g_sys_val, "%s\n%.1fHz %.2fs",
					      rtc, s.accel_hz, took);
		else
			lv_label_set_text_fmt(g_sys_val, "%s\n--", rtc);
	}
}

static void find_touch_node(char *out, size_t n)
{
	DIR *d = opendir("/dev/input");
	struct dirent *e;

	snprintf(out, n, "/dev/input/event3");
	if (!d)
		return;
	while ((e = readdir(d))) {
		unsigned long absbits[NBITS(ABS_CNT)] = { 0 };
		char path[PATHLEN];
		int fd;

		if (strncmp(e->d_name, "event", 5) != 0)
			continue;
		snprintf(path, sizeof path, "/dev/input/%.100s", e->d_name);
		fd = open(path, O_RDONLY | O_NONBLOCK);
		if (fd < 0)
			continue;
		ioctl(fd, EVIOCGBIT(EV_ABS, sizeof absbits), absbits);
		if (BIT_ISSET(ABS_MT_POSITION_X, absbits))
			snprintf(out, n, "%s", path);
		close(fd);
		if (BIT_ISSET(ABS_MT_POSITION_X, absbits))
			break;
	}
	closedir(d);
}

static void build_ui(lv_display_t *disp)
{
	int w = lv_display_get_horizontal_resolution(disp);
	int h = lv_display_get_vertical_resolution(disp);
	int gx = (w - GRID_W) / 2;
	int gy = (h - GRID_H) / 2;
	lv_obj_t *scr = lv_screen_active();
	lv_obj_t *header;

	lv_obj_set_style_bg_color(scr, lv_color_hex(0x000000), 0);
	lv_obj_set_style_pad_all(scr, 0, 0);
	lv_obj_set_scrollbar_mode(scr, LV_SCROLLBAR_MODE_OFF);
	lv_obj_set_scrollable(scr, false);

	header = lv_label_create(scr);
	lv_label_set_text(header, "W1A SENSORS");
	lv_obj_set_style_text_color(header, lv_color_hex(0xe5e7eb), 0);
	lv_obj_set_style_text_font(header, &lv_font_montserrat_20, 0);
	lv_obj_align(header, LV_ALIGN_TOP_MID, 0, gy - 34);

	g_accel_val = make_card(scr, "ACCEL m/s2", 0x60a5fa,
				gx, gy);
	g_gyro_val = make_card(scr, "GYRO dps", 0x34d399,
			       gx + CARD_W + CARD_GAP, gy);
	g_mag_val = make_card(scr, "MAG uT", 0xc084fc,
			      gx, gy + (CARD_H + CARD_GAP));
	g_baro_val = make_card(scr, "BARO", 0x22d3ee,
			       gx + CARD_W + CARD_GAP,
			       gy + (CARD_H + CARD_GAP));
	g_power_val = make_card(scr, "POWER", 0xfbbf24,
				gx, gy + 2 * (CARD_H + CARD_GAP));
	g_temp_val = make_card(scr, "TEMP C", 0xf87171,
			       gx + CARD_W + CARD_GAP,
			       gy + 2 * (CARD_H + CARD_GAP));
	g_input_val = make_card(scr, "INPUT", 0xf472b6,
				gx, gy + 3 * (CARD_H + CARD_GAP));
	g_sys_val = make_card(scr, "SYS", 0x94a3b8,
			      gx + CARD_W + CARD_GAP,
			      gy + 3 * (CARD_H + CARD_GAP));

	g_dot = lv_obj_create(scr);
	lv_obj_set_size(g_dot, DOT_SIZE, DOT_SIZE);
	lv_obj_set_style_radius(g_dot, LV_RADIUS_CIRCLE, 0);
	lv_obj_set_style_bg_color(g_dot, lv_color_hex(0xfbbf24), 0);
	lv_obj_set_style_bg_opa(g_dot, LV_OPA_50, 0);
	lv_obj_set_style_border_width(g_dot, 2, 0);
	lv_obj_set_style_border_color(g_dot, lv_color_white(), 0);
	lv_obj_set_style_pad_all(g_dot, 0, 0);
	lv_obj_set_clickable(g_dot, false);
	lv_obj_set_hidden(g_dot, true);
}

static void on_signal(int sig)
{
	(void)sig;
	stop = 1;
}

int main(int argc, char **argv)
{
	char touch_node[PATHLEN];
	lv_display_t *disp;
	pthread_t th;
	lv_result_t r;

	(void)argc;
	(void)argv;

	setvbuf(stdout, NULL, _IONBF, 0);
	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);

	scan_iio();
	find_touch_node(touch_node, sizeof touch_node);

	lv_init();
	disp = lv_linux_fbdev_create();
	if (!disp) {
		fprintf(stderr, "lvgl-sensors: display create failed\n");
		return 1;
	}
	r = lv_linux_fbdev_set_file(disp, "/dev/fb0");
	if (r != LV_RESULT_OK) {
		fprintf(stderr, "lvgl-sensors: fb set_file failed (%d)\n",
			(int)r);
		return 1;
	}

	g_touch = lv_evdev_create(LV_INDEV_TYPE_POINTER, touch_node);
	if (!g_touch)
		fprintf(stderr, "lvgl-sensors: evdev create failed (%s)\n",
			touch_node);
	else
		lv_indev_set_display(g_touch, disp);

	build_ui(disp);
	lv_timer_create(input_timer_cb, 50, NULL);
	lv_timer_create(ui_timer_cb, 250, NULL);

	pthread_create(&th, NULL, sensor_thread, NULL);
	pthread_create(&th, NULL, input_thread, NULL);

	printf("lvgl-sensors: ready (fb=/dev/fb0, touch=%s, %d iio)\n",
	       touch_node, niio);
	fflush(stdout);

	while (!stop) {
		uint32_t t = lv_timer_handler();

		if (t > 20)
			t = 20;
		usleep(t * 1000);
	}

	close(STDIN_FILENO);
	return 0;
}

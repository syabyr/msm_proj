/*
 * w1a-vib - drive the CMCC-W1A vibration motor (PM8909 SPMI vibrator).
 *
 * The mainline driver (drivers/input/misc/pm8xxx-vibrator.c) registers an
 * evdev force-feedback device named "pm8xxx_vib_ffmemless" that supports
 * FF_RUMBLE only.  There is no sysfs trigger: userspace uploads a rumble
 * effect with EVIOCSFF and starts it by writing an EV_FF event.
 *
 * usage:
 *   w1a-vib [-d /dev/input/eventN] [-s strength] [-t ms] [-r repeats]
 *   w1a-vib -l                     list input devices
 *
 *   -s strength  1..254  (default 200)  -> PMIC drive
 *   -t duration  ms      (default 400)
 *   -r repeats   count   (default 1)
 *
 * Notes:
 *  - The input device number can change between boots (pwrkey, jack,
 *    touchscreen, gpio-keys are also input devices), so by default the
 *    tool looks up /sys/class/input/eventN/device/name and picks the
 *    "pm8xxx_vib_ffmemless" one.
 *  - Keep the fd open while vibrating: the driver's close() callback
 *    stops the motor.
 *  - Must run as root (or with write access to /dev/input/eventN).
 *  - Strength 255 is avoided: the driver's level math can overflow the
 *    5-bit VIB_VTG field at exactly 255 (32 & 0x1f == 0), which may
 *    silence the motor.  254 is the safe maximum.
 *  - Short pulses (<150 ms) at low strength are easy to miss: the motor
 *    needs a little spin-up time.  Defaults are 200/400 ms.
 */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define VIB_NAME "pm8xxx_vib_ffmemless"

static int find_vib(char *out, size_t outsz)
{
	DIR *d = opendir("/sys/class/input");
	struct dirent *de;
	int ret = -1;

	if (!d)
		return -1;

	while ((de = readdir(d)) != NULL) {
		char path[512], name[128];
		FILE *f;

		if (strncmp(de->d_name, "event", 5) != 0)
			continue;

		snprintf(path, sizeof(path), "/sys/class/input/%s/device/name",
			 de->d_name);
		f = fopen(path, "r");
		if (!f)
			continue;
		if (!fgets(name, sizeof(name), f)) {
			fclose(f);
			continue;
		}
		fclose(f);
		name[strcspn(name, "\r\n")] = '\0';

		if (strcmp(name, VIB_NAME) == 0) {
			snprintf(out, outsz, "/dev/input/%s", de->d_name);
			ret = 0;
			break;
		}
	}

	closedir(d);
	return ret;
}

static void list_devices(void)
{
	DIR *d = opendir("/sys/class/input");
	struct dirent *de;

	if (!d) {
		perror("/sys/class/input");
		return;
	}

	while ((de = readdir(d)) != NULL) {
		char path[512], name[128] = "";
		FILE *f;

		if (strncmp(de->d_name, "event", 5) != 0)
			continue;

		snprintf(path, sizeof(path), "/sys/class/input/%s/device/name",
			 de->d_name);
		f = fopen(path, "r");
		if (f) {
			if (fgets(name, sizeof(name), f))
				name[strcspn(name, "\r\n")] = '\0';
			fclose(f);
		}
		printf("/dev/input/%-8s %s\n", de->d_name, name);
	}

	closedir(d);
}

static void usage(const char *prog)
{
	fprintf(stderr,
		"usage: %s [-d /dev/input/eventN] [-s 1..254] [-t ms] [-r repeats]\n"
		"       %s -l\n", prog, prog);
}

int main(int argc, char **argv)
{
	const char *dev = NULL;
	int strength = 200, duration_ms = 400, repeats = 1;
	struct ff_effect eff;
	struct input_event ev;
	char path[512];
	int fd, opt;

	while ((opt = getopt(argc, argv, "d:s:t:r:lh")) != -1) {
		switch (opt) {
		case 'd':
			dev = optarg;
			break;
		case 's':
			strength = atoi(optarg);
			break;
		case 't':
			duration_ms = atoi(optarg);
			break;
		case 'r':
			repeats = atoi(optarg);
			break;
		case 'l':
			list_devices();
			return 0;
		default:
			usage(argv[0]);
			return 1;
		}
	}

	if (strength < 1)
		strength = 1;
	if (strength > 254)
		strength = 254;
	if (duration_ms < 1)
		duration_ms = 1;
	if (repeats < 1)
		repeats = 1;

	if (!dev) {
		if (find_vib(path, sizeof(path)) < 0) {
			fprintf(stderr, "w1a-vib: '%s' not found, use -d\n",
				VIB_NAME);
			list_devices();
			return 1;
		}
		dev = path;
	}

	fd = open(dev, O_RDWR);
	if (fd < 0) {
		fprintf(stderr, "w1a-vib: %s: %s\n", dev, strerror(errno));
		return 1;
	}

	memset(&eff, 0, sizeof(eff));
	eff.type = FF_RUMBLE;
	eff.id = -1;			/* let the kernel assign */
	eff.replay.length = duration_ms;
	eff.replay.delay = 0;
	/* driver: speed = strong_magnitude >> 8, so 0xffff -> 255 */
	eff.u.rumble.strong_magnitude = (uint16_t)(strength * 0xffff / 255);
	eff.u.rumble.weak_magnitude = 0;

	if (ioctl(fd, EVIOCSFF, &eff) < 0) {
		fprintf(stderr, "w1a-vib: EVIOCSFF: %s\n", strerror(errno));
		close(fd);
		return 1;
	}

	memset(&ev, 0, sizeof(ev));
	ev.type = EV_FF;
	ev.code = eff.id;
	ev.value = repeats;		/* >0: play, repeat count */

	if (write(fd, &ev, sizeof(ev)) != (ssize_t)sizeof(ev)) {
		fprintf(stderr, "w1a-vib: EV_FF write: %s\n", strerror(errno));
		ioctl(fd, EVIOCRMFF, eff.id);
		close(fd);
		return 1;
	}

	/* Keep the fd open so the driver does not stop on close().
	 * ff-memless stops the effect itself after replay.length * repeats. */
	usleep((useconds_t)duration_ms * repeats * 1000 + 50000);

	ev.value = 0;			/* explicit stop */
	if (write(fd, &ev, sizeof(ev)) < 0)
		fprintf(stderr, "w1a-vib: stop: %s\n", strerror(errno));
	ioctl(fd, EVIOCRMFF, eff.id);
	close(fd);

	return 0;
}

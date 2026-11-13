/* mempeek - read 32-bit registers from /dev/mem (naked static ARM)
 * build: arm-none-eabi-gcc -nostdlib -nostartfiles -static -O2 -o mempeek mempeek.c -lgcc
 * usage: mempeek <hexaddr> [count]
 */
#include <stdint.h>
typedef unsigned int size_t_t;
#define size_t unsigned int

#define __NR_exit       1
#define __NR_open       5	/* ARM EABI: open=5 (2 is fork!) */
#define __NR_close      6
#define __NR_write      4
#define __NR_mmap2      192
#define __NR_brk        45

static long sysc(long n, long a, long b, long c, long d, long e, long f)
{
	register long r7 __asm__("r7") = n;
	register long r0 __asm__("r0") = a;
	register long r1 __asm__("r1") = b;
	register long r2 __asm__("r2") = c;
	register long r3 __asm__("r3") = d;
	register long r4 __asm__("r4") = e;
	register long r5 __asm__("r5") = f;
	__asm__ volatile("svc 0"
			 : "+r"(r0), "+r"(r1), "+r"(r2), "+r"(r3)
			 : "r"(r7), "r"(r4), "r"(r5)
			 : "memory");
	return r0;
}

static int hexval(char c)
{
	if (c >= '0' && c <= '9') return c - '0';
	if (c >= 'a' && c <= 'f') return c - 'a' + 10;
	if (c >= 'A' && c <= 'F') return c - 'A' + 10;
	return -1;
}

static uint32_t hexparse(const char *s)
{
	uint32_t v = 0;
	while (*s) {
		int h = hexval(*s++);
		if (h < 0) break;
		v = (v << 4) | h;
	}
	return v;
}

static char *utoa(uint32_t v, char *buf)
{
	char tmp[12];
	int i = 0, j;
	if (!v) { buf[0] = '0'; buf[1] = 0; return buf; }
	while (v) { tmp[i++] = '0' + (v % 10); v /= 10; }
	for (j = 0; j < i; j++) buf[j] = tmp[i - 1 - j];
	buf[i] = 0;
	return buf;
}

static size_t slen(const char *s) { size_t n = 0; while (s[n]) n++; return n; }

#define O_RDONLY 0
#define PROT_READ 1
#define MAP_PRIVATE 2

void _start_c(long *sp)
{
	char **argv = (char **)(sp + 1);
	int argc = (int)(sp[0]);
	char line[96];
	uint32_t addr;
	unsigned int count = 1, i;

	if (argc < 2) {
		const char *u = "usage: mempeek <hexaddr> [count]\n";
		sysc(__NR_write, 2, (long)u, slen(u), 0, 0, 0);
		sysc(__NR_exit, 1, 0, 0, 0, 0, 0);
	}
	addr = hexparse(argv[1]);
	if (argc > 2)
		count = hexparse(argv[2]);

	long fd = sysc(__NR_open, (long)"/dev/mem", O_RDONLY, 0, 0, 0, 0);
	if (fd < 0) {
		const char *e = "open /dev/mem failed\n";
		sysc(__NR_write, 2, (long)e, slen(e), 0, 0, 0);
		sysc(__NR_exit, 2, 0, 0, 0, 0, 0);
	}

	/* page-align the mapping and read each word with volatile accesses */
	uint32_t page = addr & ~0xfffu;
	uint32_t off = addr & 0xfffu;
	uint32_t mlen = (off + count * 4 + 0xfff) & ~0xfffu;
	long map = sysc(__NR_mmap2, 0, mlen, PROT_READ, MAP_PRIVATE, fd, page >> 12);
	if (map < 0 && map > -4096) {
		const char *e = "mmap failed\n";
		sysc(__NR_write, 2, (long)e, slen(e), 0, 0, 0);
		sysc(__NR_exit, 3, 0, 0, 0, 0, 0);
	}
	volatile uint32_t *regs = (volatile uint32_t *)(map + off);

	for (i = 0; i < count; i++) {
		char *p = line;
		const char hexd[] = "0123456789abcdef";
		uint32_t v = regs[i];
		int s;
		const char *pre = "0x";
		for (s = 0; s < 2; s++) *p++ = pre[s];
		for (s = 28; s >= 0; s -= 4) {
			*p++ = hexd[(v >> s) & 0xf];
		}
		*p++ = '\n';
		sysc(__NR_write, 1, (long)line, p - line, 0, 0, 0);
	}

	sysc(__NR_close, fd, 0, 0, 0, 0, 0);
	sysc(__NR_exit, 0, 0, 0, 0, 0, 0);
}

__asm__(
".global _start\n"
"_start:\n"
"  mov r0, sp\n"
"  b _start_c\n"
);

// SPDX-License-Identifier: GPL-2.0-only
/* Run only in the synthetic ARM64 QEMU guest, never against a physical board. */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include "np545_power_supply.h"

#define SUPPLY "/sys/class/power_supply/np545-usb-c"
static unsigned int checks;

static void check(int ok, const char *what)
{
	checks++;
	if (!ok) {
		fprintf(stderr, "NP545_POWER_FAIL: %s errno=%d\n", what, errno);
		exit(1);
	}
}

static unsigned long long now(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_BOOTTIME, &ts);
	return (unsigned long long)ts.tv_sec * 1000000000ULL + ts.tv_nsec;
}

static void present(int expected)
{
	int i;
	for (i = 0; i < 300; i++) {
		if ((access(SUPPLY, F_OK) == 0) == expected)
			break;
		usleep(10000);
	}
	check(i < 300, expected ? "supply appears" : "supply removed");
}

static void value(const char *name, const char *expected)
{
	char path[256], buffer[128] = {0};
	int fd;
	ssize_t n;
	struct stat st;

	snprintf(path, sizeof(path), "%s/%s", SUPPLY, name);
	fd = open(path, O_RDONLY);
	check(fd >= 0, name);
	check(fstat(fd, &st) == 0 && !(st.st_mode & 0222), "standard property read-only");
	n = read(fd, buffer, sizeof(buffer) - 1);
	close(fd);
	check(n > 0 && strcmp(buffer, expected) == 0, name);
}

static void send_report(int fd, struct np545_report *r)
{
	r->boottime_ns = now();
	check(write(fd, r, sizeof(*r)) == sizeof(*r), "valid report accepted");
	usleep(100000);
}

int main(void)
{
	struct np545_report r = { .version = 1, .valid = 7, .online = 1,
		.voltage_max_uv = 5000000, .current_max_ua = 3000000,
		.input_limit_ua = 3000000, .charge_voltage_uv = 8400000 };
	struct np545_report bad;
	int fd, second, attr;
	char byte;
	struct stat st;

	present(0);
	check(stat("/dev/np545-power-supply", &st) == 0 && (st.st_mode & 0777) == 0600,
	      "report endpoint root-only");
	fd = open("/dev/np545-power-supply", O_WRONLY);
	check(fd >= 0, "reporter open");
	second = open("/dev/np545-power-supply", O_WRONLY);
	check(second < 0 && errno == EBUSY, "single writer");
	check(write(fd, &r, 1) < 0 && errno == EMSGSIZE, "short frame rejected");
	bad = r; bad.version = 2; bad.boottime_ns = now();
	check(write(fd, &bad, sizeof(bad)) < 0 && errno == EINVAL, "unknown ABI rejected");
	bad = r; bad.valid = 8; bad.boottime_ns = now();
	check(write(fd, &bad, sizeof(bad)) < 0 && errno == EINVAL, "unknown validity bits rejected");
	bad = r; bad.online = 0; bad.boottime_ns = now();
	check(write(fd, &bad, sizeof(bad)) < 0 && errno == EINVAL, "offline contract rejected");
	bad = r; bad.current_max_ua = 0xffffffff; bad.boottime_ns = now();
	check(write(fd, &bad, sizeof(bad)) < 0 && errno == ERANGE, "overflow rejected");
	bad = r; bad.valid = 1; bad.boottime_ns = now();
	check(write(fd, &bad, sizeof(bad)) < 0 && errno == EINVAL, "unflagged data rejected");
	bad = r; bad.boottime_ns = now() + 1000000000ULL;
	check(write(fd, &bad, sizeof(bad)) < 0 && errno == ESTALE, "future sample rejected");
	send_report(fd, &r);
	present(1);
	check(write(fd, &r, sizeof(r)) < 0 && errno == EINVAL, "replay rejected");
	value("type", "USB\n");
	value("online", "1\n");
	value("usb_type", "Unknown [PD]\n");
	value("voltage_max", "5000000\n");
	value("current_max", "3000000\n");
	value("input_current_limit", "3000000\n");
	value("constant_charge_current", "0\n");
	value("constant_charge_voltage", "8400000\n");
	check(access(SUPPLY "/voltage_now", F_OK) < 0, "no invented measured VBUS");
	check(access(SUPPLY "/current_now", F_OK) < 0, "no invented measured IBUS");
	attr = open(SUPPLY "/constant_charge_current", O_WRONLY);
	if (attr >= 0) {
		check(write(attr, "1024000", 7) < 0, "cannot control current through sysfs");
		close(attr);
	} else {
		check(errno == EACCES, "cannot open current property for writing");
	}
	r.voltage_max_uv = 12000000;
	r.charge_current_ua = 1024000;
	r.charge_voltage_uv = 8696000;
	send_report(fd, &r);
	value("constant_charge_current", "1024000\n");
	value("voltage_max", "12000000\n");
	memset(&r, 0, sizeof(r)); r.version = 1; r.valid = 1;
	send_report(fd, &r);
	value("online", "0\n");
	value("usb_type", "[Unknown] PD\n");
	attr = open(SUPPLY "/voltage_max", O_RDONLY);
	check(attr >= 0, "offline optional property exists");
	check(read(attr, &byte, 1) < 0 && errno == ENODATA, "offline limits unavailable");
	close(attr);
	r.valid = 0;
	send_report(fd, &r);
	present(0);
	r.valid = 1; r.online = 1;
	send_report(fd, &r);
	present(1);
	close(fd);
	present(0);
	fd = open("/dev/np545-power-supply", O_WRONLY);
	check(fd >= 0, "reporter can restart");
	send_report(fd, &r);
	present(1);
	sleep(21);
	present(0);
	bad = r;
	check(write(fd, &bad, sizeof(bad)) < 0 && errno == ESTALE, "expired frame rejected");
	send_report(fd, &r);
	present(1);
	close(fd);
	present(0);
	printf("NP545_POWER_PASS checks=%u\n", checks);
	return 0;
}

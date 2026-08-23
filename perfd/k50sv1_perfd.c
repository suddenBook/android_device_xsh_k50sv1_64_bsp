/*
 * k50sv1_perfd - hold the SoC at maximum while the panel is lit, and let the
 *                kernel have it back the moment the panel blanks.
 *
 * WHY THIS EXISTS
 * ===============
 * The owner's requirement is the two extremes: screen on -> everything at
 * maximum, screen off -> rest.  Neither half of that can be expressed inside
 * MediaTek's PPM, and the reasons are worth stating because they are not
 * obvious and both were arrived at by measurement.
 *
 *  1. The Power HAL's INTERACTION hint DOES reach the hardware -- 8 cores,
 *     both clusters at their top OPP -- but the lock is released 235-705 ms
 *     after the hint.  PERF_RES_POWER_HINT_HOLD_TIME is parsed by
 *     libpowerhal (it echoes the value back from updateCusScnTable) and then
 *     does not govern the release; raising it from 5000 to 20000 changed
 *     nothing measurable.  See E-031.
 *
 *  2. No PPM policy can be released by screen-off.  It is tempting to hold a
 *     permanent pin and let PPM_POLICY_LCM_OFF override it when the panel
 *     blanks, because LCM_OFF is applied after every performance policy.  But
 *     ppm_main_update_limit()'s default: branch INTERSECTS overlapping ranges
 *     and takes MAX() of the two minima, and LCM_OFF's range is a superset of
 *     any pin -- so it can narrow a maximum and can never lower a minimum.
 *     Measured: a pin held 8 cores at 1001/1508 MHz for 18 s of screen-off.
 *     See E-032.
 *
 * So the screen-state edge has to come from userspace.  This is that edge, and
 * it is deliberately the smallest thing that can produce it.
 *
 * WHAT IT IS WORTH
 * ================
 * Settings cold start, interleaved baseline/pinned/baseline to rule out cache
 * warmth: 321 ms +-34 becomes 253 ms +-1.3.  21% on the mean, and the spread
 * collapses by a factor of 25 -- on a part this slow the tail is what gets
 * noticed.  See E-033.
 *
 * HOW IT WORKS
 * ============
 * Screen state comes from /sys/class/leds/lcd-backlight/brightness.  On this
 * handset that reads 0 exactly when the panel is blanked and >= 10 otherwise
 * (Android's own minimum is 10, config_screenBrightnessSettingMinimum), so the
 * signal is unambiguous.  poll(POLLPRI) is attempted first in case the LED
 * class ever grows a sysfs_notify; it does not have one today, so in practice
 * this is a 1 Hz poll of a single small file.  That costs one wakeup per
 * second while the device is awake, and none at all while it is suspended:
 * poll() timeouts are CLOCK_MONOTONIC, which does not advance across suspend
 * and is not a wake source.
 *
 * The knob is /proc/ppm/policy/perfserv_perf_idx.  It is the PERF_SERV policy's
 * own interface, and it is NOT the one libpowerhal drives -- the HAL writes
 * /proc/perfmgr/legacy/perfserv_{freq,core}, which reach PPM as PPM_KIR_PERF
 * and land in USER_LIMIT.  Different policy, no collision, and both push the
 * same direction so they compose.  Writing a perf index also moves HICA out of
 * LL_ONLY through ppm_hica_get_state_by_perf_idx(), which is what actually
 * brings the big cluster online; a plain frequency floor does not.
 *
 * The maximum index is read from /proc/ppm/policy/perfserv_max_perf_idx at
 * start rather than hardcoded: it is derived from the per-part power table
 * (5616 on this bin, 78 at the bottom) and a different bin would have a
 * different one.
 *
 * HOW TO REMOVE THIS
 * ==================
 * It is one service and one policy file, and it is meant to be easy to drop
 * once a from-source kernel makes the same behaviour a 20-line change in
 * mt_ppm_policy_lcm_off.c.  To revert:
 *
 *   1. delete this directory and sepolicy/power/k50sv1_perfd.te
 *   2. remove `k50sv1_perfd` from device.mk PRODUCT_PACKAGES
 *   3. remove the `service vendor.k50sv1_perfd` block from
 *      rootdir/etc/init/hw/init.mt6755.rc
 *   4. remove the two perfserv_* lines from sepolicy/power/genfs_contexts
 *
 * Nothing else in the tree references it.  The device returns to the
 * INTERACTION-only behaviour measured in E-031, which is not broken -- it is
 * just not what the owner asked for.
 */

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define LOG_TAG "k50sv1_perfd"
#include <log/log.h>

static const char kBacklight[] = "/sys/class/leds/lcd-backlight/brightness";
static const char kPerfIdx[]   = "/proc/ppm/policy/perfserv_perf_idx";
static const char kMaxIdx[]    = "/proc/ppm/policy/perfserv_max_perf_idx";

/* One second is fast enough on both edges. Going to maximum is already covered
 * for the first fraction of a second by the INTERACTION hint the framework
 * sends at display-on, so the handoff is seamless; and releasing the pin a
 * second late costs a second of idle cores, not a wake. */
#define POLL_MS 1000

/* Read a file whose whole content is a small decimal number, possibly with
 * leading text. Returns -1 on any failure. */
static long read_number(const char *path)
{
    char buf[128];
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        return -1;
    }
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) {
        return -1;
    }
    buf[n] = '\0';

    /* perfserv_max_perf_idx prints a bare number; be tolerant of a "name = N"
     * shape too, which is what perfserv_perf_idx uses on read. */
    const char *p = strrchr(buf, '=');
    p = p ? p + 1 : buf;
    errno = 0;
    char *end = NULL;
    long v = strtol(p, &end, 10);
    if (end == p || errno != 0) {
        return -1;
    }
    return v;
}

static int write_number(const char *path, long value)
{
    char buf[32];
    int len = snprintf(buf, sizeof(buf), "%ld", value);
    if (len <= 0 || (size_t)len >= sizeof(buf)) {
        return -1;
    }
    int fd = open(path, O_WRONLY | O_CLOEXEC);
    if (fd < 0) {
        return -1;
    }
    ssize_t n = write(fd, buf, (size_t)len);
    close(fd);
    return (n == len) ? 0 : -1;
}

int main(void)
{
    long max_idx = read_number(kMaxIdx);
    if (max_idx <= 0) {
        ALOGE("cannot read %s (%s); nothing to pin to, exiting", kMaxIdx, strerror(errno));
        return 1;
    }
    ALOGI("pinning to perf_idx %ld while the panel is lit", max_idx);

    int fd = open(kBacklight, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        ALOGE("cannot open %s (%s), exiting", kBacklight, strerror(errno));
        return 1;
    }

    /* -1 means "no decision yet", so the first observation always writes. */
    int pinned = -1;

    for (;;) {
        char buf[32];
        ssize_t n = pread(fd, buf, sizeof(buf) - 1, 0);
        if (n > 0) {
            buf[n] = '\0';
            int want = (strtol(buf, NULL, 10) > 0) ? 1 : 0;
            if (want != pinned) {
                if (write_number(kPerfIdx, want ? max_idx : 0) == 0) {
                    pinned = want;
                    ALOGI("panel %s -> perf_idx %ld", want ? "on" : "off",
                          want ? max_idx : 0L);
                } else {
                    /* Do not latch a state we failed to apply; retry next tick. */
                    ALOGE("write %s failed: %s", kPerfIdx, strerror(errno));
                }
            }
        }

        /* POLLPRI in case the LED class ever gains a sysfs_notify. It has none
         * today, so this is the 1 Hz timeout path. */
        struct pollfd pfd = { .fd = fd, .events = POLLPRI | POLLERR, .revents = 0 };
        int rc = poll(&pfd, 1, POLL_MS);
        if (rc < 0 && errno != EINTR) {
            ALOGE("poll failed: %s, exiting", strerror(errno));
            close(fd);
            return 1;
        }
    }
}

//
// SPDX-FileCopyrightText: The LineageOS Project
// SPDX-License-Identifier: Apache-2.0
//

#include <android/log.h>
#include <cutils/properties.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define LOG_TAG "wmt_loader"
#define INFO(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define ERROR(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

/* Scalar ioctl arguments, from the source kernel's common_detect/wmt_detect.h. */
#define WMT_SET_CHIP_ID    _IOW('w', 1, int)
#define WMT_GET_SOC_ID     _IOR('w', 3, int)
#define WMT_MODULE_INIT    _IOR('w', 4, int)
#define WMT_MODULE_CLEANUP _IOR('w', 5, int)

#define DETECT_NODE "/dev/wmtdetect"
#define CHIP_PROPERTY "persist.vendor.connsys.chipid"
#define READY_PROPERTY "vendor.connsys.driver.ready"
#define NODE_ATTEMPTS 200
#define NODE_RETRY_US 300000

/* This binary belongs to the K50 MT6755 product, which builds SoC/BTIF support.
 * Preserve the raw ID for WMT; the older silicon alias uses the MT6755 init ID.
 */
static bool supported_chip(unsigned long chip)
{
    return chip == 0x6755 || chip == 0x0326;
}

static bool cached_chip_id(unsigned int *chip)
{
    char value[PROPERTY_VALUE_MAX] = {0};
    char *end;
    unsigned long parsed;

    if (property_get(CHIP_PROPERTY, value, "") <= 0 ||
        !isxdigit((unsigned char)value[0]))
        return false;
    errno = 0;
    parsed = strtoul(value, &end, 16);
    if (errno || *end || parsed > UINT_MAX || !supported_chip(parsed))
        return false;
    *chip = parsed;
    return true;
}

static int open_detector(void)
{
    for (unsigned attempt = 0; attempt < NODE_ATTEMPTS; attempt++) {
        int fd = open(DETECT_NODE, O_RDWR | O_NOCTTY | O_CLOEXEC);
        if (fd >= 0)
            return fd;
        if (errno != ENOENT && errno != ENODEV && errno != EINTR) {
            ERROR("Cannot open %s: %s", DETECT_NODE, strerror(errno));
            return -1;
        }
        if (attempt + 1 < NODE_ATTEMPTS)
            usleep(NODE_RETRY_US);
    }
    ERROR("Timed out waiting for %s", DETECT_NODE);
    errno = ETIMEDOUT;
    return -1;
}

static int initialize_driver(int fd, unsigned int chip)
{
    unsigned long init_chip = chip == 0x0326 ? 0x6755 : chip;
    const unsigned int requests[] = {
        WMT_SET_CHIP_ID, WMT_MODULE_CLEANUP, WMT_MODULE_INIT,
    };
    const char *const names[] = {
        "set chip ID", "clean up detector", "initialize WMT",
    };

    for (unsigned i = 0; i < sizeof(requests) / sizeof(requests[0]); i++) {
        unsigned long argument = i == 0 ? chip : init_chip;
        int result = ioctl(fd, requests[i], argument);
        if (result != 0) {
            ERROR("Failed to %s: result=%d errno=%d", names[i], result,
                  result < 0 ? errno : 0);
            return -1;
        }
    }
    return 0;
}

int main(void)
{
    char ready[PROPERTY_VALUE_MAX] = {0};
    unsigned int chip;
    int status = 1;

    property_get(READY_PROPERTY, ready, "");
    if (!strcmp(ready, "yes")) {
        INFO("WMT is already ready");
        return 0;
    }

    int fd = open_detector();
    if (fd < 0)
        return 1;
    if (!cached_chip_id(&chip)) {
        int detected = ioctl(fd, WMT_GET_SOC_ID, 0UL);
        if (detected < 0 || !supported_chip((unsigned int)detected)) {
            ERROR("Unsupported or unavailable K50 SoC ID: %d", detected);
            goto out;
        }
        chip = detected;
        char value[PROPERTY_VALUE_MAX];
        snprintf(value, sizeof(value), "0x%04x", chip);
        /* The retained launcher reads this property before its kernel fallback.
         * An invalid, nonempty value must not survive a successful initialization.
         */
        if (property_set(CHIP_PROPERTY, value)) {
            ERROR("Cannot publish the detected chip ID: %s", strerror(errno));
            goto out;
        }
    }
    if (initialize_driver(fd, chip))
        goto out;
    if (property_set(READY_PROPERTY, "yes")) {
        ERROR("Cannot publish WMT readiness: %s", strerror(errno));
        goto out;
    }
    INFO("Source WMT loader initialized chip 0x%04x", chip);
    status = 0;
out:
    if (close(fd))
        ERROR("Cannot close %s: %s", DETECT_NODE, strerror(errno));
    return status;
}

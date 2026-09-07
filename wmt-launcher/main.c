// SPDX-License-Identifier: Apache-2.0
#include "firmware.h"
#include "protocol.h"

#include <android/log.h>
#include <cutils/properties.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#if __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error "The paired MT6755 session ioctl uses the target little-endian ABI"
#endif

#define INFO(...) __android_log_print(ANDROID_LOG_INFO, "wmt_launcher", __VA_ARGS__)
#define ERROR(...) __android_log_print(ANDROID_LOG_ERROR, "wmt_launcher", __VA_ARGS__)
#define WMT_NODE "/dev/stpwmt"
#define DRIVER_READY "vendor.connsys.driver.ready"
#define LAUNCHER_READY "vendor.connsys.formeta.ready"
#define CHIP_PROPERTY "persist.vendor.connsys.chipid"
#define FWLOG_PROPERTY "persist.vendor.connsys.fwlog.status"
#define DUMP_PROPERTY "persist.vendor.connsys.dynamic.dump"
#define PATCH_VERSION "persist.vendor.connsys.patch.version"
#define WIFI_VERSION "persist.vendor.connsys.wifi_fw_ver"
#define BT_VERSION "persist.vendor.connsys.bt_fw_ver"
#define WMT_SET_HIF _IOW(0xa0, 5, int)
#define WMT_POWER _IOW(0xa0, 7, int)
#define WMT_CHIP_INFO _IOR(0xa0, 12, int)
#define WMT_KILL_CLEAR _IOW(0xa0, 13, int)
#define WMT_CHIP_ID _IOR(0xa0, 22, int)
#define WMT_FWLOG _IOR(0xa0, 29, int)
#define WMT_DYNAMIC_DUMP _IOR(0xa0, 30, char *)
#define DYNAMIC_DUMP_BYTES 109
#define POLL_INTERVAL_MS 1000

static volatile sig_atomic_t stop_requested;

struct power_task {
    int fd;
    unsigned long argument;
    atomic_bool stopping;
    atomic_bool finished;
    int result;
};

struct log_task {
    int fd;
    unsigned long enabled;
    pthread_t thread;
    atomic_bool stopping;
    atomic_bool finished;
    bool created;
};

struct optional_controls {
    char fwlog[PROPERTY_VALUE_MAX];
    char dump[PROPERTY_VALUE_MAX];
    struct log_task log;
};

static void request_stop(int signal)
{
    (void)signal;
    stop_requested = 1;
}

static void publish(const char *key, const char *value)
{
    if (property_set(key, value))
        ERROR("Cannot publish %s: %s", key, strerror(errno));
}

static bool supported_chip(unsigned long chip)
{
    return chip == 0x6755 || chip == 0x0326;
}

static bool cached_chip(void)
{
    char value[PROPERTY_VALUE_MAX] = {0};
    char *end;
    unsigned long chip;

    if (property_get(CHIP_PROPERTY, value, "") <= 0 ||
        !isxdigit((unsigned char)value[0]))
        return false;
    errno = 0;
    chip = strtoul(value, &end, 16);
    return !errno && !*end && supported_chip(chip);
}

static int open_driver(void)
{
    char ready[PROPERTY_VALUE_MAX];

    while (!stop_requested) {
        property_get(DRIVER_READY, ready, "");
        if (!strcmp(ready, "yes")) {
            int fd = open(WMT_NODE, O_RDWR | O_NOCTTY | O_CLOEXEC);
            if (fd >= 0)
                return fd;
            if (errno != ENOENT && errno != ENODEV && errno != EINTR) {
                ERROR("Cannot open %s: %s", WMT_NODE, strerror(errno));
                return -1;
            }
        }
        usleep(300000);
    }
    errno = EINTR;
    return -1;
}

static int check_chip(int fd)
{
    if (cached_chip())
        return 0;
    while (!stop_requested) {
        int chip = ioctl(fd, WMT_CHIP_ID, 0UL);
        if (chip >= 0)
            return supported_chip((unsigned)chip) ? 0 : -ENODEV;
        if (errno != EAGAIN && errno != ENODEV && errno != EPERM && errno != EINTR)
            return -errno;
        usleep(300000);
    }
    return -EINTR;
}

static void *power_on(void *argument)
{
    struct power_task *task = argument;

    task->result = -ECANCELED;
    for (unsigned attempt = 0; attempt < 20 && !atomic_load(&task->stopping); attempt++) {
        int result = ioctl(task->fd, WMT_POWER, task->argument);
        if (result == 0) {
            task->result = 0;
            INFO("Power initialization completed on attempt %u", attempt + 1);
            break;
        }
        task->result = result < 0 ? -errno : -EIO;
        ERROR("Power attempt %u failed: %d", attempt + 1, task->result);
        if (atomic_load(&task->stopping))
            break;
        if (ioctl(task->fd, WMT_POWER, 0UL) < 0)
            ERROR("Power retry cleanup failed: %s", strerror(errno));
        if (attempt + 1 < 20)
            usleep(1000000);
    }
    atomic_store(&task->finished, true);
    return NULL;
}

static void *set_firmware_log(void *argument)
{
    struct log_task *task = argument;
    /* The paired kernel bounds each ioctl to one ring-drain pass. Keeping
     * the repeat loop here makes a stop safe even before the first ioctl.
     */
    while (!atomic_load(&task->stopping)) {
        if (ioctl(task->fd, WMT_FWLOG, task->enabled) < 0) {
            ERROR("Firmware log control failed: %s", strerror(errno));
            break;
        }
        usleep(100000);
    }
    atomic_store(&task->finished, true);
    return NULL;
}

static int stop_firmware_log(int fd, struct log_task *task)
{
    if (task->created) {
        atomic_store(&task->stopping, true);
        int error = pthread_join(task->thread, NULL);
        if (error)
            return -error;
        task->created = false;
    }
    /* Disable after the last bounded enable finishes, so a late-starting
     * worker cannot overwrite the disable request.
     * This kernel returns 1 for successful disable, and 0 for enable.
     */
    return ioctl(fd, WMT_FWLOG, 0UL) < 0 ? -errno : 0;
}

static void check_optional_controls(int fd, struct optional_controls *controls)
{
    char fwlog[PROPERTY_VALUE_MAX] = {0};
    /* The legacy ioctl copies 109 bytes, beyond Android's 92-byte value buffer. */
    char dump[DYNAMIC_DUMP_BYTES + 1] = {0};

    property_get(FWLOG_PROPERTY, fwlog, "");
    if (!strcmp(fwlog, "yes")) {
        if (controls->log.created && atomic_load(&controls->log.finished)) {
            /* Reap a failed worker before this poll iteration retries it. */
            int error = pthread_join(controls->log.thread, NULL);
            if (error)
                ERROR("Cannot join firmware log worker: %s", strerror(error));
            else
                controls->log.created = false;
        }
        if (!controls->log.created) {
            controls->log.fd = fd;
            controls->log.enabled = 1;
            atomic_store(&controls->log.stopping, false);
            atomic_store(&controls->log.finished, false);
            int error = pthread_create(&controls->log.thread, NULL, set_firmware_log, &controls->log);
            if (error) {
                ERROR("Cannot start firmware log worker: %s", strerror(error));
            } else {
                controls->log.created = true;
                memcpy(controls->fwlog, fwlog, sizeof(controls->fwlog));
            }
        }
    } else if (strcmp(fwlog, controls->fwlog)) {
        int result = stop_firmware_log(fd, &controls->log);
        if (result)
            ERROR("Cannot disable firmware logging: %d", result);
        else
            memcpy(controls->fwlog, fwlog, sizeof(controls->fwlog));
    }
    property_get(DUMP_PROPERTY, dump, "");
    if (strcmp(dump, controls->dump)) {
        if (ioctl(fd, WMT_DYNAMIC_DUMP, (unsigned long)dump) < 0)
            ERROR("Dynamic dump control failed: %s", strerror(errno));
        else
            memcpy(controls->dump, dump, sizeof(controls->dump));
    }
}

static int send_frame(int fd, const uint8_t *frame, size_t size)
{
    ssize_t written;

    do {
        written = write(fd, frame, size);
    } while (written < 0 && errno == EINTR && !stop_requested);
    if (written < 0)
        return -errno;
    return (size_t)written == size ? 0 : -EPROTO;
}

static int handle_command(int fd, const char *directory, const struct wmt_command *command)
{
    uint8_t frame[WMT_CMD2_WRITE_MAX];
    struct wmt_cmd2_record records[WMT_CMD2_PATCH_MAX] = {{0}};
    struct wmt_firmware_result firmware = {.patches = {0}};
    struct wmt_rom_set rom = {0};
    bool normal = !strcmp(command->text, "srh_patch");
    bool is_rom = !strcmp(command->text, "srh_rom_patch");
    size_t count = 0;
    int result = -EOPNOTSUPP;
    int size, chip, version;

    if (normal || is_rom) {
        chip = ioctl(fd, WMT_CHIP_INFO, 0UL);
        if (chip < 0) {
            result = -errno;
        } else if (!supported_chip((unsigned)chip)) {
            result = -ENODEV;
        } else {
            version = ioctl(fd, WMT_CHIP_INFO, 2UL);
            if (version < 0)
                result = -errno;
            else if (version > UINT16_MAX)
                result = -ERANGE;
            else if (normal)
                result = wmt_firmware_search(directory, version, &firmware);
            else
                result = wmt_rom_search(directory, version, &rom);
        }
    }
    if (!result) {
        if (normal) {
            count = firmware.patches.count;
            for (size_t i = 0; i < count; i++) {
                records[i].index = firmware.patches.records[i].sequence;
                memcpy(records[i].address, firmware.patches.records[i].address, 4);
                memcpy(records[i].name, firmware.patches.records[i].name, 256);
            }
        } else {
            for (unsigned type = 0; type < WMT_ROM_TYPES; type++) {
                if (!(rom.seen & (1U << type)))
                    continue;
                records[count].index = type;
                memcpy(records[count].address, rom.records[type].address, 4);
                memcpy(records[count].name, rom.records[type].name, 256);
                count++;
            }
        }
        size = wmt_reply_list(command, normal ? WMT_CMD2_PATCH_LIST : WMT_CMD2_ROM_LIST,
                              records, count, frame, sizeof(frame));
        if (size < 0)
            result = size;
    } else {
        size = 0;
    }
    if (result) {
        ERROR("Command %s transaction=%" PRIu64 " failed: %d",
              command->text, command->transaction, result);
        size = wmt_reply_status(command, result, frame, sizeof(frame));
    }
    if (size < 0)
        return size;
    int sent = send_frame(fd, frame, size);
    if (sent)
        return sent;
    INFO("Accepted %s session=%" PRIu64 " transaction=%" PRIu64 " result=%d records=%zu",
         command->text, command->session, command->transaction, result, count);
    /* These properties describe accepted metadata, not completed downloads.
     * Publishing only after acceptance avoids stale searches changing them.
     */
    if (!result && normal)
        publish(PATCH_VERSION, firmware.versions[0]);
    if (!result && is_rom && rom.has_wifi_version)
        publish(WIFI_VERSION, rom.wifi_version);
    if (!result && is_rom && rom.has_bt_version)
        publish(BT_VERSION, rom.bt_version);
    return 0;
}

static int command_loop(int fd, uint64_t session, const char *directory,
                        struct power_task *power, struct optional_controls *controls)
{
    struct pollfd item = {.fd = fd, .events = POLLIN};
    uint8_t frame[WMT_CMD2_READ_MAX];
    bool power_checked = false;

    while (!stop_requested) {
        if (atomic_load(&power->finished)) {
            if (!power_checked && power->result)
                return power->result;
            power_checked = true;
            check_optional_controls(fd, controls);
        }
        item.revents = 0;
        int ready = poll(&item, 1, POLL_INTERVAL_MS);
        if (ready < 0) {
            if (errno == EINTR)
                continue;
            return -errno;
        }
        if (item.revents & (POLLERR | POLLHUP | POLLNVAL))
            return -ENODEV;
        if (!(item.revents & POLLIN))
            continue;
        ssize_t size = read(fd, frame, sizeof(frame));
        if (size < 0) {
            if (errno == EINTR || errno == EAGAIN || errno == ETIMEDOUT)
                continue;
            return -errno;
        }
        struct wmt_command command;
        int result = wmt_command_decode(frame, size, session, &command);
        if (result)
            return result;
        result = handle_command(fd, directory, &command);
        if (result == -ESTALE || result == -ECANCELED || result == -ETIMEDOUT || result == -ENOENT) {
            INFO("Discarded expired transaction=%" PRIu64 ": %d", command.transaction, result);
            continue;
        }
        if (result)
            return result;
    }
    return 0;
}

int main(int argc, char **argv)
{
    const char *directory = "/vendor/firmware/";
    struct sigaction action = {.sa_handler = request_stop};
    struct wmt_cmd2_session session = {.version = WMT_CMD2_VERSION, .action = WMT_CMD2_BIND};
    struct power_task power = {.argument = 1};
    struct optional_controls controls = {.fwlog = {0}};
    pthread_t power_thread;
    bool bound = false, power_started = false, advertised = false;
    int option, result = -EINTR, fd = -1;

    atomic_init(&power.stopping, false);
    atomic_init(&power.finished, false);
    atomic_init(&controls.log.stopping, false);
    atomic_init(&controls.log.finished, false);
    while ((option = getopt(argc, argv, "p:o:h")) != -1) {
        if (option == 'p') {
            directory = optarg;
        } else if (option == 'o' && (!strcmp(optarg, "0") || !strcmp(optarg, "1"))) {
            power.argument = !strcmp(optarg, "1") ? 2 : 1;
        } else {
            fprintf(option == 'h' ? stdout : stderr, "Usage: wmt_launcher [-p directory] [-o 0|1]\n");
            return option == 'h' ? 0 : 2;
        }
    }
    if (optind != argc || !*directory || strnlen(directory, PATH_MAX) == PATH_MAX)
        return 2;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGTERM, &action, NULL) || sigaction(SIGINT, &action, NULL)) {
        ERROR("Cannot install stop handlers: %s", strerror(errno));
        return 1;
    }
    fd = open_driver();
    if (fd < 0)
        return stop_requested ? 0 : 1;
    result = check_chip(fd);
    if (result)
        goto out;
    if (ioctl(fd, WMT_IOCTL_CMD2_SESSION, (unsigned long)&session) < 0) {
        result = -errno;
        goto out;
    }
    bound = true;
    if (session.version != WMT_CMD2_VERSION || !session.session_id ||
        session.max_read_bytes != WMT_CMD2_READ_MAX || session.max_write_bytes != WMT_CMD2_WRITE_MAX ||
        session.flags || session.reserved) {
        result = -EPROTO;
        goto out;
    }
    if (ioctl(fd, WMT_SET_HIF, 0x23UL) < 0 || ioctl(fd, WMT_KILL_CLEAR, 0UL) < 0) {
        result = -errno;
        goto out;
    }
    if (property_set(LAUNCHER_READY, "yes")) {
        result = -EIO;
        goto out;
    }
    advertised = true;
    power.fd = fd;
    int error = pthread_create(&power_thread, NULL, power_on, &power);
    if (error) {
        result = -error;
        goto out;
    }
    power_started = true;
    INFO("Source launcher ready on session=%" PRIu64, (uint64_t)session.session_id);
    result = command_loop(fd, session.session_id, directory, &power, &controls);
out:
    atomic_store(&power.stopping, true);
    if (bound) {
        struct wmt_cmd2_session unbind = {.version = WMT_CMD2_VERSION,
            .action = WMT_CMD2_UNBIND, .session_id = session.session_id};
        if (ioctl(fd, WMT_IOCTL_CMD2_SESSION, (unsigned long)&unbind) < 0)
            ERROR("Cannot unbind command session: %s", strerror(errno));
    }
    if (power_started) {
        int error = pthread_join(power_thread, NULL);
        if (error)
            ERROR("Cannot join power worker: %s", strerror(error));
    }
    /* A reaped worker still needs a final disable if its replacement failed. */
    if (controls.log.created || !strcmp(controls.fwlog, "yes")) {
        int error = stop_firmware_log(fd, &controls.log);
        if (error)
            ERROR("Cannot stop firmware logging: %d", error);
    }
    if (advertised)
        publish(LAUNCHER_READY, "no");
    if (close(fd))
        ERROR("Cannot close %s: %s", WMT_NODE, strerror(errno));
    if (result && !stop_requested)
        ERROR("Launcher stopped: %d", result);
    return result && !stop_requested ? 1 : 0;
}

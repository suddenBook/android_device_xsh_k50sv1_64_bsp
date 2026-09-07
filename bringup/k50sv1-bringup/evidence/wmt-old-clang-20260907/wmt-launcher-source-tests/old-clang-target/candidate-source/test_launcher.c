// SPDX-License-Identifier: Apache-2.0
/* Execute the complete service with actual pthreads and filesystem discovery.
 * Only Android properties, device syscalls and wait timing are host adapters.
 */
#include "firmware.h"
#include "protocol.h"
#include <android/log.h>
#include <cutils/properties.h>
#include <assert.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

static int host_open(const char *path, int flags, ...);
static int host_close(int fd);
static int host_ioctl(int fd, unsigned long request, ...);
static int host_poll(struct pollfd *items, nfds_t count, int timeout);
static ssize_t host_read(int fd, void *data, size_t size);
static ssize_t host_write(int fd, const void *data, size_t size);
static int host_usleep(useconds_t delay);
static int host_property_get(const char *key, char *value, const char *fallback);
static int host_property_set(const char *key, const char *value);
static int host_sigaction(int signal, const struct sigaction *action, struct sigaction *old);
static int host_thread_create(pthread_t *thread, const pthread_attr_t *attr,
                              void *(*start)(void *), void *argument);
static int host_thread_join(pthread_t thread, void **result);

#define main launcher_entry
#define open host_open
#define close host_close
#define ioctl host_ioctl
#define poll host_poll
#define read host_read
#define write host_write
#define usleep host_usleep
#define property_get host_property_get
#define property_set host_property_set
#define sigaction(...) host_sigaction(__VA_ARGS__)
#define pthread_create host_thread_create
#define pthread_join host_thread_join
#include "main.c"
#undef main
#undef open
#undef close
#undef ioctl
#undef poll
#undef read
#undef write
#undef usleep
#undef property_get
#undef property_set
#undef sigaction
#undef pthread_create
#undef pthread_join

static const uint64_t test_session = UINT64_C(0x0102030405060708);
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed = PTHREAD_COND_INITIALIZER;
static const char *mode;
static struct {
    unsigned ready_reads, opens, closes, chip_reads, binds, unbinds, hif, kill;
    unsigned power_calls, off_calls, power_sleeps, writes, accepted, patch_versions;
    unsigned reads, delivered, frame_done, poll_calls, post_polls, fwlog_calls, dump_calls;
    unsigned ready_yes, ready_no, errors, interrupted_writes, expired_reads;
    unsigned log_enables, log_disables;
    unsigned optional_scans, log_create_attempts, log_creates, log_joins;
    unsigned last_create_scan, last_dump_scan, log_failures, dump_failures;
    bool owner, powered_waiting, power_released, power_created;
    bool log_joinable;
    pthread_t log_thread;
    unsigned long power_argument, fwlog_argument;
    struct power_task *power;
    struct log_task *log;
    uint64_t published_transaction;
} state;

static bool scenario(const char *name)
{
    return !strcmp(mode, name);
}

static bool log_retry_case(void)
{
    return scenario("fw-enable-retry") || scenario("fw-repeated-failure") ||
        scenario("fw-disable-after-failure") || scenario("fw-retry-toggle") ||
        scenario("fw-retry-create-failure") || scenario("fw-retry-shutdown-create-failure") ||
        scenario("fw-retry-late-start") || scenario("fw-disable-retry");
}

static bool dump_retry_case(void)
{
    return scenario("dump-retry-same") || scenario("dump-retry-repeated");
}

static unsigned commands(void)
{
    if (scenario("stale-reply") || scenario("read-expired"))
        return 2;
    return scenario("full-service") ? 3 : 1;
}

static const char *command_text(unsigned index)
{
    if (scenario("full-service") && index == 1)
        return "srh_rom_patch";
    if (scenario("full-service") && index == 2)
        return "update_patch_version";
    return "srh_patch";
}

static void wait_briefly(void)
{
    struct timespec deadline;
    assert(clock_gettime(CLOCK_REALTIME, &deadline) == 0);
    deadline.tv_nsec += 10000000;
    if (deadline.tv_nsec >= 1000000000) {
        deadline.tv_sec++;
        deadline.tv_nsec -= 1000000000;
    }
    int result = pthread_cond_timedwait(&changed, &lock, &deadline);
    assert(!result || result == ETIMEDOUT);
}

int __android_log_print(int priority, const char *tag, const char *format, ...)
{
    (void)tag;
    if (priority == ANDROID_LOG_ERROR) {
        pthread_mutex_lock(&lock);
        state.errors++;
        pthread_mutex_unlock(&lock);
    }
    va_list args;
    va_start(args, format);
    int size = vfprintf(stderr, format, args);
    fputc('\n', stderr);
    va_end(args);
    return size;
}

static int host_open(const char *path, int flags, ...)
{
    assert(!strcmp(path, "/dev/stpwmt"));
    assert(flags == (O_RDWR | O_NOCTTY | O_CLOEXEC));
    state.opens++;
    if (scenario("late-driver") && state.opens < 3) {
        errno = ENOENT;
        return -1;
    }
    if (scenario("open-denied")) {
        errno = EACCES;
        return -1;
    }
    return 73;
}

static int host_close(int fd)
{
    assert(fd == 73 && !state.owner);
    assert(!state.power_created || atomic_load(&state.power->finished));
    assert(!state.log_joinable && state.log_creates == state.log_joins);
    assert(!state.log_creates || state.fwlog_argument == 0);
    state.closes++;
    return 0;
}

static int host_usleep(useconds_t delay)
{
    assert(delay == 300000 || delay == 1000000 || delay == 100000);
    pthread_mutex_lock(&lock);
    if (delay == 1000000)
        state.power_sleeps++;
    pthread_mutex_unlock(&lock);
    if (delay == 100000) {
        struct timespec pause = {.tv_nsec = 1000000};
        nanosleep(&pause, NULL);
    }
    return 0;
}

static int host_property_get(const char *key, char *value, const char *fallback)
{
    const char *text = fallback;
    if (!strcmp(key, DRIVER_READY)) {
        state.ready_reads++;
        text = scenario("late-driver") && state.ready_reads < 3 ? "no" : "yes";
    } else if (!strcmp(key, CHIP_PROPERTY)) {
        text = scenario("chip-fallback") || scenario("unsupported-chip") ? "invalid" : "0x6755";
    } else if (!strcmp(key, FWLOG_PROPERTY)) {
        state.optional_scans++;
        text = scenario("fw-late-start") || scenario("fw-inflight-stop") ? "yes" :
            (scenario("optional-controls") ? (state.post_polls < 2 ? "yes" : "no") : "");
        if (log_retry_case()) {
            text = "yes";
            if (((scenario("fw-disable-after-failure") || scenario("fw-disable-retry")) &&
                 state.optional_scans >= 2) ||
                (scenario("fw-retry-toggle") &&
                 (state.optional_scans == 3 || state.optional_scans >= 6)))
                text = "no";
        }
    } else if (!strcmp(key, DUMP_PROPERTY)) {
        text = scenario("optional-controls") && state.post_polls < 2 ? "0x1/0x2/" : "";
        if (dump_retry_case())
            text = "0x1/0x2/";
    } else {
        assert(!"unexpected property");
    }
    assert(strlen(text) < PROPERTY_VALUE_MAX);
    strcpy(value, text);
    return strlen(text);
}

static int host_property_set(const char *key, const char *value)
{
    pthread_mutex_lock(&lock);
    if (!strcmp(key, LAUNCHER_READY)) {
        if (!strcmp(value, "yes")) {
            assert(state.owner && state.hif && state.kill && !state.power_calls);
            if (scenario("ready-failure")) {
                pthread_mutex_unlock(&lock);
                errno = EACCES;
                return -1;
            }
            state.ready_yes++;
        } else {
            assert(!strcmp(value, "no") && !state.owner);
            state.ready_no++;
        }
    } else if (!strcmp(key, PATCH_VERSION)) {
        assert(state.accepted && !strcmp(value, "20200629194517a"));
        state.patch_versions++;
        state.published_transaction = 100 + state.frame_done;
    } else {
        assert(!"no retained ROM file supplies a version in this integration fixture");
    }
    pthread_mutex_unlock(&lock);
    return 0;
}

static int host_sigaction(int signal, const struct sigaction *action, struct sigaction *old)
{
    assert((signal == SIGINT || signal == SIGTERM) && action && !old);
    return 0;
}

static void *delayed_log_start(void *argument)
{
    struct log_task *task = argument;
    while (!atomic_load(&task->stopping)) {
        struct timespec pause = {.tv_nsec = 1000000};
        nanosleep(&pause, NULL);
    }
    return set_firmware_log(argument);
}

static int host_thread_create(pthread_t *thread, const pthread_attr_t *attr,
                              void *(*start)(void *), void *argument)
{
    if (start == power_on) {
        state.power = argument;
        if (scenario("thread-failure"))
            return EAGAIN;
    }
    if (start == set_firmware_log) {
        pthread_mutex_lock(&lock);
        assert(!state.log_joinable && state.last_create_scan < state.optional_scans);
        state.last_create_scan = state.optional_scans;
        state.log_create_attempts++;
        state.log = argument;
        if ((scenario("fw-retry-create-failure") || scenario("fw-retry-shutdown-create-failure")) &&
            state.log_create_attempts == 2) {
            pthread_mutex_unlock(&lock);
            return EAGAIN;
        }
        if (scenario("fw-late-start") ||
            (scenario("fw-retry-late-start") && state.log_create_attempts == 2))
            start = delayed_log_start;
        int result = pthread_create(thread, attr, start, argument);
        if (!result) {
            state.log_creates++;
            state.log_thread = *thread;
            state.log_joinable = true;
        }
        pthread_mutex_unlock(&lock);
        return result;
    }
    int result = pthread_create(thread, attr, start, argument);
    if (start == power_on && !result)
        state.power_created = true;
    return result;
}

static int host_thread_join(pthread_t thread, void **result)
{
    pthread_mutex_lock(&lock);
    bool log_worker = state.log_joinable && pthread_equal(thread, state.log_thread);
    if (log_worker)
        assert(atomic_load(&state.log->stopping) || atomic_load(&state.log->finished));
    pthread_mutex_unlock(&lock);
    int error = pthread_join(thread, result);
    if (log_worker && !error) {
        pthread_mutex_lock(&lock);
        assert(atomic_load(&state.log->finished));
        state.log_joinable = false;
        state.log_joins++;
        pthread_mutex_unlock(&lock);
    }
    return error;
}

static int host_ioctl(int fd, unsigned long request, ...)
{
    assert(fd == 73);
    va_list args;
    va_start(args, request);
    unsigned long argument = va_arg(args, unsigned long);
    va_end(args);
    int result = 0;
    pthread_mutex_lock(&lock);
    if (request == 0xc020a040UL) {
        struct wmt_cmd2_session *session = (void *)argument;
        assert(session->version == 2 && !session->flags && !session->reserved &&
               !session->max_read_bytes && !session->max_write_bytes);
        if (session->action == 1) {
            state.binds++;
            assert(!session->session_id);
            if (scenario("old-kernel")) {
                errno = ENOTTY;
                result = -1;
            } else {
                state.owner = true;
                session->session_id = test_session;
                session->max_read_bytes = scenario("bad-bind-limits") ? 286 : 287;
                session->max_write_bytes = 2680;
            }
        } else {
            assert(session->action == 2 && state.owner && session->session_id == test_session);
            state.owner = false;
            state.unbinds++;
            pthread_cond_broadcast(&changed);
        }
    } else if (request == 0x8004a016UL) {
        assert(!argument);
        state.chip_reads++;
        if (scenario("chip-fallback") && state.chip_reads == 1) {
            errno = EAGAIN;
            result = -1;
        } else {
            result = scenario("unsupported-chip") ? 0x1234 : 0x6755;
        }
    } else if (request == 0x4004a005UL) {
        assert(state.owner && argument == 0x23);
        state.hif++;
        if (scenario("hif-failure")) {
            errno = EIO;
            result = -1;
        }
    } else if (request == 0x4004a00dUL) {
        assert(state.hif && !argument);
        state.kill++;
        if (scenario("kill-failure")) {
            errno = EIO;
            result = -1;
        }
    } else if (request == 0x4004a007UL) {
        assert(state.ready_yes && state.hif && state.kill);
        if (!argument) {
            state.off_calls++;
        } else {
            assert(argument == (scenario("power-default") ? 1UL : 2UL));
            state.power_argument = argument;
            state.power_calls++;
            if (scenario("power-exhausted") || (scenario("power-retry") && state.power_calls < 3)) {
                errno = EIO;
                result = -1;
            } else {
                state.powered_waiting = true;
                pthread_cond_broadcast(&changed);
                while (state.owner && !state.accepted)
                    wait_briefly();
                state.power_released = true;
                if (!state.accepted) {
                    errno = ECANCELED;
                    result = -1;
                }
            }
        }
    } else if (request == 0x8004a00cUL) {
        assert(argument == 0 || argument == 2);
        result = argument ? 0x8a00 : 0x6755;
    } else if (request == 0x8004a01dUL) {
        assert((scenario("optional-controls") || scenario("fw-late-start") ||
                scenario("fw-inflight-stop") || log_retry_case()) && argument <= 1);
        state.fwlog_calls++;
        state.fwlog_argument = argument;
        result = argument ? 0 : 1;
        if (argument) {
            state.log_enables++;
            pthread_cond_broadcast(&changed);
            if (log_retry_case() && !scenario("fw-disable-retry") &&
                (state.log_enables == 1 || scenario("fw-repeated-failure"))) {
                state.log_failures++;
                errno = EIO;
                result = -1;
            } else if (scenario("fw-inflight-stop") || log_retry_case()) {
                while (!atomic_load(&state.log->stopping))
                    wait_briefly();
            }
        } else {
            assert(!state.log_joinable && state.log_creates == state.log_joins);
            state.log_disables++;
            if (scenario("fw-disable-retry") && state.log_disables == 1) {
                errno = EIO;
                result = -1;
            }
        }
        pthread_cond_broadcast(&changed);
    } else if (request == 0x8008a01eUL) {
        assert(scenario("optional-controls") || dump_retry_case());
        const char *data = (void *)argument;
        assert(!strcmp(data, dump_retry_case() || !state.dump_calls ? "0x1/0x2/" : ""));
        for (size_t i = strlen(data); i < 109; i++)
            assert(data[i] == 0);
        assert(state.last_dump_scan < state.optional_scans);
        state.last_dump_scan = state.optional_scans;
        state.dump_calls++;
        if (dump_retry_case() && (state.dump_calls == 1 || scenario("dump-retry-repeated"))) {
            state.dump_failures++;
            errno = EIO;
            result = -1;
        }
    } else {
        assert(!"unexpected or legacy metadata ioctl");
    }
    pthread_mutex_unlock(&lock);
    return result;
}

static int host_poll(struct pollfd *items, nfds_t count, int timeout)
{
    assert(count == 1 && items[0].fd == 73 && items[0].events == POLLIN && timeout == 1000);
    pthread_mutex_lock(&lock);
    state.poll_calls++;
    assert(state.poll_calls < 1000);
    if (scenario("poll-interrupted") && state.poll_calls == 1) {
        pthread_mutex_unlock(&lock);
        errno = EINTR;
        return -1;
    }
    if (state.frame_done < commands() && state.powered_waiting) {
        items[0].revents = POLLIN;
        pthread_mutex_unlock(&lock);
        return 1;
    }
    if (state.power && atomic_load(&state.power->finished) && state.frame_done >= commands()) {
        state.post_polls++;
        if (log_retry_case() || dump_retry_case()) {
            bool late_start = scenario("fw-retry-late-start") && state.log_creates == 2;
            if (state.log_joinable && !late_start) {
                while (state.log_enables < state.log_creates)
                    wait_briefly();
                if (!scenario("fw-disable-retry") &&
                    (state.log_creates == 1 || scenario("fw-repeated-failure")))
                    while (!atomic_load(&state.log->finished))
                        wait_briefly();
            }
            unsigned limit = scenario("fw-retry-toggle") ? 7 :
                scenario("fw-retry-shutdown-create-failure") ? 2 : 4;
            if (state.optional_scans >= limit)
                stop_requested = 1;
        } else {
            if (scenario("optional-controls") && state.post_polls == 2) {
                while (state.fwlog_calls < 1)
                    wait_briefly();
            }
            if (scenario("fw-inflight-stop") && state.post_polls == 2)
                while (!state.log_enables)
                    wait_briefly();
            if (state.post_polls >= (scenario("optional-controls") ? 4U : 2U))
                stop_requested = 1;
        }
    } else {
        wait_briefly();
    }
    items[0].revents = 0;
    pthread_mutex_unlock(&lock);
    return 0;
}

static ssize_t host_read(int fd, void *data, size_t capacity)
{
    assert(fd == 73 && capacity == 287);
    if (scenario("read-failure")) {
        errno = EIO;
        return -1;
    }
    const char *text = command_text(state.frame_done);
    size_t size = strlen(text);
    uint8_t *bytes = data;
    memset(bytes, 0, 32 + size);
    memcpy(bytes, "WMT2\2\0\1\0", 8);
    for (unsigned i = 0; i < 8; i++) {
        bytes[8 + i] = test_session >> (8 * i);
        bytes[16 + i] = (uint64_t)(101 + state.frame_done) >> (8 * i);
    }
    bytes[24] = size;
    memcpy(bytes + 32, text, size);
    if (scenario("bad-request"))
        bytes[0] = 'X';
    state.reads++;
    if (scenario("read-expired") && !state.expired_reads) {
        state.expired_reads++;
        state.frame_done++;
        errno = ETIMEDOUT;
        return -1;
    }
    state.delivered = state.frame_done + 1;
    return 32 + size;
}

static uint32_t wire32(const uint8_t *bytes)
{
    return (uint32_t)bytes[0] + ((uint32_t)bytes[1] << 8) +
           ((uint32_t)bytes[2] << 16) + ((uint32_t)bytes[3] << 24);
}

static ssize_t host_write(int fd, const void *data, size_t size)
{
    assert(fd == 73);
    const uint8_t *bytes = data;
    pthread_mutex_lock(&lock);
    state.writes++;
    assert(state.owner && state.delivered && size >= 32);
    assert(!memcmp(bytes, "WMT2\2\0", 6));
    uint64_t session = (uint64_t)wire32(bytes + 8) | (uint64_t)wire32(bytes + 12) << 32;
    uint64_t transaction = (uint64_t)wire32(bytes + 16) | (uint64_t)wire32(bytes + 20) << 32;
    assert(session == test_session && transaction == 100 + state.delivered);
    assert(wire32(bytes + 24) == size - 32);
    const char *text = command_text(state.frame_done);
    if (!strcmp(text, "srh_patch")) {
        assert(size == 568 && bytes[6] == 3 && wire32(bytes + 28) == 0);
        assert(wire32(bytes + 32) == 2 && wire32(bytes + 36) == 0);
        assert(wire32(bytes + 40) == 1 && !memcmp(bytes + 44, "\0\0\12\360", 4));
        assert(wire32(bytes + 304) == 2 && !memcmp(bytes + 308, "\0\0\6\0", 4));
        assert(!strcmp((const char *)bytes + 48, "ROMv2_lm_patch_1_1_hdr.bin"));
        assert(!strcmp((const char *)bytes + 312, "ROMv2_lm_patch_1_0_hdr.bin"));
    } else if (!strcmp(text, "srh_rom_patch")) {
        assert(size == 40 && bytes[6] == 4 && !wire32(bytes + 32));
    } else {
        assert(size == 32 && bytes[6] == 2 && (int32_t)wire32(bytes + 28) == -EOPNOTSUPP);
    }
    if (scenario("write-interrupted") && !state.interrupted_writes++) {
        pthread_mutex_unlock(&lock);
        errno = EINTR;
        return -1;
    }
    if (scenario("short-write")) {
        pthread_mutex_unlock(&lock);
        return size - 1;
    }
    if (scenario("write-failure")) {
        pthread_mutex_unlock(&lock);
        errno = EIO;
        return -1;
    }
    state.frame_done++;
    if (scenario("stale-reply") && state.frame_done == 1) {
        assert(!state.patch_versions);
        pthread_mutex_unlock(&lock);
        errno = ESTALE;
        return -1;
    }
    state.accepted++;
    pthread_cond_broadcast(&changed);
    pthread_mutex_unlock(&lock);
    return size;
}

int main(int argc, char **argv)
{
    assert(argc == 3);
    mode = argv[1];
    char *arguments[] = {"wmt_launcher", "-p", argv[2], "-o", "1", NULL};
    if (scenario("power-default"))
        arguments[4] = "0";
    int result = launcher_entry(5, arguments);
    bool fail = scenario("open-denied") || scenario("unsupported-chip") || scenario("old-kernel") ||
        scenario("bad-bind-limits") || scenario("hif-failure") || scenario("kill-failure") ||
        scenario("ready-failure") || scenario("thread-failure") || scenario("power-exhausted") ||
        scenario("short-write") || scenario("bad-request") || scenario("read-failure") || scenario("write-failure");
    assert(result == (fail ? 1 : 0));
    assert(!state.owner && state.closes == (scenario("open-denied") ? 0U : 1U));
    assert(state.ready_yes == state.ready_no);
    if (!fail) {
        assert(state.accepted == commands() -
               (scenario("stale-reply") || scenario("read-expired") ? 1U : 0U));
        assert(state.patch_versions == 1);
        assert(state.power_calls == (scenario("power-retry") ? 3U : 1U));
        assert(state.unbinds == 1 && state.power_released);
    } else {
        assert(!state.accepted && !state.patch_versions);
    }
    if (scenario("late-driver"))
        assert(state.ready_reads == 5 && state.opens == 3);
    if (scenario("chip-fallback"))
        assert(state.chip_reads == 2);
    if (scenario("stale-reply") || scenario("read-expired"))
        assert(state.published_transaction == 102);
    if (scenario("power-exhausted"))
        assert(state.power_calls == 20 && state.off_calls == 20 && state.power_sleeps == 19);
    if (scenario("power-retry"))
        assert(state.off_calls == 2 && state.power_sleeps == 2);
    if (scenario("optional-controls"))
        assert(state.fwlog_calls >= 2 && state.fwlog_argument == 0 && state.dump_calls == 2);
    if (scenario("fw-late-start"))
        assert(state.log_enables == 0 && state.log_disables == 1);
    if (scenario("fw-inflight-stop"))
        assert(state.log_enables == 1 && state.log_disables == 1);
    if (scenario("dump-retry-same"))
        assert(state.dump_calls == 2 && state.dump_failures == 1);
    if (scenario("dump-retry-repeated"))
        assert(state.dump_calls == 4 && state.dump_failures == 4);
    if (scenario("fw-enable-retry"))
        assert(state.log_creates == 2 && state.log_enables == 2 && state.log_failures == 1 &&
               state.log_disables == 1);
    if (scenario("fw-repeated-failure"))
        assert(state.log_creates == 4 && state.log_enables == 4 && state.log_failures == 4 &&
               state.log_disables == 1);
    if (scenario("fw-disable-after-failure"))
        assert(state.log_creates == 1 && state.log_failures == 1 && state.log_disables == 1);
    if (scenario("fw-retry-toggle"))
        assert(state.log_creates == 3 && state.log_enables == 3 && state.log_failures == 1 &&
               state.log_disables == 2);
    if (scenario("fw-retry-create-failure"))
        assert(state.log_create_attempts == 3 && state.log_creates == 2 && state.log_enables == 2 &&
               state.log_failures == 1 && state.log_disables == 1);
    if (scenario("fw-retry-shutdown-create-failure"))
        assert(state.log_create_attempts == 2 && state.log_creates == 1 && state.log_failures == 1 &&
               state.log_disables == 1);
    if (scenario("fw-retry-late-start"))
        assert(state.log_creates == 2 && state.log_enables == 1 && state.log_disables == 1);
    if (scenario("fw-disable-retry"))
        assert(state.log_creates == 1 && state.log_enables == 1 && state.log_disables == 2);
    printf("PASS %s writes=%u accepted=%u version_publications=%u power_calls=%u\n",
           mode, state.writes, state.accepted, state.patch_versions, state.power_calls);
    if (log_retry_case() || dump_retry_case())
        printf("optional_scans=%u dump_calls=%u dump_failures=%u log_create_attempts=%u "
               "log_creates=%u log_joins=%u log_enables=%u log_failures=%u log_disables=%u\n",
               state.optional_scans, state.dump_calls, state.dump_failures, state.log_create_attempts,
               state.log_creates, state.log_joins, state.log_enables, state.log_failures, state.log_disables);
    return 0;
}

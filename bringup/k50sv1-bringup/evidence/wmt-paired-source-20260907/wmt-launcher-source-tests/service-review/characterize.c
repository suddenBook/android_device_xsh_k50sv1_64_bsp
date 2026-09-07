/* Host-only characterization of the exact initial service source. */
#define main reviewed_launcher_main
#include "initial-sources/main.c"
#undef main

#include <assert.h>
#include <stdarg.h>
#include <time.h>

static pthread_mutex_t model_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t model_changed = PTHREAD_COND_INITIALIZER;
static bool enable_entered, release_enable;
static unsigned enable_calls, disable_calls, poll_calls;
static char desired_fwlog[4] = "yes";
static int read_error;

int __android_log_print(int priority, const char *tag, const char *format, ...)
{
    (void)priority;
    (void)tag;
    (void)format;
    return 0;
}

int property_get(const char *key, char *value, const char *fallback)
{
    const char *text = fallback;
    int length;

    pthread_mutex_lock(&model_lock);
    if (!strcmp(key, FWLOG_PROPERTY))
        text = desired_fwlog;
    else if (!strcmp(key, DUMP_PROPERTY))
        text = "";
    length = snprintf(value, PROPERTY_VALUE_MAX, "%s", text);
    pthread_mutex_unlock(&model_lock);
    assert(length >= 0 && length < PROPERTY_VALUE_MAX);
    return length;
}

int property_set(const char *key, const char *value)
{
    (void)key;
    (void)value;
    return 0;
}

int __wrap_ioctl(int fd, unsigned long request, ...)
{
    va_list arguments;
    unsigned long enabled;

    assert(fd == 7 && request == WMT_FWLOG);
    va_start(arguments, request);
    enabled = va_arg(arguments, unsigned long);
    va_end(arguments);
    pthread_mutex_lock(&model_lock);
    if (enabled) {
        enable_calls++;
        enable_entered = true;
        pthread_cond_broadcast(&model_changed);
        /* The retained kernel loops continuously after a successful enable.
         * This explicit test-only release permits the host test to clean up.
         */
        while (!release_enable)
            pthread_cond_wait(&model_changed, &model_lock);
    } else {
        disable_calls++;
    }
    pthread_mutex_unlock(&model_lock);
    return enabled ? 0 : 1;
}

int __wrap_poll(struct pollfd *items, nfds_t count, int timeout)
{
    assert(count == 1 && items[0].fd == 7 && timeout == POLL_INTERVAL_MS);
    poll_calls++;
    if (poll_calls == 1) {
        items[0].revents = POLLIN;
        return 1;
    }
    items[0].revents = 0;
    stop_requested = 1;
    return 0;
}

ssize_t __wrap_read(int fd, void *buffer, size_t size)
{
    assert(fd == 7 && size == WMT_CMD2_READ_MAX);
    /* Bytes copied during an expired request are not a committed delivery. */
    memset(buffer, 0xa5, size);
    errno = read_error;
    return -1;
}

static void check_held_log(void)
{
    struct optional_controls controls = {0};
    struct timespec deadline;

    atomic_init(&controls.log.finished, false);
    check_optional_controls(7, &controls);
    assert(controls.log.created);
    assert(clock_gettime(CLOCK_REALTIME, &deadline) == 0);
    deadline.tv_sec++;
    pthread_mutex_lock(&model_lock);
    while (!enable_entered)
        assert(pthread_cond_timedwait(&model_changed, &model_lock, &deadline) == 0);
    memcpy(desired_fwlog, "no", 3);
    pthread_mutex_unlock(&model_lock);
    check_optional_controls(7, &controls);
    pthread_mutex_lock(&model_lock);
    assert(enable_calls == 1 && disable_calls == 0);
    assert(!atomic_load(&controls.log.finished));
    assert(!strcmp(controls.fwlog, "yes"));
    printf("{\"case\":\"held-enable-then-disable\",\"enable_calls\":%u,"
           "\"disable_calls\":%u,\"worker_finished\":false,"
           "\"desired\":\"no\",\"cached\":\"yes\",\"bug_reproduced\":true}\n",
           enable_calls, disable_calls);
    release_enable = true;
    pthread_cond_broadcast(&model_changed);
    pthread_mutex_unlock(&model_lock);
    assert(pthread_join(controls.log.thread, NULL) == 0);
}

static void check_read_retirement(int error, int expected, unsigned expected_polls)
{
    struct power_task power = {0};
    struct optional_controls controls = {0};
    int result;

    atomic_init(&power.stopping, false);
    atomic_init(&power.finished, false);
    atomic_init(&controls.log.finished, false);
    stop_requested = 0;
    read_error = error;
    poll_calls = 0;
    result = command_loop(7, 123, "/unused", &power, &controls);
    assert(result == expected && poll_calls == expected_polls);
    printf("{\"case\":\"read-retirement\",\"errno\":%d,\"loop_result\":%d,"
           "\"poll_calls\":%u,\"session_loop_survives\":%s}\n",
           error, result, poll_calls, result == 0 ? "true" : "false");
}

int main(void)
{
    check_held_log();
    check_read_retirement(EAGAIN, 0, 2);
    check_read_retirement(ETIMEDOUT, -ETIMEDOUT, 1);
    return 0;
}

/* Complete service and real kernel VFS/broker/metadata, linked as separate units.
 * Only Android properties, HIF/power hardware and wait timing are host models.
 */
#include <android/log.h>
#include <cutils/properties.h>
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

void pair_init(void);
int pair_open(void), pair_close(void), pair_command(const char *);
long pair_ioctl(unsigned long, unsigned long);
ssize_t pair_read(void *, size_t), pair_write(const void *, size_t);
unsigned pair_poll(void);
void pair_cancel(void), pair_empty(void), pair_cleanup(void);
void pair_patch(unsigned, const char *, const unsigned char [4]);
void pair_rom(unsigned, const char *, const unsigned char [4]);

static int host_open(const char *, int, ...), host_close(int);
static int host_ioctl(int, unsigned long, ...);
static int host_poll(struct pollfd *, nfds_t, int);
static ssize_t host_read(int, void *, size_t), host_write(int, const void *, size_t);
static int host_usleep(useconds_t);
static int host_property_get(const char *, char *, const char *);
static int host_property_set(const char *, const char *);
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

#include "expected_firmware.h"
static const char *mode;
static atomic_bool producer_finished;
static unsigned writes, accepted, stale, version_sets, ready_yes, ready_no;
static uint64_t previous_transaction;
static uint8_t saved[WMT_CMD2_WRITE_MAX];
static size_t saved_size;
static bool is_mode(const char *name) { return !strcmp(name, mode); }
static long posix(long value)
{
    if (value < 0) { errno = -value; return -1; }
    return value;
}
int __android_log_print(int priority, const char *tag, const char *format, ...)
{
    (void)priority; (void)tag;
    va_list arguments;
    va_start(arguments, format);
    int result = vfprintf(stderr, format, arguments);
    va_end(arguments);
    fputc('\n', stderr);
    return result;
}
static int host_open(const char *name, int flags, ...)
{
    assert(!strcmp(name, WMT_NODE));
    assert(flags == (O_RDWR | O_NOCTTY | O_CLOEXEC));
    assert(pair_open() == 0);
    return 73;
}
static int host_close(int fd) { assert(fd == 73); return posix(pair_close()); }
static int host_property_get(const char *name, char *value, const char *fallback)
{
    const char *answer = fallback;
    if (!strcmp(name, DRIVER_READY)) answer = "yes";
    else if (!strcmp(name, CHIP_PROPERTY)) answer = "6755";
    strcpy(value, answer);
    return strlen(value);
}
static int host_property_set(const char *name, const char *value)
{
    if (!strcmp(name, LAUNCHER_READY)) {
        if (!strcmp(value, "yes")) ready_yes++;
        else { assert(!strcmp(value, "no")); ready_no++; }
    } else if (!strcmp(name, PATCH_VERSION)) {
        assert(!strcmp(value, expected_version));
        version_sets++;
    } else {
        assert(0 && "Unexpected property publication");
    }
    return 0;
}
static void check_real_patches(void)
{
    for (unsigned i = 0; i < 2; i++)
        pair_patch(i + 1, expected_names[i], expected_addresses[i]);
}
static int power_commands(void)
{
    int result = pair_command("srh_patch");
    if (is_mode("cancel-first")) {
        assert(result == -ECANCELED);
        pair_empty();
        result = pair_command("srh_patch");
    }
    if (is_mode("close-pending")) {
        assert(result == -ECONNRESET);
        pair_empty();
        atomic_store(&producer_finished, true);
        return 0;
    }
    if (is_mode("missing-firmware")) {
        assert(result == -ENOENT);
        pair_empty();
    } else {
        assert(result == 0);
        check_real_patches();
    }
    if (is_mode("duplicate")) {
        assert(pair_command("srh_patch") == 0);
        check_real_patches();
    }
    assert(pair_command("srh_rom_patch") == 0);
    for (unsigned i = 0; i < 5; i++) {
        unsigned char address[] = {0, 0x21, 0x32, 0x40};
        char name[64];
        snprintf(name, sizeof(name), "soc1_0_ram_integration_%u.bin", i);
        pair_rom(i, is_mode("all-rom") ? name : NULL, address);
    }
    assert(pair_command("unknown_pair_command") == -EOPNOTSUPP);
    atomic_store(&producer_finished, true);
    return 0;
}
static int host_ioctl(int fd, unsigned long command, ...)
{
    assert(fd == 73);
    va_list arguments;
    va_start(arguments, command);
    unsigned long argument = va_arg(arguments, unsigned long);
    va_end(arguments);
    if (command == WMT_POWER) { assert(argument == 2); return power_commands(); }
    if (command == WMT_SET_HIF) { assert(argument == 0x23); return 0; }
    return posix(pair_ioctl(command, argument));
}
static int host_poll(struct pollfd *items, nfds_t count, int timeout)
{
    assert(count == 1 && items[0].fd == 73 && timeout == 1000);
    if (atomic_load(&producer_finished)) {
        request_stop(SIGTERM);
        items[0].revents = 0;
        return 0;
    }
    items[0].revents = pair_poll();
    if (is_mode("close-pending") && (items[0].revents & POLLIN)) {
        request_stop(SIGTERM);
        items[0].revents = 0;
    }
    if (!items[0].revents) usleep(1000);
    return items[0].revents != 0;
}
static ssize_t host_read(int fd, void *data, size_t size)
{
    assert(fd == 73);
    ssize_t result = pair_read(data, size);
    if (result > 0) {
        struct wmt_cmd2_header header;
        memcpy(&header, data, sizeof(header));
        assert(header.transaction_id > previous_transaction);
        previous_transaction = header.transaction_id;
    }
    return posix(result);
}
static ssize_t host_write(int fd, const void *data, size_t size)
{
    assert(fd == 73 && size <= sizeof(saved));
    writes++;
    if (is_mode("cancel-first") && writes == 1) pair_cancel();
    if (is_mode("duplicate") && writes == 2) {
        assert(pair_write(saved, saved_size) == -ESTALE);
        stale++;
        check_real_patches();
    }
    ssize_t result = pair_write(data, size);
    if (is_mode("cancel-first") && writes == 1) {
        assert(result == -ESTALE);
        stale++;
    } else {
        assert(result == (ssize_t)size);
        accepted++;
    }
    if (writes == 1) { memcpy(saved, data, size); saved_size = size; }
    return posix(result);
}
static int host_usleep(useconds_t delay) { (void)delay; return usleep(1000); }
int main(int argc, char **argv)
{
    assert(argc == 3);
    mode = argv[1];
    pair_init();
    char *arguments[] = {"wmt_launcher", "-p", argv[2], "-o", "1", NULL};
    assert(launcher_entry(5, arguments) == 0);
    assert(atomic_load(&producer_finished));
    assert(ready_yes == 1 && ready_no == 1);
    assert(version_sets == (is_mode("close-pending") || is_mode("missing-firmware") ? 0U :
                            is_mode("duplicate") ? 2U : 1U));
    assert(stale == (is_mode("cancel-first") || is_mode("duplicate") ? 1U : 0U));
    assert(accepted == (is_mode("close-pending") ? 0U : is_mode("duplicate") ? 4U : 3U));
    pair_cleanup();
    printf("PASS %s: accepted=%u stale=%u published=%u; cache consumers and cleanup checked\n",
           mode, accepted, stale, version_sets);
    return 0;
}

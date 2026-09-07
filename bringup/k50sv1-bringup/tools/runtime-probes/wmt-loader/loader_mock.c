/* Native behavioral fixture for the original K50 WMT loader.
 * Imported device/property operations are simulated. A seccomp filter denies
 * their real syscall paths, including property-service sockets, if a binding
 * unexpectedly bypasses an interposer. No driver is opened or initialized.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <stddef.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <unistd.h>

#define MOCK_FD 1111
#define PROP_SIZE 92
static const char *scenario;
static unsigned open_calls, cleanup_calls, init_calls, sleep_calls, detect_calls;
static char chip[PROP_SIZE], ready[PROP_SIZE];
static bool active;
static bool bootstrap_read_fds[64];
static void fixture_result(void);

static bool is_case(const char *value)
{
    return scenario && strcmp(scenario, value) == 0;
}

__attribute__((constructor)) static void fixture_init(void)
{
    scenario = getenv("WMT_FIXTURE_CASE");
    if (!scenario) _exit(91);
    strcpy(ready, is_case("already-ready") ? "yes" : "no");
    if (!is_case("detect") && !is_case("detect-failure") &&
        !is_case("detect-wrong-chip") && !is_case("chip-property-failure"))
        strcpy(chip, is_case("invalid-property") ? "garbage" : "0x6755");
    if (is_case("alias-property")) strcpy(chip, "0x0326");
    if (is_case("bare-property")) strcpy(chip, "6755");
    if (is_case("uppercase-property")) strcpy(chip, "0X6755");
    if (is_case("suffix-property")) strcpy(chip, "0x6755junk");
    if (is_case("overflow-property")) strcpy(chip, "0x10000000000006755");
    if (is_case("negative-property")) strcpy(chip, "-6755");
    if (is_case("other-property")) strcpy(chip, "0x6765");

#define DENY_SYSCALL(number) \
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, number, 0, 1), \
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | EPERM)
    struct sock_filter instructions[] = {
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, arch)),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, AUDIT_ARCH_AARCH64, 1, 0),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL),
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
        DENY_SYSCALL(__NR_ioctl),
        DENY_SYSCALL(__NR_openat),
        DENY_SYSCALL(__NR_fchown),
        DENY_SYSCALL(__NR_fchownat),
        DENY_SYSCALL(__NR_socket),
        DENY_SYSCALL(__NR_socketpair),
        DENY_SYSCALL(__NR_connect),
        DENY_SYSCALL(__NR_sendto),
        DENY_SYSCALL(__NR_sendmsg),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
    };
    struct sock_fprog filter = {
        .len = sizeof(instructions) / sizeof(instructions[0]),
        .filter = instructions,
    };
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) ||
        prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &filter)) {
        dprintf(2, "SANDBOX_FAILED errno=%d\n", errno);
        _exit(90);
    }
    /* Prove denied fallback calls before permitting the binary to enter main. */
    errno = 0;
    if (syscall(__NR_ioctl, MOCK_FD, 0, 0) != -1 || errno != EPERM)
        _exit(92);
    errno = 0;
    if (syscall(__NR_socket, 1, 1, 0) != -1 || errno != EPERM)
        _exit(93);
    errno = 0;
    if (syscall(__NR_openat, AT_FDCWD, "/dev/wmtdetect", O_RDWR, 0) != -1 ||
        errno != EPERM)
        _exit(94);
    active = true;
    if (atexit(fixture_result)) _exit(90);
    dprintf(1, "SANDBOX_READY case=%s real_ioctl_socket_open_denied=1\n", scenario);
}

static void fixture_result(void)
{
    if (active)
        dprintf(1, "FINAL case=%s open=%u cleanup=%u init=%u detect=%u sleep=%u ready=%s chip=%s\n",
                scenario, open_calls, cleanup_calls, init_calls, detect_calls,
                sleep_calls, ready, chip);
}

int property_get(const char *key, char *value, const char *fallback)
{
    (void)fallback;
    if (!active) { value[0] = 0; return 0; }
    const char *result;
    if (!strcmp(key, "vendor.connsys.driver.ready")) result = ready;
    else if (!strcmp(key, "persist.vendor.connsys.chipid")) result = chip;
    else {
        dprintf(2, "UNEXPECTED_PROPERTY_GET %s\n", key);
        _exit(95);
    }
    snprintf(value, PROP_SIZE, "%s", result);
    dprintf(1, "GET %s %s\n", key, result);
    return strlen(result);
}

int property_set(const char *key, const char *value)
{
    char *destination;
    if (!strcmp(key, "vendor.connsys.driver.ready")) destination = ready;
    else if (!strcmp(key, "persist.vendor.connsys.chipid")) destination = chip;
    else {
        dprintf(2, "UNEXPECTED_PROPERTY_SET %s\n", key);
        _exit(96);
    }
    dprintf(1, "SET %s %s\n", key, value);
    if (is_case("property-failure") ||
        (is_case("chip-property-failure") && destination == chip)) {
        errno = EIO;
        return -1;
    }
    snprintf(destination, PROP_SIZE, "%s", value);
    return 0;
}

int __open_2(const char *path, int flags)
{
    /* The allocator and libcutils read configuration before this constructor.
     * Main runs after the mandatory syscall filter has been installed. */
    if (!active) {
        if ((flags & O_ACCMODE) != O_RDONLY ||
            (strcmp(path, "/sys/kernel/mm/transparent_hugepage/enabled") &&
             strcmp(path, "/dev/__properties__") &&
             strncmp(path, "/dev/__properties__/", sizeof("/dev/__properties__/") - 1))) {
            dprintf(2, "BOOTSTRAP_DENIED path=%s flags=%x\n", path, flags);
            _exit(97);
        }
        int fd = syscall(__NR_openat, AT_FDCWD, path, flags, 0);
        if (fd >= 0) {
            if ((unsigned)fd >= sizeof(bootstrap_read_fds)) _exit(97);
            bootstrap_read_fds[fd] = true;
        }
        return fd;
    }
    dprintf(1, "OPEN %s flags=%x\n", path, flags);
    open_calls++;
    if (strcmp(path, "/dev/wmtdetect")) _exit(97);
    if (is_case("open-permission")) { errno = EACCES; return -1; }
    if (is_case("open-failure") || (is_case("open-retry") && open_calls < 4)) {
        errno = ENOENT;
        return -1;
    }
    return MOCK_FD;
}

int open(const char *path, int flags, ...)
{
    return __open_2(path, flags);
}

int ioctl(int fd, int request, ...)
{
    unsigned command = (unsigned)request;
    /* Scalar parameters are only read for ioctls whose call sites provide one. */
    unsigned long argument = 0;
    if (command == 0x40047701 || command == 0x80047704 ||
        command == 0x80047705 || command == 0x80047708) {
        va_list args;
        va_start(args, request);
        argument = va_arg(args, unsigned long);
        va_end(args);
    }
    dprintf(1, "IOCTL fd=%d command=%08x argument=%lx\n", fd, command, argument);
    if (fd != MOCK_FD) _exit(98);
    switch (command) {
    case 0x80047706: /* The K50 kernel builds only SoC support. */
        errno = EPERM;
        return -1;
    case 0x80047703:
        detect_calls++;
        if (is_case("detect-failure")) { errno = ENODEV; return -1; }
        if (is_case("detect-wrong-chip")) return 0x6765;
        return 0x6755;
    case 0x40047701:
        if (is_case("set-id-failure")) { errno = EIO; return -1; }
        return 0;
    case 0x80047705:
        cleanup_calls++;
        if (is_case("cleanup-failure")) { errno = EIO; return -1; }
        if (is_case("positive-failure")) return 2;
        return 0;
    case 0x80047704:
        init_calls++;
        if (is_case("init-failure")) { errno = EIO; return -1; }
        return 0;
    default:
        dprintf(2, "UNEXPECTED_IOCTL %08x\n", command);
        _exit(99);
    }
}

int close(int fd)
{
    if (fd >= 0 && (unsigned)fd < sizeof(bootstrap_read_fds) &&
        bootstrap_read_fds[fd]) {
        bootstrap_read_fds[fd] = false;
        return syscall(__NR_close, fd);
    }
    if (fd != MOCK_FD) { errno = EBADF; return -1; }
    dprintf(1, "CLOSE %d\n", fd);
    if (is_case("close-failure")) { errno = EIO; return -1; }
    return 0;
}

int chown(const char *path, uid_t uid, gid_t gid)
{
    dprintf(1, "CHOWN %s uid=%u gid=%u simulated_errno=EPERM\n", path, uid, gid);
    errno = EPERM; /* Matches the service's system UID and root-owned proc files. */
    return -1;
}

int usleep(useconds_t duration)
{
    dprintf(1, "SLEEP requested_us=%u\n", duration);
    if (++sleep_calls > 250) {
        dprintf(1, "FIXTURE_RETRY_BUDGET_REACHED\n");
        _exit(88);
    }
    return 0;
}

int __android_log_print(int priority, const char *tag, const char *format, ...)
{
    va_list args;
    dprintf(1, "LOG priority=%d tag=%s ", priority, tag);
    va_start(args, format);
    int length = vdprintf(1, format, args);
    va_end(args);
    if (!strchr(format, '\n')) dprintf(1, "\n");
    return length;
}

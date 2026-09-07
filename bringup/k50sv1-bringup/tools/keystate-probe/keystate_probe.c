/*
 * keystate-probe -- read the kernel's authoritative key bitmap for every
 * /dev/input/event* node via EVIOCGKEY, alongside each device's name and its
 * advertised EV_KEY capabilities.
 *
 * This is the one datum shell tools on the handset cannot produce. `getevent`
 * shows only transitions, and `dumpsys input` shows only what InputReader
 * believes. When Volume Up appears latched down, the question is whether the
 * *kernel* still has the bit set (hardware or driver fault) or whether only
 * userspace is out of sync (framework fault). EVIOCGKEY answers that directly,
 * per device, which also separates the two candidates on this handset:
 * mtk-kpd (the real matrix keypad) and ACCDET (the PMIC jack-detect comparator
 * on a chassis with no jack).
 *
 * Strictly read-only: every ioctl is a get, and no event is injected.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define BITS_PER_LONG ((int)(8 * sizeof(unsigned long)))
#define NLONGS(n) (((n) + BITS_PER_LONG - 1) / BITS_PER_LONG)
#define MAX_NODES 64
#define NAME_MAX_LEN 32

static int test_bit(const unsigned long *map, int bit) {
    return (int)((map[bit / BITS_PER_LONG] >> (bit % BITS_PER_LONG)) & 1UL);
}

/* Only the codes the drivers on this handset actually advertise. */
static const struct {
    int code;
    const char *name;
} kKeyNames[] = {
    {KEY_HOME, "KEY_HOME"},
    {KEY_VOLUMEDOWN, "KEY_VOLUMEDOWN"},
    {KEY_VOLUMEUP, "KEY_VOLUMEUP"},
    {KEY_POWER, "KEY_POWER"},
    {KEY_SLEEP, "KEY_SLEEP"},
    {KEY_WAKEUP, "KEY_WAKEUP"},
    {KEY_PLAYPAUSE, "KEY_PLAYPAUSE"},
    {KEY_VOICECOMMAND, "KEY_VOICECOMMAND"},
    {KEY_RESTART, "KEY_RESTART"},
};

static const char *key_name(int code) {
    for (size_t i = 0; i < sizeof(kKeyNames) / sizeof(kKeyNames[0]); ++i) {
        if (kKeyNames[i].code == code) {
            return kKeyNames[i].name;
        }
    }
    return "(other)";
}

static int compare_names(const void *a, const void *b) {
    return strcmp((const char *)a, (const char *)b);
}

struct probe_result {
    int examined;   /* EVIOCGKEY answered, so this node's bitmap was read */
    int down;       /* codes asserted in that bitmap */
    int undeclared; /* codes asserted that EVIOCGBIT does not advertise */
};

static struct probe_result probe(const char *path) {
    struct probe_result result = {0, 0, 0};
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        printf("%s: open failed: %s\n", path, strerror(errno));
        return result;
    }

    char name[128];
    memset(name, 0, sizeof(name));
    if (ioctl(fd, EVIOCGNAME(sizeof(name) - 1), name) < 0) {
        snprintf(name, sizeof(name), "?");
    }

    unsigned long caps[NLONGS(KEY_MAX + 1)];
    unsigned long state[NLONGS(KEY_MAX + 1)];
    memset(caps, 0, sizeof(caps));
    memset(state, 0, sizeof(state));

    printf("%s  name=\"%s\"\n", path, name);
    int have_caps = ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(caps)), caps) >= 0;
    if (ioctl(fd, EVIOCGKEY(sizeof(state)), state) < 0) {
        printf("    EVIOCGKEY failed: %s\n", strerror(errno));
        close(fd);
        return result;
    }
    result.examined = 1;
    if (!have_caps) {
        printf("    EVIOCGBIT(EV_KEY) failed; reading the key state alone\n");
    }

    /*
     * Walk the STATE bitmap, not the capability bitmap.
     *
     * The scan used to `continue` on any code EVIOCGBIT did not advertise, so a
     * key latched at an undeclared code was never even looked at -- and a driver
     * asserting a code it never declared is exactly the class of driver fault
     * this tool exists to catch. A code is printed when it is declared or when
     * it is down, and a down-but-undeclared code is called out by name.
     */
    for (int code = 0; code <= KEY_MAX; ++code) {
        int declared = have_caps && test_bit(caps, code);
        int is_down = test_bit(state, code);
        if (!declared && !is_down) {
            continue;
        }
        result.down += is_down;
        if (is_down && !declared) {
            result.undeclared++;
        }
        printf("    %-16s code=%-4d %s%s\n", key_name(code), code,
               is_down ? "DOWN  <== asserted in the kernel bitmap" : "up",
               (is_down && !declared)
                   ? "  <== at a code this driver does not advertise"
                   : "");
    }
    printf("    %d key(s) asserted on this device", result.down);
    if (result.undeclared > 0) {
        printf(", %d of them at undeclared code(s)", result.undeclared);
    }
    printf("\n");
    close(fd);
    return result;
}

int main(void) {
    DIR *dir = opendir("/dev/input");
    if (dir == NULL) {
        fprintf(stderr, "cannot open /dev/input: %s\n", strerror(errno));
        return 1;
    }

    char nodes[MAX_NODES][NAME_MAX_LEN];
    int count = 0;
    int overflow = 0;
    const struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (strncmp(entry->d_name, "event", 5) != 0) {
            continue;
        }
        if (count >= MAX_NODES) {
            overflow = 1;
            continue;
        }
        snprintf(nodes[count++], NAME_MAX_LEN, "%s", entry->d_name);
    }
    closedir(dir);
    qsort(nodes, (size_t)count, NAME_MAX_LEN, compare_names);

    int total = 0;
    int examined = 0;
    int undeclared = 0;
    for (int i = 0; i < count; ++i) {
        char path[16 + NAME_MAX_LEN];
        struct probe_result result;
        snprintf(path, sizeof(path), "/dev/input/%s", nodes[i]);
        result = probe(path);
        total += result.down;
        examined += result.examined;
        undeclared += result.undeclared;
    }
    printf("\n%d key(s) asserted across %d of %d device(s) read",
           total, examined, count);
    if (undeclared > 0) {
        printf("; %d at code(s) the driver does not advertise", undeclared);
    }
    printf("\n");

    /*
     * The caller runs this under `set -e`, and this used to return 0 whatever
     * happened. A run in which every open() failed with EACCES -- no `adb root`,
     * or a node the shell user cannot open -- therefore looked identical to a
     * run that read every node and found nothing latched, and the capture
     * carried on as though the kernel had answered. The exit status now says
     * whether the bitmap this tool exists to read was actually read.
     */
    if (count == 0) {
        fprintf(stderr, "no /dev/input/event* node found\n");
        return 1;
    }
    if (overflow) {
        fprintf(stderr, "more than %d /dev/input/event* nodes; only the first "
                        "%d were examined\n", MAX_NODES, MAX_NODES);
        return 1;
    }
    if (examined != count) {
        fprintf(stderr, "read the key state of only %d of %d input node(s)\n",
                examined, count);
        return 1;
    }
    return 0;
}

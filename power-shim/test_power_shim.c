#include "fake_powerhal.h"

#include <assert.h>
#include <dlfcn.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>

static void *lookup(void *handle, const char *name)
{
    void *symbol = dlsym(handle, name);
    assert(symbol != NULL);
    return symbol;
}

int main(int argc, char **argv)
{
    assert(argc == 4);
    // Q's DF_1_GLOBAL lookup is represented by RTLD_GLOBAL on the host.
    void *shim = dlopen(argv[1], RTLD_NOW | RTLD_GLOBAL);
    if (shim == NULL) {
        fprintf(stderr, "%s\n", dlerror());
        return 1;
    }
    int (*hook)(const char *, int) = lookup(shim, "_Z9set_valuePKci");
    if (strcmp(argv[3], "missing-library") == 0) {
        hook("/proc/ppm/policy_status", 1);
        return 2;
    }
    void *vendor = dlopen(argv[2], RTLD_NOW | RTLD_LOCAL);
    if (vendor == NULL) {
        fprintf(stderr, "%s\n", dlerror());
        return 1;
    }
    if (strcmp(argv[3], "missing-symbol") == 0) {
        hook("/proc/ppm/policy_status", 1);
        return 2;
    }

    struct fake_powerhal_state *(*reset)(void) = lookup(vendor, "fake_reset");
    int (*scalar)(const char *, int) = lookup(vendor, "fake_call_scalar");
    int (*pair)(const char *, int, int) = lookup(vendor, "fake_call_pair");
    int (*text)(const char *, const char *) = lookup(vendor, "fake_call_text");
    struct fake_powerhal_state *state;

    // The first write also resolves the real setters. Loader work must not
    // alter errno before a successful vendor call which leaves it untouched.
    state = reset();
    errno = EBUSY;
    assert(scalar("/proc/ppm/root_cluster", 1) == 1 && errno == EBUSY);
    assert(state->scalar_calls == 1 && state->pair_calls == 0);

    static const struct { int value; const char *command; } hica_cases[] = {
        {1, "10 1"}, {0, "10 0"}, {-1, "10 -1"},
        {INT_MAX, "10 2147483647"}, {INT_MIN, "10 -2147483648"},
    };
    for (size_t i = 0; i < sizeof(hica_cases) / sizeof(hica_cases[0]); ++i) {
        state = reset();
        int result = scalar("/proc/ppm/policy_status", hica_cases[i].value);
        assert(result == (int)strlen(hica_cases[i].command));
        assert(strcmp(state->command, hica_cases[i].command) == 0);
        assert(strcmp(state->path, "/proc/ppm/policy_status") == 0);
        assert(state->pair_calls == 1 && state->scalar_calls == 0);
    }

    state = reset();
    assert(scalar("/sys/devices/system/cpu/cpufreq/interactive/min_sample_time", 200000) == 6);
    assert(strcmp(state->command, "200000") == 0);
    assert(state->scalar_calls == 1 && state->pair_calls == 0);

    state = reset();
    assert(scalar("/proc/ppm/policy_status_extra", -1) == 2);
    assert(strcmp(state->command, "-1") == 0);
    assert(state->scalar_calls == 1 && state->pair_calls == 0);

    state = reset();
    errno = 0;
    assert(scalar(NULL, 1) == 0 && errno == EINVAL);
    assert(state->null_path && state->scalar_calls == 1 && state->pair_calls == 0);

    state = reset();
    assert(text("/proc/ppm/policy_status", "10 0") == 4);
    assert(strcmp(state->command, "10 0") == 0 && state->text_calls == 1);
    assert(state->scalar_calls == 0 && state->pair_calls == 0);

    state = reset();
    assert(pair("/proc/ppm/policy_status", 4, 0) == 3);
    assert(strcmp(state->command, "4 0") == 0 && state->pair_calls == 1);
    assert(state->scalar_calls == 0 && state->text_calls == 0);

    state = reset();
    state->fail_errno = EACCES;
    errno = 0;
    assert(scalar("/proc/ppm/policy_status", 1) == 0 && errno == EACCES);
    assert(strcmp(state->command, "10 1") == 0 && state->pair_calls == 1);

    state = reset();
    state->fail_errno = EROFS;
    errno = 0;
    assert(scalar("/proc/ppm/root_cluster", 1) == 0 && errno == EROFS);
    assert(strcmp(state->command, "1") == 0 && state->scalar_calls == 1);

    puts("Power HAL shim command, PLT forwarding, return count, and errno tests: PASS");
    return 0;
}

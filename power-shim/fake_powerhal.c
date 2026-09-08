#include "fake_powerhal.h"

#include <errno.h>
#include <stdio.h>
#include <string.h>

static struct fake_powerhal_state sState;

int vendor_scalar(const char *, int) __asm__("_Z9set_valuePKci");
int vendor_pair(const char *, int, int) __asm__("_Z9set_valuePKcii");
int vendor_text(const char *, const char *) __asm__("_Z9set_valuePKcS0_");

struct fake_powerhal_state *fake_reset(void)
{
    memset(&sState, 0, sizeof(sState));
    return &sState;
}

static int record_write(const char *path)
{
    sState.null_path = path == NULL;
    if (path == NULL) {
        errno = EINVAL;
        return 0;
    }
    snprintf(sState.path, sizeof(sState.path), "%s", path);
    if (sState.fail_errno != 0) {
        errno = sState.fail_errno;
        return 0;
    }
    return (int)strlen(sState.command);
}

#ifndef OMIT_SCALAR
int vendor_scalar(const char *path, int value)
{
    ++sState.scalar_calls;
    snprintf(sState.command, sizeof(sState.command), "%d", value);
    return record_write(path);
}
#endif

#ifndef OMIT_PAIR
int vendor_pair(const char *path, int first, int second)
{
    ++sState.pair_calls;
    snprintf(sState.command, sizeof(sState.command), "%d %d", first, second);
    return record_write(path);
}

int fake_call_pair(const char *path, int first, int second)
{
    return vendor_pair(path, first, second);
}
#endif

int vendor_text(const char *path, const char *value)
{
    ++sState.text_calls;
    snprintf(sState.command, sizeof(sState.command), "%s", value);
    return record_write(path);
}

// These calls must pass through the fixture's PLT, as the vendor calls do.
int fake_call_scalar(const char *path, int value)
{
    return vendor_scalar(path, value);
}

int fake_call_text(const char *path, const char *value)
{
    return vendor_text(path, value);
}

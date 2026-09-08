#ifndef K50SV1_FAKE_POWERHAL_H
#define K50SV1_FAKE_POWERHAL_H

struct fake_powerhal_state {
    int scalar_calls;
    int pair_calls;
    int text_calls;
    int fail_errno;
    int null_path;
    char path[128];
    char command[64];
};

struct fake_powerhal_state *fake_reset(void);
int fake_call_scalar(const char *path, int value);
int fake_call_pair(const char *path, int first, int second);
int fake_call_text(const char *path, const char *value);

#endif

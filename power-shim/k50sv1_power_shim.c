/*
 * libpowerhal's loadConTable() writes DefaultValue without the command Prefix.
 * For the HICA entry that produces "1" where policy_status requires "10 1".
 * Keep the blob's defaults, arbitration, and already-prefixed writes intact.
 * See README.md for the measured ABI and linker requirements.
 */
#define LOG_TAG "k50sv1-power-shim"

#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#ifdef K50SV1_POWER_SHIM_HOST_TEST
#include <stdio.h>
#define SHIM_LOG(...) do { fprintf(stderr, LOG_TAG ": " __VA_ARGS__); fputc('\n', stderr); } while (0)
#define SHIM_FATAL(...) do { SHIM_LOG(__VA_ARGS__); abort(); } while (0)
#else
#include <log/log.h>
#define SHIM_LOG(...) ALOGI(__VA_ARGS__)
#define SHIM_FATAL(...) LOG_ALWAYS_FATAL(__VA_ARGS__)
#endif

typedef int (*scalar_setter)(const char *, int);
typedef int (*pair_setter)(const char *, int, int);

static pthread_once_t sResolveOnce = PTHREAD_ONCE_INIT;
static scalar_setter sRealScalar;
static pair_setter sRealPair;

__attribute__((visibility("default")))
int k50sv1_power_set_value(const char *path, int value) __asm__("_Z9set_valuePKci");

static void *required_symbol(void *handle, const char *name)
{
    dlerror();
    void *symbol = dlsym(handle, name);
    const char *error = dlerror();
    if (symbol == NULL || error != NULL) {
        SHIM_FATAL("cannot resolve libpowerhal.so %s: %s", name,
                   error != NULL ? error : "null symbol");
    }
    return symbol;
}

static void resolve_setters(void)
{
    // The caller is already in libpowerhal. Keep this handle for the process
    // lifetime; RTLD_NOLOAD avoids loading another backend during a write.
    void *handle = dlopen("libpowerhal.so", RTLD_NOW | RTLD_NOLOAD);
    if (handle == NULL) {
        SHIM_FATAL("cannot find loaded libpowerhal.so: %s", dlerror());
    }
    // RTLD_NEXT can miss a HAL loaded with RTLD_LOCAL. A handle lookup starts
    // at the real library and does not resolve the scalar setter back to us.
    sRealScalar = (scalar_setter)required_symbol(handle, "_Z9set_valuePKci");
    sRealPair = (pair_setter)required_symbol(handle, "_Z9set_valuePKcii");
    if (sRealScalar == k50sv1_power_set_value) {
        SHIM_FATAL("libpowerhal.so scalar setter resolves to the shim itself");
    }
}

int k50sv1_power_set_value(const char *path, int value)
{
    int incoming_errno = errno;
    pthread_once(&sResolveOnce, resolve_setters);
    errno = incoming_errno;
    if (path != NULL && strcmp(path, "/proc/ppm/policy_status") == 0) {
        // HICA is policy 10 in this kernel and the only command table entry
        // using policy_status. Pass the value unchanged to the real formatter.
        int result = sRealPair(path, 10, value);
        int saved_errno = errno;
        SHIM_LOG("policy_status scalar write \"10 %d\" returned %d", value, result);
        errno = saved_errno;
        return result;
    }
    return sRealScalar(path, value);
}

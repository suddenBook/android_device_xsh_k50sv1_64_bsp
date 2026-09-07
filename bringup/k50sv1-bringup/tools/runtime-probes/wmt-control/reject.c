/* E-191 native rejection probe: every request fails validation before mutation.
 * The host runner first binds the installed wmt_drv.ko to the fixed source build.
 */
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

/* wmt_dev.c uses pointer-sized command encodings and a 264-byte fixed payload
 * for both common and ROM patch metadata. identifier means sequence or type.
 */
#define SET_PATCH_NUM _IOW(0xa0, 14, int)
#define SET_PATCH_INFO _IOW(0xa0, 15, char *)
#define DYNAMIC_DUMP _IOR(0xa0, 30, char *)
#define SET_ROM_PATCH_INFO _IOW(0xa0, 31, char *)
#define DYNAMIC_DUMP_BYTES 109

struct patch_info {
    uint32_t identifier;
    uint8_t address[4];
    char name[256];
};
_Static_assert(sizeof(struct patch_info) == 264, "patch ioctl payload size");
_Static_assert(offsetof(struct patch_info, name) == 8, "patch name offset");

static unsigned cases, failures;

static void reject(int fd, const char *name, unsigned request,
                   unsigned long argument, int expected_errno)
{
    errno = 0;
    int result = ioctl(fd, request, argument);
    int error = errno;
    int passed = result == -1 && error == expected_errno;
    cases++;
    failures += !passed;
    printf("%s case=%s command=%08x result=%d errno=%d expected_errno=%d\n",
           passed ? "PASS" : "FAIL", name, request, result, error, expected_errno);
}

int main(void)
{
    int fd = open("/dev/stpwmt", O_RDWR | O_CLOEXEC);
    if (fd < 0) {
        perror("open /dev/stpwmt");
        return 2;
    }
    printf("ABI pointer_bytes=%zu payload_bytes=%zu\n", sizeof(void *),
           sizeof(struct patch_info));
    reject(fd, "patch-count-zero", SET_PATCH_NUM, 0, EINVAL);
    reject(fd, "patch-count-eleven", SET_PATCH_NUM, 11, EINVAL);
    reject(fd, "patch-count-max", SET_PATCH_NUM, ULONG_MAX, EINVAL);
    reject(fd, "patch-null", SET_PATCH_INFO, 0, EFAULT);

    struct patch_info info = {0};
    strcpy(info.name, "invalid-sequence");
    reject(fd, "patch-sequence-zero", SET_PATCH_INFO, (unsigned long)&info, EINVAL);
    info.identifier = UINT32_MAX;
    reject(fd, "patch-sequence-max", SET_PATCH_INFO, (unsigned long)&info, EINVAL);
    info.identifier = 1;
    memset(info.name, 'x', sizeof(info.name));
    reject(fd, "patch-unterminated-name", SET_PATCH_INFO, (unsigned long)&info, EINVAL);

    reject(fd, "rom-null", SET_ROM_PATCH_INFO, 0, EFAULT);
    memset(&info, 0, sizeof(info));
    info.identifier = 5;
    reject(fd, "rom-type-limit", SET_ROM_PATCH_INFO, (unsigned long)&info, EINVAL);
    info.identifier = UINT32_MAX;
    reject(fd, "rom-type-max", SET_ROM_PATCH_INFO, (unsigned long)&info, EINVAL);
    info.identifier = 0;
    memset(info.name, 'x', sizeof(info.name));
    reject(fd, "rom-unterminated-name", SET_ROM_PATCH_INFO, (unsigned long)&info, EINVAL);

    reject(fd, "dump-null", DYNAMIC_DUMP, 0, EFAULT);
    const struct {
        const char *name;
        const char *value;
        int error;
    } malformed[] = {
        {"dump-empty-field", "1//2", EINVAL},
        {"dump-leading-separator", "/1", EINVAL},
        {"dump-u32-overflow", "1/4294967296", ERANGE},
        {"dump-negative", "-1", EINVAL},
        {"dump-eleven-values", "0/0/0/0/0/0/0/0/0/0/1", EINVAL},
    };
    char dump[DYNAMIC_DUMP_BYTES];
    for (unsigned i = 0; i < sizeof(malformed) / sizeof(malformed[0]); i++) {
        memset(dump, 0, sizeof(dump));
        strcpy(dump, malformed[i].value);
        reject(fd, malformed[i].name, DYNAMIC_DUMP, (unsigned long)dump, malformed[i].error);
    }
    memset(dump, '9', sizeof(dump));
    reject(fd, "dump-full-buffer-overflow", DYNAMIC_DUMP, (unsigned long)dump, ERANGE);
    if (close(fd)) {
        perror("close /dev/stpwmt");
        return 2;
    }
    printf("RESULT cases=%u passed=%u failed=%u\n", cases, cases - failures, failures);
    return failures ? 1 : 0;
}

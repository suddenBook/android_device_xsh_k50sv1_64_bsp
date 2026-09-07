// SPDX-License-Identifier: Apache-2.0
#include "firmware.h"

#include <assert.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* Linker wrappers affect this host executable only. Faults are armed solely
 * around calls into the unchanged production discovery functions.
 */
enum fault {
    NONE, OPEN_ERROR, STAT_ERROR, READ_ERROR, READ_PARTIAL_ERROR,
    READ_INTERRUPTED, READ_CHUNKS, DIRECTORY_ERROR, CLOSE_ERROR,
    CLOSEDIR_ERROR, ALLOC_ERROR, SEEK_ERROR, END_READ_ERROR, FILE_GREW
};

static enum fault injected;
static unsigned read_calls, directory_calls;
static int candidate_fd = -1;
static char case_directory[PATH_MAX];
static const char *temporary_root;
static uint8_t real_a[WMT_PATCH_HEADER_SIZE], real_b[WMT_PATCH_HEADER_SIZE];
static unsigned passed;

int __real_openat(int directory, const char *path, int flags, ...);
int __real_fstat(int fd, struct stat *status);
ssize_t __real_read(int fd, void *buffer, size_t size);
struct dirent *__real_readdir(DIR *stream);
int __real_close(int fd);
int __real_closedir(DIR *stream);
void *__real_malloc(size_t size);
off_t __real_lseek(int fd, off_t offset, int origin);

int __wrap_openat(int directory, const char *path, int flags, ...)
{
    if (injected == OPEN_ERROR) {
        errno = EACCES;
        return -1;
    }
    candidate_fd = __real_openat(directory, path, flags);
    return candidate_fd;
}

int __wrap_fstat(int fd, struct stat *status)
{
    if (fd == candidate_fd && injected == STAT_ERROR) {
        errno = EIO;
        return -1;
    }
    return __real_fstat(fd, status);
}

ssize_t __wrap_read(int fd, void *buffer, size_t size)
{
    if (fd == candidate_fd) {
        read_calls++;
        if (injected == READ_ERROR ||
            (injected == READ_PARTIAL_ERROR && read_calls == 2) ||
            (injected == END_READ_ERROR && read_calls == 3)) {
            errno = EIO;
            return -1;
        }
        if (injected == READ_INTERRUPTED && read_calls == 1) {
            errno = EINTR;
            return -1;
        }
        if (injected == FILE_GREW && read_calls == 3) {
            assert(size == 1);
            *(uint8_t *)buffer = 0xff;
            return 1;
        }
        if ((injected == READ_CHUNKS || injected == READ_PARTIAL_ERROR) && size > 3)
            size = 3;
    }
    return __real_read(fd, buffer, size);
}

struct dirent *__wrap_readdir(DIR *stream)
{
    directory_calls++;
    if (injected == DIRECTORY_ERROR && directory_calls == 4) {
        errno = EIO;
        return NULL;
    }
    return __real_readdir(stream);
}

int __wrap_close(int fd)
{
    int result = __real_close(fd);

    if (fd == candidate_fd && injected == CLOSE_ERROR) {
        assert(result == 0);
        errno = EIO;
        result = -1;
    }
    if (fd == candidate_fd)
        candidate_fd = -1;
    return result;
}

int __wrap_closedir(DIR *stream)
{
    int result = __real_closedir(stream);

    if (injected == CLOSEDIR_ERROR) {
        assert(result == 0);
        errno = EIO;
        return -1;
    }
    return result;
}

void *__wrap_malloc(size_t size)
{
    return injected == ALLOC_ERROR ? NULL : __real_malloc(size);
}

off_t __wrap_lseek(int fd, off_t offset, int origin)
{
    if (fd == candidate_fd && injected == SEEK_ERROR) {
        errno = EIO;
        return -1;
    }
    return __real_lseek(fd, offset, origin);
}

static void arm(enum fault fault)
{
    injected = fault;
    read_calls = 0;
    directory_calls = 0;
    candidate_fd = -1;
}

static void path_for(const char *name, char path[PATH_MAX])
{
    int length = snprintf(path, PATH_MAX, "%s/%s", case_directory, name);

    assert(length > 0 && length < PATH_MAX);
}

static void begin_case(void)
{
    int length = snprintf(case_directory, sizeof(case_directory), "%s/case-XXXXXX", temporary_root);

    assert(length > 0 && (size_t)length < sizeof(case_directory));
    assert(mkdtemp(case_directory));
    arm(NONE);
}

static void end_case(const char *name)
{
    DIR *stream;
    struct dirent *entry;

    arm(NONE);
    stream = opendir(case_directory);
    assert(stream);
    while ((entry = readdir(stream))) {
        char path[PATH_MAX];
        struct stat status;

        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, ".."))
            continue;
        path_for(entry->d_name, path);
        assert(lstat(path, &status) == 0);
        if (S_ISDIR(status.st_mode))
            assert(rmdir(path) == 0);
        else
            assert(unlink(path) == 0);
    }
    assert(closedir(stream) == 0);
    assert(rmdir(case_directory) == 0);
    passed++;
    printf("{\"case\":\"%s\",\"passed\":true}\n", name);
}

static void put(const char *name, const void *data, size_t size)
{
    char path[PATH_MAX];
    const uint8_t *position = data;
    int fd;

    path_for(name, path);
    fd = open(path, O_CREAT | O_TRUNC | O_WRONLY | O_CLOEXEC, 0600);
    assert(fd >= 0);
    while (size) {
        ssize_t bytes = write(fd, position, size);

        assert(bytes > 0);
        position += bytes;
        size -= (size_t)bytes;
    }
    assert(close(fd) == 0);
}

static void real_headers(void)
{
    /* These exact 28-byte headers are loaded from the two hash-bound retained
     * firmware files. Their filename suffix order is opposite to sequence order.
     */
    put("ROMv2_lm_patch_1_0_hdr.bin", real_a, sizeof(real_a));
    put("ROMv2_lm_patch_1_1_hdr.bin", real_b, sizeof(real_b));
}

static struct wmt_firmware_result normal_result(uint16_t firmware, int expected)
{
    struct wmt_firmware_result result, before;
    int error;

    memset(&result, 0xa5, sizeof(result));
    memcpy(&before, &result, sizeof(before));
    error = wmt_firmware_search(case_directory, firmware, &result);
    if (error != expected)
        fprintf(stderr, "normal expected %d, got %d\n", expected, error);
    assert(error == expected);
    if (error)
        assert(!memcmp(&before, &result, sizeof(result)));
    return result;
}

static struct wmt_rom_set rom_result(uint16_t firmware, int expected)
{
    struct wmt_rom_set result = {0}, before;
    int error;

    result.count = 12345;
    result.seen = 0xa5;
    result.has_wifi_version = true;
    result.has_bt_version = true;
    memset(result.records, 0xa5, sizeof(result.records));
    memcpy(&before, &result, sizeof(before));
    error = wmt_rom_search(case_directory, firmware, &result);
    if (error != expected)
        fprintf(stderr, "ROM expected %d, got %d\n", expected, error);
    assert(error == expected);
    if (error)
        assert(!memcmp(&before, &result, sizeof(result)));
    return result;
}

static void synthetic_rom_header(uint8_t header[WMT_ROM_HEADER_SIZE], uint8_t type)
{
    memset(header, 0, WMT_ROM_HEADER_SIZE);
    memcpy(header, "20200907010203x!", 16);
    header[22] = 0x7b;
    header[24] = 0; /* ROM does not use the normal count/sequence nibbles. */
    header[25] = 0x12;
    header[26] = 0x34;
    header[27] = 0xa5;
    header[31] = type;
}

static void put_rom(const char *name, uint8_t type, const char *text)
{
    uint8_t data[1024];
    size_t size = text ? strlen(text) : 0;

    assert(size <= sizeof(data) - WMT_ROM_HEADER_SIZE);
    synthetic_rom_header(data, type);
    if (size)
        memcpy(data + WMT_ROM_HEADER_SIZE, text, size);
    put(name, data, WMT_ROM_HEADER_SIZE + size);
}

static void test_normal(void)
{
    uint8_t header[WMT_PATCH_HEADER_SIZE];
    struct wmt_firmware_result result;
    const struct {
        enum fault fault;
        int error;
        const char *name;
    } faults[] = {
        {OPEN_ERROR, -EACCES, "normal-open-error"},
        {STAT_ERROR, -EIO, "normal-fstat-error"},
        {READ_ERROR, -EIO, "normal-read-error"},
        {READ_PARTIAL_ERROR, -EIO, "normal-partial-then-error"},
        {DIRECTORY_ERROR, -EIO, "normal-readdir-error"},
        {CLOSE_ERROR, -EIO, "normal-close-error"},
        {CLOSEDIR_ERROR, -EIO, "normal-closedir-error"},
        {READ_INTERRUPTED, 0, "normal-eintr-retry"},
        {READ_CHUNKS, 0, "normal-partial-read-reassembly"},
    };

    begin_case();
    real_headers();
    result = normal_result(0xff00, 0);
    assert(result.patches.count == 2 && result.patches.seen == 3);
    assert(result.patches.records[0].sequence == 1);
    assert(result.patches.records[1].sequence == 2);
    assert(!strcmp(result.patches.records[0].name, "ROMv2_lm_patch_1_1_hdr.bin"));
    assert(!strcmp(result.patches.records[1].name, "ROMv2_lm_patch_1_0_hdr.bin"));
    assert(!memcmp(result.patches.records[0].address, "\0\0\12\360", 4));
    assert(!memcmp(result.patches.records[1].address, "\0\0\6\0", 4));
    assert(!strcmp(result.versions[0], "20200629194517a"));
    assert(!strcmp(result.versions[1], "20200629194517a"));
    end_case("normal-real-headers-low-byte-and-order");

    begin_case();
    put("ignored.bin", "x", 1);
    normal_result(0, -ENOENT);
    end_case("normal-no-candidates");

    begin_case();
    put("ROMv2_lm_patch_only", real_a, sizeof(real_a));
    normal_result(0, -ENODATA);
    end_case("normal-incomplete");

    begin_case();
    real_headers();
    put("ROMv2_lm_patch_duplicate", real_a, sizeof(real_a));
    normal_result(0, -EEXIST);
    end_case("normal-duplicate");

    begin_case();
    real_headers();
    memcpy(header, real_a, sizeof(header));
    header[24] = 0x33;
    put("ROMv2_lm_patch_inconsistent", header, sizeof(header));
    normal_result(0, -EINVAL);
    end_case("normal-inconsistent-count");

    begin_case();
    real_headers();
    header[23] = 1;
    header[24] = 0xff;
    put("ROMv2_lm_patch_other-firmware", header, sizeof(header));
    result = normal_result(0, 0);
    assert(result.patches.count == 2);
    normal_result(2, -ENOENT);
    end_case("normal-mismatch-skips-metadata");

    begin_case();
    for (unsigned sequence = WMT_MAX_PATCHES; sequence; sequence--) {
        char name[64];

        memcpy(header, real_a, sizeof(header));
        header[0] = (uint8_t)('A' + sequence);
        header[24] = (WMT_MAX_PATCHES << 4) | sequence;
        snprintf(name, sizeof(name), "ROMv2_lm_patch_%u", sequence);
        put(name, header, sizeof(header));
    }
    result = normal_result(0, 0);
    assert(result.patches.count == 10 && result.patches.seen == 0x3ff);
    for (unsigned index = 0; index < WMT_MAX_PATCHES; index++) {
        assert(result.patches.records[index].sequence == index + 1);
        assert(result.versions[index][0] == 'B' + (int)index);
    }
    end_case("normal-ten-reverse-created-versions-by-sequence");

    begin_case();
    for (size_t size = 0; size < sizeof(real_a); size++) {
        put("ROMv2_lm_patch_short", real_a, size);
        normal_result(0, -EMSGSIZE);
    }
    end_case("normal-all-short-header-lengths");

    begin_case();
    memcpy(header, real_a, sizeof(header));
    for (unsigned metadata = 0; metadata <= 255; metadata++) {
        unsigned count = metadata >> 4, sequence = metadata & 15;

        if (count && count <= WMT_MAX_PATCHES && sequence && sequence <= count)
            continue;
        header[24] = (uint8_t)metadata;
        put("ROMv2_lm_patch_invalid", header, sizeof(header));
        normal_result(0, -EINVAL);
    }
    end_case("normal-invalid-count-sequence-nibbles");

    begin_case();
    char maximum_name[WMT_PATCH_NAME_SIZE];
    memset(maximum_name, 'x', sizeof(maximum_name) - 1);
    memcpy(maximum_name, "ROMv2_lm_patch", strlen("ROMv2_lm_patch"));
    maximum_name[sizeof(maximum_name) - 1] = '\0';
    memcpy(header, real_a, sizeof(header));
    header[24] = 0x11;
    put(maximum_name, header, sizeof(header));
    result = normal_result(0, 0);
    assert(!strcmp(result.patches.records[0].name, maximum_name));
    end_case("normal-255-byte-basename");

    for (size_t i = 0; i < sizeof(faults) / sizeof(faults[0]); i++) {
        begin_case();
        real_headers();
        arm(faults[i].fault);
        normal_result(0, faults[i].error);
        end_case(faults[i].name);
    }
}

static void test_filesystem(void)
{
    char path[PATH_MAX], target[PATH_MAX];
    uint8_t header[WMT_ROM_HEADER_SIZE];
    struct wmt_firmware_result normal;
    struct wmt_rom_set rom;

    begin_case();
    assert(wmt_firmware_search(NULL, 0, &normal) == -EINVAL);
    assert(wmt_firmware_search("", 0, &normal) == -EINVAL);
    assert(wmt_firmware_search(case_directory, 0, NULL) == -EINVAL);
    assert(wmt_rom_search(NULL, 0, &rom) == -EINVAL);
    assert(wmt_rom_search("", 0, &rom) == -EINVAL);
    assert(wmt_rom_search(case_directory, 0, NULL) == -EINVAL);
    path_for("missing", path);
    assert(wmt_firmware_search(path, 0, &normal) == -ENOENT);
    assert(wmt_rom_search(path, 0, &rom) == -ENOENT);
    put("plain", "x", 1);
    path_for("plain", path);
    assert(wmt_firmware_search(path, 0, &normal) == -ENOTDIR);
    assert(wmt_rom_search(path, 0, &rom) == -ENOTDIR);
    end_case("filesystem-invalid-arguments-and-directory");

    const char *names[] = {"ROMv2_lm_patch_bad", "soc1_0_ram_bad"};
    for (unsigned kind = 0; kind < 3; kind++) {
        begin_case();
        for (unsigned i = 0; i < 2; i++) {
            path_for(names[i], path);
            if (kind == 0)
                assert(mkdir(path, 0700) == 0);
            else if (kind == 1)
                assert(mkfifo(path, 0600) == 0);
            else
                assert(symlink("absent-target", path) == 0);
        }
        normal_result(0, kind == 2 ? -ENOENT : -EINVAL);
        rom_result(0, kind == 2 ? -ENOENT : -EINVAL);
        end_case(kind == 0 ? "filesystem-directory-candidates" :
                  kind == 1 ? "filesystem-fifo-candidates-no-block" :
                              "filesystem-broken-symlink-candidates");
    }

    begin_case();
    memcpy(header, real_a, sizeof(real_a));
    header[24] = 0x11;
    put("normal-target", header, sizeof(real_a));
    path_for("normal-target", target);
    path_for("ROMv2_lm_patch_link", path);
    assert(symlink(target, path) == 0);
    normal = normal_result(0, 0);
    assert(!strcmp(normal.patches.records[0].name, "ROMv2_lm_patch_link"));
    synthetic_rom_header(header, 4);
    put("rom-target", header, sizeof(header));
    path_for("rom-target", target);
    path_for("soc1_0_ram_link", path);
    assert(symlink(target, path) == 0);
    rom = rom_result(0, 0);
    assert(rom.count == 1 && rom.seen == (1U << 4));
    end_case("filesystem-regular-symlinks-keep-entry-basename");
}

static void test_rom(void)
{
    uint8_t header[WMT_ROM_HEADER_SIZE];
    struct wmt_rom_set result;
    const char *bt = "BABEFACEBABEFACE\nt-neptune 2020-release\nignoredDEADBEEFDEADBEEF";

    begin_case();
    put("ignored", "x", 1);
    result = rom_result(0, 0);
    assert(!result.count && !result.seen && !result.has_wifi_version && !result.has_bt_version);
    end_case("synthetic-rom-empty-success");

    begin_case();
    for (int type = WMT_ROM_TYPES - 1; type >= 0; type--) {
        char name[64];

        snprintf(name, sizeof(name), "soc1_0_ram_type_%d", type);
        put_rom(name, (uint8_t)type, NULL);
    }
    result = rom_result(0xff00, 0);
    assert(result.count == 5 && result.seen == 31);
    for (unsigned type = 0; type < WMT_ROM_TYPES; type++) {
        assert(result.records[type].type == type);
        assert(!memcmp(result.records[type].address, "\0\22\64\245", 4));
    }
    end_case("synthetic-rom-all-five-types-low-byte-address");

    begin_case();
    put_rom("soc1_0_ram_wmt", 4, NULL);
    result = rom_result(0, 0);
    assert(result.count == 1 && result.seen == 16 && result.records[4].type == 4);
    end_case("synthetic-rom-wmt-type-four-alone");

    begin_case();
    put_rom("soc1_0_ram_first", 3, NULL);
    put_rom("soc1_0_ram_duplicate", 3, NULL);
    rom_result(0, -EEXIST);
    end_case("synthetic-rom-duplicate-type");

    begin_case();
    synthetic_rom_header(header, 4);
    for (unsigned type = WMT_ROM_TYPES; type <= 255; type++) {
        header[31] = (uint8_t)type;
        put("soc1_0_ram_invalid", header, sizeof(header));
        rom_result(0, -EINVAL);
    }
    end_case("synthetic-rom-all-invalid-types-including-original-five");

    begin_case();
    synthetic_rom_header(header, 1);
    for (unsigned value = 0; value < 16; value++) {
        header[27] = (uint8_t)value;
        put("soc1_0_ram_invalid", header, sizeof(header));
        rom_result(0, -EINVAL);
    }
    end_case("synthetic-rom-missing-header27-high-nibble");

    begin_case();
    synthetic_rom_header(header, 4);
    for (size_t size = 0; size < sizeof(header); size++) {
        put("soc1_0_ram_short", header, size);
        rom_result(0, -EMSGSIZE);
    }
    end_case("synthetic-rom-all-short-header-lengths");

    begin_case();
    header[23] = 1;
    header[27] = 0;
    header[31] = 255;
    put("soc1_0_ram_other-firmware", header, sizeof(header));
    result = rom_result(0, 0);
    assert(!result.count);
    end_case("synthetic-rom-mismatch-skips-invalid-metadata");

    begin_case();
    put_rom("soc1_0_ram_wifi", 1, NULL);
    put_rom("soc1_0_ram_bt", 0, bt);
    result = rom_result(0, 0);
    assert(result.has_wifi_version && result.has_bt_version);
    assert(!strcmp(result.wifi_version, "20200907010203x"));
    assert(!strcmp(result.bt_version, "t-neptune 2020-release"));
    end_case("synthetic-rom-wifi-header-and-bt-marker-newline");

    begin_case();
    put_rom("soc1_0_ram_wifi_a", 1, NULL);
    put_rom("soc1_0_ram_wifi_b", 2, NULL);
    result = rom_result(0, 0);
    assert(result.count == 2 && result.has_wifi_version);
    synthetic_rom_header(header, 2);
    header[0] = '9';
    put("soc1_0_ram_wifi_b", header, sizeof(header));
    rom_result(0, -EINVAL);
    end_case("synthetic-rom-wifi-multiple-role-version-consistency");

    const struct {
        const char *text;
        int error;
        const char *version;
        const char *name;
    } versions[] = {
        {"ordinary binary payload", 0, NULL, "synthetic-bt-absent-optional-markers"},
        {"BABEFACEBABEFACEunknownDEADBEEFDEADBEEF", 0, NULL, "synthetic-bt-unrecognized-text"},
        {"BABEFACEBABEFACEt-neptune", -EBADMSG, NULL, "synthetic-bt-start-without-end"},
        {"DEADBEEFDEADBEEF", -EBADMSG, NULL, "synthetic-bt-end-without-start"},
        {"DEADBEEFDEADBEEFt-neptuneBABEFACEBABEFACE", -EBADMSG, NULL, "synthetic-bt-reversed-markers"},
        {"BABEFACEBABEFACEt-neptuneDEADBEEFDEADBEE", -EBADMSG, NULL, "synthetic-bt-truncated-end-marker"},
        {"BABEFACEBABEFACE= debug payloadDEADBEEFDEADBEEF", 0, "20200907010203", "synthetic-bt-debug-fallback-first-fourteen-bytes"},
        {"BABEFACEBABEFACE= debug t-neptune releaseDEADBEEFDEADBEEF", 0, "t-neptune release", "synthetic-bt-neptune-precedes-debug-fallback"},
        {"BABEFACEBABEFACEDEADBEEFDEADBEEFt-neptune outside", 0, NULL, "synthetic-bt-text-outside-markers-excluded"},
    };
    for (size_t i = 0; i < sizeof(versions) / sizeof(versions[0]); i++) {
        begin_case();
        put_rom("soc1_0_ram_bt", 0, versions[i].text);
        result = rom_result(0, versions[i].error);
        if (!versions[i].error) {
            assert(result.count == 1);
            assert(result.has_bt_version == (versions[i].version != NULL));
            if (versions[i].version)
                assert(!strcmp(result.bt_version, versions[i].version));
        }
        end_case(versions[i].name);
    }

    begin_case();
    uint8_t binary[128] = {0};
    synthetic_rom_header(binary, 0);
    memcpy(binary + 40, "BABEFACEBABEFACE", 16);
    memcpy(binary + 57, "t-neptune hidden", 16);
    memcpy(binary + 80, "DEADBEEFDEADBEEF", 16);
    put("soc1_0_ram_bt", binary, 96);
    result = rom_result(0, 0);
    assert(!result.has_bt_version);
    binary[56] = ' ';
    put("soc1_0_ram_bt", binary, 96);
    result = rom_result(0, 0);
    assert(result.has_bt_version && !strcmp(result.bt_version, "t-neptune hidden"));
    end_case("synthetic-bt-binary-markers-and-bounded-nul-text");

    begin_case();
    char long_text[256];
    memcpy(long_text, "BABEFACEBABEFACEt-neptune", 25);
    memset(long_text + 25, 'x', 150);
    memcpy(long_text + 175, "DEADBEEFDEADBEEF", 17);
    put_rom("soc1_0_ram_bt", 0, long_text);
    result = rom_result(0, 0);
    assert(result.has_bt_version && strlen(result.bt_version) == 91);
    assert(!memcmp(result.bt_version, long_text + 16, 91));
    end_case("synthetic-bt-version-truncates-to-ninety-one");

    begin_case();
    put_rom("soc1_0_ram_bt_a", 0, bt);
    put_rom("soc1_0_ram_bt_b", 1, bt);
    result = rom_result(0, 0);
    assert(result.count == 2 && result.has_bt_version);
    put_rom("soc1_0_ram_bt_b", 1, "BABEFACEBABEFACEt-neptune otherDEADBEEFDEADBEEF");
    rom_result(0, -EINVAL);
    end_case("synthetic-bt-multiple-role-version-consistency");

    begin_case();
    size_t limit = WMT_BT_VERSION_FILE_LIMIT;
    uint8_t *large = malloc(limit + 1);
    assert(large);
    memset(large, 'x', limit + 1);
    synthetic_rom_header(large, 0);
    memcpy(large + limit - strlen(bt), bt, strlen(bt));
    put("soc1_0_ram_bt", large, limit);
    result = rom_result(0, 0);
    assert(result.has_bt_version && !strcmp(result.bt_version, "t-neptune 2020-release"));
    put("soc1_0_ram_bt", large, limit + 1);
    rom_result(0, -EFBIG);
    free(large);
    end_case("synthetic-bt-one-mib-boundary-and-oversize");

    const struct {
        enum fault fault;
        int error;
        const char *name;
    } faults[] = {
        {OPEN_ERROR, -EACCES, "synthetic-rom-open-error"},
        {STAT_ERROR, -EIO, "synthetic-rom-fstat-error"},
        {READ_ERROR, -EIO, "synthetic-rom-read-error"},
        {READ_PARTIAL_ERROR, -EIO, "synthetic-rom-partial-then-error"},
        {DIRECTORY_ERROR, -EIO, "synthetic-rom-readdir-error"},
        {CLOSE_ERROR, -EIO, "synthetic-rom-close-error"},
        {CLOSEDIR_ERROR, -EIO, "synthetic-rom-closedir-error"},
        {ALLOC_ERROR, -ENOMEM, "synthetic-bt-allocation-error"},
        {SEEK_ERROR, -EIO, "synthetic-bt-seek-error"},
        {END_READ_ERROR, -EIO, "synthetic-bt-final-read-error"},
        {FILE_GREW, -ESTALE, "synthetic-bt-file-grew-after-stat"},
        {READ_INTERRUPTED, 0, "synthetic-rom-eintr-retry"},
        {READ_CHUNKS, 0, "synthetic-rom-partial-read-reassembly"},
    };
    for (size_t i = 0; i < sizeof(faults) / sizeof(faults[0]); i++) {
        begin_case();
        put_rom("soc1_0_ram_bt", 0, bt);
        arm(faults[i].fault);
        result = rom_result(0, faults[i].error);
        if (!faults[i].error)
            assert(result.has_bt_version && !strcmp(result.bt_version, "t-neptune 2020-release"));
        end_case(faults[i].name);
    }
}

static void load_header(const char *path, uint8_t *header)
{
    FILE *stream = fopen(path, "rb");

    assert(stream);
    assert(fread(header, 1, WMT_PATCH_HEADER_SIZE, stream) == WMT_PATCH_HEADER_SIZE);
    assert(fclose(stream) == 0);
}

int main(int argc, char **argv)
{
    assert(argc == 4);
    load_header(argv[1], real_a);
    load_header(argv[2], real_b);
    temporary_root = argv[3];
    test_normal();
    test_filesystem();
    test_rom();
    printf("{\"passed\":%u,\"failed\":0,\"rom_fixtures\":\"synthetic\"}\n", passed);
    return 0;
}

// SPDX-License-Identifier: Apache-2.0
#include "firmware.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

_Static_assert(sizeof(struct wmt_rom_info) == 264, "WMT ROM metadata ABI");
_Static_assert(offsetof(struct wmt_rom_info, address) == 4, "WMT ROM address ABI");
_Static_assert(offsetof(struct wmt_rom_info, name) == 8, "WMT ROM name ABI");

static int read_exact(int fd, void *buffer, size_t size)
{
    unsigned char *position = buffer;

    while (size) {
        ssize_t bytes = read(fd, position, size);

        if (bytes < 0) {
            if (errno == EINTR)
                continue;
            return -errno;
        }
        if (!bytes)
            return -EMSGSIZE;
        position += bytes;
        size -= (size_t)bytes;
    }
    return 0;
}

typedef int (*read_candidate)(int fd, const struct stat *status, const char *name,
                              uint16_t firmware, void *result);

static int search_directory(const char *directory, const char *prefix,
                            uint16_t firmware, read_candidate consume, void *result)
{
    DIR *stream = opendir(directory);
    size_t prefix_size = strlen(prefix);
    int error = 0;

    if (!stream)
        return -errno;
    for (;;) {
        struct dirent *entry;
        struct stat status;
        int fd;

        errno = 0;
        entry = readdir(stream);
        if (!entry) {
            error = -errno;
            break;
        }
        if (strncmp(entry->d_name, prefix, prefix_size))
            continue;
        /* NONBLOCK prevents a malformed FIFO candidate from blocking startup.
         * A symlink is usable only when its opened target is a regular file.
         */
        fd = openat(dirfd(stream), entry->d_name, O_RDONLY | O_CLOEXEC | O_NONBLOCK);
        if (fd < 0) {
            error = -errno;
            break;
        }
        if (fstat(fd, &status) < 0)
            error = -errno;
        else if (!S_ISREG(status.st_mode))
            error = -EINVAL;
        else
            error = consume(fd, &status, entry->d_name, firmware, result);
        if (close(fd) < 0 && !error)
            error = -errno;
        if (error)
            break;
    }
    if (closedir(stream) < 0 && !error)
        error = -errno;
    return error;
}

static int read_patch(int fd, const struct stat *status, const char *name,
                      uint16_t firmware, void *result)
{
    struct wmt_firmware_result *found = result;
    struct wmt_patch_file file;
    uint8_t header[WMT_PATCH_HEADER_SIZE];
    int error;

    (void)status;
    error = read_exact(fd, header, sizeof(header));
    if (error)
        return error;
    error = wmt_patch_parse(header, sizeof(header), name, firmware, &file);
    if (error)
        return error == 1 ? 0 : error;
    error = wmt_patch_set_add(&found->patches, &file);
    if (error)
        return error;
    return wmt_patch_build_version(header, sizeof(header),
                                    found->versions[file.info.sequence - 1]);
}

int wmt_firmware_search(const char *directory, uint16_t firmware,
                        struct wmt_firmware_result *output)
{
    struct wmt_firmware_result found = {0};
    int error;

    if (!directory || !directory[0] || !output)
        return -EINVAL;
    error = search_directory(directory, "ROMv2_lm_patch", firmware, read_patch, &found);
    if (!error)
        error = wmt_patch_set_complete(&found.patches);
    if (!error)
        *output = found;
    return error;
}

static const uint8_t *find_bytes(const uint8_t *data, size_t size, const char *text)
{
    size_t length = strlen(text);

    if (size < length)
        return NULL;
    for (size_t i = 0; i <= size - length; i++) {
        if (!memcmp(data + i, text, length))
            return data + i;
    }
    return NULL;
}

static int bt_version(const uint8_t *data, size_t size,
                      char version[WMT_BT_VERSION_SIZE], bool *present)
{
    const char *start_marker = "BABEFACEBABEFACE";
    const char *end_marker = "DEADBEEFDEADBEEF";
    const uint8_t *start = find_bytes(data, size, start_marker);
    const uint8_t *end, *text, *nul;
    size_t length, span;

    *present = false;
    if (!start)
        return find_bytes(data, size, end_marker) ? -EBADMSG : 0;
    end = find_bytes(start + strlen(start_marker),
                     size - (size_t)(start - data) - strlen(start_marker), end_marker);
    if (!end)
        return -EBADMSG;
    span = (size_t)(end - start);
    /* The original marker scan accepts binary bytes, then its text search
     * stops at the first NUL. Keep both searches within the marker interval.
     */
    nul = memchr(start, '\0', span);
    if (nul)
        span = (size_t)(nul - start);
    text = find_bytes(start, span, "t-neptune");
    if (text) {
        length = (size_t)(end - text);
    } else if (find_bytes(start, span, "= debug")) {
        /* The retained ELF's fallback copies the first fourteen file bytes. */
        text = data;
        length = 14;
    } else {
        return 0;
    }
    if (length >= WMT_BT_VERSION_SIZE)
        length = WMT_BT_VERSION_SIZE - 1;
    memcpy(version, text, length);
    version[length] = '\0';
    char *newline = strchr(version, '\n');
    if (newline)
        *newline = '\0';
    *present = true;
    return 0;
}

static int read_bt_version(int fd, const struct stat *status,
                           char version[WMT_BT_VERSION_SIZE], bool *present)
{
    uint8_t *data, extra;
    size_t size;
    ssize_t bytes;
    int error;

    if (status->st_size < WMT_ROM_HEADER_SIZE)
        return -EMSGSIZE;
    if ((uint64_t)status->st_size > WMT_BT_VERSION_FILE_LIMIT)
        return -EFBIG;
    size = (size_t)status->st_size;
    data = malloc(size);
    if (!data)
        return -ENOMEM;
    if (lseek(fd, 0, SEEK_SET) < 0) {
        error = -errno;
    } else {
        error = read_exact(fd, data, size);
        if (!error) {
            do {
                bytes = read(fd, &extra, 1);
            } while (bytes < 0 && errno == EINTR);
            if (bytes < 0)
                error = -errno;
            else if (bytes)
                error = -ESTALE;
            else
                error = bt_version(data, size, version, present);
        }
    }
    free(data);
    return error;
}

static int read_rom(int fd, const struct stat *status, const char *name,
                    uint16_t firmware, void *result)
{
    struct wmt_rom_set *found = result;
    struct wmt_rom_info file = {0};
    uint8_t header[WMT_ROM_HEADER_SIZE];
    size_t name_size = strnlen(name, sizeof(file.name));
    uint32_t bit;
    int error;

    if (!name_size || name_size == sizeof(file.name) || strchr(name, '/'))
        return -EINVAL;
    error = read_exact(fd, header, sizeof(header));
    if (error)
        return error;
    if (header[23] != (firmware & 0xff))
        return 0;
    file.type = header[31];
    if (!(header[27] & 0xf0) || file.type >= WMT_ROM_TYPES)
        return -EINVAL;
    bit = 1U << file.type;
    if (found->seen & bit)
        return -EEXIST;
    memcpy(file.address + 1, header + 25, 3);
    memcpy(file.name, name, name_size + 1);
    if (strstr(name, "ram_wifi")) {
        char version[16];

        error = wmt_patch_build_version(header, sizeof(header), version);
        if (error)
            return error;
        if (found->has_wifi_version && strcmp(found->wifi_version, version))
            return -EINVAL;
        memcpy(found->wifi_version, version, sizeof(version));
        found->has_wifi_version = true;
    }
    if (strstr(name, "ram_bt")) {
        char version[WMT_BT_VERSION_SIZE] = {0};
        bool present;

        error = read_bt_version(fd, status, version, &present);
        if (error)
            return error;
        if (present) {
            if (found->has_bt_version && strcmp(found->bt_version, version))
                return -EINVAL;
            memcpy(found->bt_version, version, sizeof(version));
            found->has_bt_version = true;
        }
    }
    found->records[file.type] = file;
    found->seen |= bit;
    found->count++;
    return 0;
}

int wmt_rom_search(const char *directory, uint16_t firmware,
                   struct wmt_rom_set *output)
{
    struct wmt_rom_set found = {0};
    int error;

    if (!directory || !directory[0] || !output)
        return -EINVAL;
    error = search_directory(directory, "soc1_0_ram", firmware, read_rom, &found);
    if (!error)
        *output = found;
    return error;
}

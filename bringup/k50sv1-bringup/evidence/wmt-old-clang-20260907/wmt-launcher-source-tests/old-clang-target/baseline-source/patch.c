// SPDX-License-Identifier: Apache-2.0
#include "patch.h"

#include <errno.h>
#include <string.h>

_Static_assert(sizeof(struct wmt_patch_info) == 264, "WMT patch metadata ABI");
_Static_assert(offsetof(struct wmt_patch_info, address) == 4, "WMT patch address ABI");
_Static_assert(offsetof(struct wmt_patch_info, name) == 8, "WMT patch name ABI");

int wmt_patch_build_version(const uint8_t *header, size_t size, char version[16])
{
    if (!header || !version)
        return -EINVAL;
    if (size < 16)
        return -EMSGSIZE;
    memcpy(version, header, 15);
    version[15] = '\0';
    return 0;
}

int wmt_patch_parse(const uint8_t *header, size_t size, const char *basename,
                    uint16_t firmware, struct wmt_patch_file *output)
{
    struct wmt_patch_file parsed = {0};
    size_t name_length;

    if (!header || !basename || !output)
        return -EINVAL;
    if (size < WMT_PATCH_HEADER_SIZE)
        return -EMSGSIZE;
    name_length = strnlen(basename, WMT_PATCH_NAME_SIZE);
    if (!name_length || name_length == WMT_PATCH_NAME_SIZE || strchr(basename, '/'))
        return -EINVAL;
    /* The retained MT6755 launcher compares the low byte of the big-endian
     * firmware field, not its high byte or the adjacent hardware field.
     */
    if (header[23] != (firmware & 0xff))
        return 1;
    parsed.count = header[24] >> 4;
    parsed.info.sequence = header[24] & 0x0f;
    if (!parsed.count || parsed.count > WMT_MAX_PATCHES ||
        !parsed.info.sequence || parsed.info.sequence > parsed.count)
        return -EINVAL;
    memcpy(parsed.info.address + 1, header + 25, 3);
    memcpy(parsed.info.name, basename, name_length + 1);
    *output = parsed;
    return 0;
}

int wmt_patch_set_add(struct wmt_patch_set *set, const struct wmt_patch_file *file)
{
    uint32_t bit;

    if (!set || !file || !file->count || file->count > WMT_MAX_PATCHES ||
        !file->info.sequence || file->info.sequence > file->count ||
        !memchr(file->info.name, '\0', sizeof(file->info.name)))
        return -EINVAL;
    if (set->count && set->count != file->count)
        return -EINVAL;
    bit = 1U << (file->info.sequence - 1);
    if (set->seen & bit)
        return -EEXIST;
    set->records[file->info.sequence - 1] = file->info;
    set->count = file->count;
    set->seen |= bit;
    return 0;
}

int wmt_patch_set_complete(const struct wmt_patch_set *set)
{
    if (!set || set->count > WMT_MAX_PATCHES)
        return -EINVAL;
    if (!set->count)
        return -ENOENT;
    return set->seen == (1U << set->count) - 1 ? 0 : -ENODATA;
}

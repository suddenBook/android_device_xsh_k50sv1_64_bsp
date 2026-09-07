// SPDX-License-Identifier: Apache-2.0
#ifndef K50_WMT_LAUNCHER_PATCH_H
#define K50_WMT_LAUNCHER_PATCH_H

#include <stddef.h>
#include <stdint.h>

#define WMT_PATCH_HEADER_SIZE 28
#define WMT_PATCH_NAME_SIZE 256
#define WMT_MAX_PATCHES 10

/* Native and compat kernels use this same fixed-width metadata layout. */
struct wmt_patch_info {
    uint32_t sequence;
    uint8_t address[4];
    char name[WMT_PATCH_NAME_SIZE];
};

struct wmt_patch_file {
    uint32_t count;
    struct wmt_patch_info info;
};

struct wmt_patch_set {
    uint32_t count;
    uint32_t seen;
    struct wmt_patch_info records[WMT_MAX_PATCHES];
};

int wmt_patch_build_version(const uint8_t *header, size_t size, char version[16]);
/* Zero accepts the header, one skips a different firmware version, negative
 * errno reports malformed input. Output is untouched unless the header matches.
 */
int wmt_patch_parse(const uint8_t *header, size_t size, const char *basename,
                    uint16_t firmware, struct wmt_patch_file *output);
/* Start each search with a zero-initialized set; records are indexed by sequence. */
int wmt_patch_set_add(struct wmt_patch_set *set, const struct wmt_patch_file *file);
int wmt_patch_set_complete(const struct wmt_patch_set *set);

#endif

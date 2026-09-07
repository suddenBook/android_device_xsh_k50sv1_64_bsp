// SPDX-License-Identifier: Apache-2.0
#ifndef K50_WMT_LAUNCHER_FIRMWARE_H
#define K50_WMT_LAUNCHER_FIRMWARE_H

#include "patch.h"

#include <stdbool.h>
#include <stdint.h>

#define WMT_ROM_TYPES 5
#define WMT_ROM_HEADER_SIZE 32
#define WMT_BT_VERSION_SIZE 92
#define WMT_BT_VERSION_FILE_LIMIT (1024U * 1024U)

struct wmt_firmware_result {
    struct wmt_patch_set patches;
    char versions[WMT_MAX_PATCHES][16];
};

struct wmt_rom_info {
    uint32_t type;
    uint8_t address[4];
    char name[WMT_PATCH_NAME_SIZE];
};

struct wmt_rom_set {
    uint32_t count;
    uint32_t seen;
    struct wmt_rom_info records[WMT_ROM_TYPES];
    bool has_wifi_version;
    bool has_bt_version;
    char wifi_version[16];
    char bt_version[WMT_BT_VERSION_SIZE];
};

/* Return zero and replace output only after the complete search succeeds.
 * Negative errno leaves output untouched. Files and directories are only read;
 * callers own metadata submission and property publication.
 */
int wmt_firmware_search(const char *directory, uint16_t firmware,
                        struct wmt_firmware_result *output);
/* ROM types 0..4 are independently optional; no matching files is success.
 * Records are indexed by type, with presence indicated by seen.
 */
int wmt_rom_search(const char *directory, uint16_t firmware,
                   struct wmt_rom_set *output);

#endif

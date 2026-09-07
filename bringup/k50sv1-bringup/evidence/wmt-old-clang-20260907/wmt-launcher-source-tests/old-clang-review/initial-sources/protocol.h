// SPDX-License-Identifier: Apache-2.0
#ifndef K50_WMT_LAUNCHER_PROTOCOL_H
#define K50_WMT_LAUNCHER_PROTOCOL_H

#include <linux/mtk_wmt_cmd.h>
#include <stddef.h>
#include <stdint.h>

struct wmt_command {
    uint64_t session;
    uint64_t transaction;
    char text[WMT_CMD2_COMMAND_MAX + 1];
};

/* Decode one complete request from the bound session. Errors preserve output. */
int wmt_command_decode(const uint8_t *frame, size_t size, uint64_t session,
                       struct wmt_command *output);
/* Return the encoded size or a negative errno; errors preserve frame. */
int wmt_reply_status(const struct wmt_command *command, int result,
                     uint8_t *frame, size_t capacity);
int wmt_reply_list(const struct wmt_command *command, unsigned kind,
                   const struct wmt_cmd2_record *records, size_t count,
                   uint8_t *frame, size_t capacity);

#endif

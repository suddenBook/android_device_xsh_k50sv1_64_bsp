// SPDX-License-Identifier: Apache-2.0
#include "protocol.h"

#include <errno.h>
#include <string.h>

_Static_assert(sizeof(struct wmt_cmd2_header) == 32, "WMT frame header ABI");
_Static_assert(offsetof(struct wmt_cmd2_header, session_id) == 8, "WMT session ABI");
_Static_assert(offsetof(struct wmt_cmd2_header, transaction_id) == 16, "WMT transaction ABI");
_Static_assert(offsetof(struct wmt_cmd2_header, payload_len) == 24, "WMT payload ABI");
_Static_assert(offsetof(struct wmt_cmd2_header, result) == 28, "WMT result ABI");
_Static_assert(sizeof(struct wmt_cmd2_session) == 32, "WMT session ioctl ABI");
_Static_assert(offsetof(struct wmt_cmd2_session, max_read_bytes) == 16, "WMT limits ABI");
_Static_assert(sizeof(struct wmt_cmd2_record) == 264, "WMT list record ABI");
_Static_assert(offsetof(struct wmt_cmd2_list, record) == 8, "WMT list prefix ABI");
_Static_assert(WMT_IOCTL_CMD2_SESSION == 0xc020a040U, "WMT native/compat ioctl ABI");

static uint16_t read16(const uint8_t *data)
{
    return (uint16_t)data[0] | (uint16_t)data[1] << 8;
}

static uint32_t read32(const uint8_t *data)
{
    return (uint32_t)data[0] | (uint32_t)data[1] << 8 |
           (uint32_t)data[2] << 16 | (uint32_t)data[3] << 24;
}

static uint64_t read64(const uint8_t *data)
{
    return (uint64_t)read32(data) | (uint64_t)read32(data + 4) << 32;
}

static void write16(uint8_t *data, uint16_t value)
{
    data[0] = value;
    data[1] = value >> 8;
}

static void write32(uint8_t *data, uint32_t value)
{
    for (unsigned i = 0; i < 4; i++)
        data[i] = value >> (8 * i);
}

static void write64(uint8_t *data, uint64_t value)
{
    write32(data, (uint32_t)value);
    write32(data + 4, (uint32_t)(value >> 32));
}

int wmt_command_decode(const uint8_t *frame, size_t size, uint64_t session,
                       struct wmt_command *output)
{
    struct wmt_command command = {0};
    uint32_t length;

    if (!frame || !session || !output)
        return -EINVAL;
    if (size < WMT_CMD2_FRAME_HEADER_SIZE)
        return -EMSGSIZE;
    if (read32(frame) != WMT_CMD2_MAGIC || read16(frame + 4) != WMT_CMD2_VERSION)
        return -EPROTONOSUPPORT;
    if (read16(frame + 6) != WMT_CMD2_COMMAND || read32(frame + 28) != 0)
        return -EPROTO;
    command.session = read64(frame + 8);
    command.transaction = read64(frame + 16);
    if (command.session != session)
        return -ESTALE;
    if (!command.transaction)
        return -EPROTO;
    length = read32(frame + 24);
    if (!length || length > WMT_CMD2_COMMAND_MAX ||
        size != WMT_CMD2_FRAME_HEADER_SIZE + length)
        return -EMSGSIZE;
    if (memchr(frame + WMT_CMD2_FRAME_HEADER_SIZE, '\0', length))
        return -EPROTO;
    memcpy(command.text, frame + WMT_CMD2_FRAME_HEADER_SIZE, length);
    *output = command;
    return 0;
}

static void reply_header(const struct wmt_command *command, unsigned kind,
                         uint32_t length, int result, uint8_t *frame)
{
    write32(frame, WMT_CMD2_MAGIC);
    write16(frame + 4, WMT_CMD2_VERSION);
    write16(frame + 6, kind);
    write64(frame + 8, command->session);
    write64(frame + 16, command->transaction);
    write32(frame + 24, length);
    write32(frame + 28, (uint32_t)result);
}

int wmt_reply_status(const struct wmt_command *command, int result,
                     uint8_t *frame, size_t capacity)
{
    if (!command || !command->session || !command->transaction || !frame ||
        result > 0 || result < -4095)
        return -EINVAL;
    if (capacity < WMT_CMD2_FRAME_HEADER_SIZE)
        return -EMSGSIZE;
    reply_header(command, WMT_CMD2_STATUS, 0, result, frame);
    return WMT_CMD2_FRAME_HEADER_SIZE;
}

int wmt_reply_list(const struct wmt_command *command, unsigned kind,
                   const struct wmt_cmd2_record *records, size_t count,
                   uint8_t *frame, size_t capacity)
{
    uint32_t seen = 0;
    size_t length, maximum;

    if (!command || !command->session || !command->transaction || !frame ||
        (count && !records))
        return -EINVAL;
    if (kind == WMT_CMD2_PATCH_LIST) {
        if (!count)
            return -EINVAL;
        maximum = WMT_CMD2_PATCH_MAX;
    } else if (kind == WMT_CMD2_ROM_LIST) {
        maximum = WMT_CMD2_ROM_MAX;
    } else {
        return -EINVAL;
    }
    if (count > maximum)
        return -E2BIG;
    length = 8 + count * WMT_CMD2_RECORD_SIZE;
    if (capacity < WMT_CMD2_FRAME_HEADER_SIZE + length)
        return -EMSGSIZE;
    for (size_t i = 0; i < count; i++) {
        uint32_t index = records[i].index;
        uint32_t bit;
        const char *name = (const char *)records[i].name;
        size_t name_length = strnlen(name, sizeof(records[i].name));

        if (kind == WMT_CMD2_PATCH_LIST) {
            if (!index || index > count)
                return -EINVAL;
            index--;
        } else if (index >= WMT_CMD2_ROM_MAX) {
            return -EINVAL;
        }
        bit = 1U << index;
        if (seen & bit)
            return -EEXIST;
        if (!name_length || name_length == sizeof(records[i].name) ||
            memchr(name, '/', name_length) || !strcmp(name, ".") || !strcmp(name, ".."))
            return -EINVAL;
        seen |= bit;
    }
    reply_header(command, kind, length, 0, frame);
    write32(frame + 32, count);
    write32(frame + 36, 0);
    for (size_t i = 0; i < count; i++) {
        uint8_t *record = frame + 40 + i * WMT_CMD2_RECORD_SIZE;
        write32(record, records[i].index);
        memcpy(record + 4, records[i].address, 4);
        memset(record + 8, 0, 256);
        memcpy(record + 8, records[i].name, strlen((const char *)records[i].name));
    }
    return WMT_CMD2_FRAME_HEADER_SIZE + length;
}

// SPDX-License-Identifier: Apache-2.0
#include "protocol.h"

#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>

/* Independent literal wire vector; deliberately nonsymmetric 64-bit IDs. */
static const uint8_t request[] = {
    'W', 'M', 'T', '2', 2, 0, 1, 0,
    1, 2, 3, 4, 5, 6, 7, 8,
    0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
    9, 0, 0, 0, 0, 0, 0, 0,
    's', 'r', 'h', '_', 'p', 'a', 't', 'c', 'h',
};

static unsigned passed;

static void done(const char *name)
{
    printf("PASS %s\n", name);
    passed++;
}

static void decode_error(const uint8_t *frame, size_t length, int expected)
{
    struct wmt_command output, before;
    memset(&output, 0xa5, sizeof(output));
    memcpy(&before, &output, sizeof(before));
    assert(wmt_command_decode(frame, length, UINT64_C(0x0807060504030201), &output) == expected);
    assert(!memcmp(&output, &before, sizeof(output)));
}

int main(void)
{
    struct wmt_command command;
    struct wmt_cmd2_record records[10] = {0};
    uint8_t input[WMT_CMD2_READ_MAX + 1], output[WMT_CMD2_WRITE_MAX + 1], before[sizeof(output)];

    assert(wmt_command_decode(request, sizeof(request), UINT64_C(0x0807060504030201), &command) == 0);
    assert(command.session == UINT64_C(0x0807060504030201));
    assert(command.transaction == UINT64_C(0x8877665544332211));
    assert(!strcmp(command.text, "srh_patch"));
    done("literal-request-and-64-bit-identities");
    for (size_t size = 0; size < sizeof(request); size++)
        decode_error(request, size, -EMSGSIZE);
    done("every-truncated-request-preserves-output");
    memcpy(input, request, sizeof(request));
    input[sizeof(request)] = 1;
    decode_error(input, sizeof(request) + 1, -EMSGSIZE);
    done("trailing-byte-rejected");
    input[0] = 'X';
    decode_error(input, sizeof(request), -EPROTONOSUPPORT);
    input[0] = 'W';
    input[4] = 3;
    decode_error(input, sizeof(request), -EPROTONOSUPPORT);
    input[4] = 2;
    done("wrong-magic-or-version");
    input[6] = WMT_CMD2_STATUS;
    decode_error(input, sizeof(request), -EPROTO);
    input[6] = WMT_CMD2_COMMAND;
    input[28] = 1;
    decode_error(input, sizeof(request), -EPROTO);
    input[28] = 0;
    done("wrong-request-kind-or-result");
    input[15] ^= 0x80;
    decode_error(input, sizeof(request), -ESTALE);
    input[15] ^= 0x80;
    memset(input + 16, 0, 8);
    decode_error(input, sizeof(request), -EPROTO);
    memcpy(input, request, sizeof(request));
    done("session-mismatch-and-zero-transaction");
    input[35] = 0;
    decode_error(input, sizeof(request), -EPROTO);
    memcpy(input, request, sizeof(request));
    done("embedded-command-nul");
    input[24] = 0;
    decode_error(input, 32, -EMSGSIZE);
    input[25] = 1;
    decode_error(input, sizeof(input), -EMSGSIZE);
    memset(input + 24, 0xff, 4);
    decode_error(input, sizeof(input), -EMSGSIZE);
    memcpy(input, request, sizeof(request));
    done("zero-oversize-and-overflow-lengths");
    input[24] = 255;
    memset(input + 32, 'q', 255);
    assert(wmt_command_decode(input, 287, command.session, &command) == 0);
    assert(strlen(command.text) == 255 && command.text[255] == 0);
    done("maximum-command-length");
    assert(wmt_command_decode(request, sizeof(request), command.session, &command) == 0);

    memset(output, 0xa5, sizeof(output));
    assert(wmt_reply_status(&command, -ENOENT, output, sizeof(output)) == 32);
    assert(!memcmp(output, request, 6) && output[6] == 2 && output[7] == 0);
    assert(!memcmp(output + 8, request + 8, 16));
    assert(!memcmp(output + 24, "\0\0\0\0\376\377\377\377", 8));
    assert(output[32] == 0xa5);
    done("literal-negative-reply-retains-original-identities");
    memcpy(before, output, sizeof(output));
    assert(wmt_reply_status(&command, 1, output, sizeof(output)) == -EINVAL);
    assert(wmt_reply_status(&command, -4096, output, sizeof(output)) == -EINVAL);
    assert(wmt_reply_status(&command, 0, output, 31) == -EMSGSIZE);
    assert(!memcmp(before, output, sizeof(output)));
    done("invalid-status-and-short-output-preserved");

    records[0].index = 2;
    memcpy(records[0].address, "\0\0\6\0", 4);
    strcpy((char *)records[0].name, "ROMv2_lm_patch_1_0_hdr.bin");
    records[1].index = 1;
    memcpy(records[1].address, "\0\0\12\360", 4);
    strcpy((char *)records[1].name, "ROMv2_lm_patch_1_1_hdr.bin");
    assert(wmt_reply_list(&command, WMT_CMD2_PATCH_LIST, records, 2, output, sizeof(output)) == 568);
    assert(!memcmp(output + 8, request + 8, 16));
    assert(!memcmp(output + 24, "\30\2\0\0\0\0\0\0", 8));
    assert(!memcmp(output + 32, "\2\0\0\0\0\0\0\0", 8));
    assert(!memcmp(output + 40, "\2\0\0\0\0\0\6\0", 8));
    assert(!memcmp(output + 304, "\1\0\0\0\0\0\12\360", 8));
    assert(!strcmp((char *)output + 48, "ROMv2_lm_patch_1_0_hdr.bin"));
    assert(!strcmp((char *)output + 312, "ROMv2_lm_patch_1_1_hdr.bin"));
    done("two-real-metadata-record-layouts-and-reversed-sequences");
    memcpy(before, output, sizeof(output));
    records[1].index = 2;
    assert(wmt_reply_list(&command, WMT_CMD2_PATCH_LIST, records, 2, output, sizeof(output)) == -EEXIST);
    records[1].index = 0;
    assert(wmt_reply_list(&command, WMT_CMD2_PATCH_LIST, records, 2, output, sizeof(output)) == -EINVAL);
    records[1].index = 3;
    assert(wmt_reply_list(&command, WMT_CMD2_PATCH_LIST, records, 2, output, sizeof(output)) == -EINVAL);
    records[1].index = 1;
    assert(!memcmp(before, output, sizeof(output)));
    done("duplicate-and-incomplete-sequence-lists-preserve-output");
    const char *bad_names[] = {"", "/patch", ".", ".."};
    for (size_t i = 0; i < sizeof(bad_names) / sizeof(bad_names[0]); i++) {
        memset(records[1].name, 0, 256);
        strcpy((char *)records[1].name, bad_names[i]);
        assert(wmt_reply_list(&command, WMT_CMD2_PATCH_LIST, records, 2, output, sizeof(output)) == -EINVAL);
    }
    memset(records[1].name, 'x', 256);
    assert(wmt_reply_list(&command, WMT_CMD2_PATCH_LIST, records, 2, output, sizeof(output)) == -EINVAL);
    assert(!memcmp(before, output, sizeof(output)));
    done("invalid-or-unterminated-basenames");
    assert(wmt_reply_list(&command, WMT_CMD2_PATCH_LIST, records, 0, output, sizeof(output)) == -EINVAL);
    assert(wmt_reply_list(&command, WMT_CMD2_PATCH_LIST, records, 11, output, sizeof(output)) == -E2BIG);
    assert(wmt_reply_list(&command, WMT_CMD2_PATCH_LIST, records, 2, output, 567) == -EMSGSIZE);
    assert(!memcmp(before, output, sizeof(output)));
    done("invalid-list-count-or-short-output");
    assert(wmt_reply_list(&command, WMT_CMD2_ROM_LIST, NULL, 0, output, sizeof(output)) == 40);
    assert(output[6] == 4 && !memcmp(output + 32, "\0\0\0\0\0\0\0\0", 8));
    records[0].index = 4;
    assert(wmt_reply_list(&command, WMT_CMD2_ROM_LIST, records, 1, output, sizeof(output)) == 304);
    assert(output[40] == 4);
    done("empty-rom-and-optional-wmt-sentinel");
    for (unsigned i = 0; i < 10; i++) {
        records[i].index = i + 1;
        memset(records[i].name, 0xa5, 256);
        snprintf((char *)records[i].name, 256, "patch-%u", i + 1);
    }
    assert(wmt_reply_list(&command, WMT_CMD2_PATCH_LIST, records, 10, output, sizeof(output)) == 2680);
    assert(output[2679] == 0 && output[2680] == 0xa5);
    for (unsigned i = 0; i < 5; i++)
        records[i].index = i;
    assert(wmt_reply_list(&command, WMT_CMD2_ROM_LIST, records, 5, output, sizeof(output)) == 1360);
    records[4].index = 5;
    assert(wmt_reply_list(&command, WMT_CMD2_ROM_LIST, records, 5, output, sizeof(output)) == -EINVAL);
    done("maximum-lists-with-zeroed-name-padding-and-rom-type-bound");
    assert(wmt_command_decode(NULL, 0, command.session, &command) == -EINVAL);
    assert(wmt_command_decode(request, sizeof(request), 0, &command) == -EINVAL);
    assert(wmt_reply_list(&command, WMT_CMD2_COMMAND, records, 1, output, sizeof(output)) == -EINVAL);
    done("invalid-api-and-list-kind");
    printf("{\"passed\":%u,\"total\":18}\n", passed);
    return passed == 18 ? 0 : 1;
}

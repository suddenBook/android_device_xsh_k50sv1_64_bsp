// SPDX-License-Identifier: Apache-2.0
#include "patch.h"

#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void load(const char *path, uint8_t header[WMT_PATCH_HEADER_SIZE])
{
    FILE *file = fopen(path, "rb");
    assert(file);
    assert(fread(header, 1, WMT_PATCH_HEADER_SIZE, file) == WMT_PATCH_HEADER_SIZE);
    assert(fclose(file) == 0);
}

int main(int argc, char **argv)
{
    uint8_t a[WMT_PATCH_HEADER_SIZE], b[WMT_PATCH_HEADER_SIZE], changed[WMT_PATCH_HEADER_SIZE];
    const char *name_a = "ROMv2_lm_patch_1_0_hdr.bin";
    const char *name_b = "ROMv2_lm_patch_1_1_hdr.bin";
    struct wmt_patch_file first, second, output, before;
    struct wmt_patch_set set = {0}, saved;
    char version[16], name[WMT_PATCH_NAME_SIZE + 1];
    unsigned passed = 0;

    assert(argc == 3);
    load(argv[1], a);
    load(argv[2], b);
    assert(wmt_patch_parse(a, sizeof(a), name_a, 0x8a00, &first) == 0);
    assert(first.count == 2 && first.info.sequence == 2);
    assert(!memcmp(first.info.address, "\0\0\6\0", 4));
    assert(!strcmp(first.info.name, name_a));
    passed++;
    assert(wmt_patch_parse(b, sizeof(b), name_b, 0x8a00, &second) == 0);
    assert(second.count == 2 && second.info.sequence == 1);
    assert(!memcmp(second.info.address, "\0\0\12\360", 4));
    passed++;
    assert(wmt_patch_set_add(&set, &first) == 0);
    assert(wmt_patch_set_complete(&set) == -ENODATA);
    assert(wmt_patch_set_add(&set, &second) == 0);
    assert(wmt_patch_set_complete(&set) == 0);
    assert(!memcmp(&set.records[0], &second.info, sizeof(second.info)));
    assert(!memcmp(&set.records[1], &first.info, sizeof(first.info)));
    passed++;

    memcpy(changed, a, sizeof(a));
    changed[22] = 0x7b;
    assert(wmt_patch_parse(changed, sizeof(changed), name_a, 0x8a00, &output) == 0);
    passed++;
    changed[20] = 0x13;
    changed[21] = 0x37;
    assert(wmt_patch_parse(changed, sizeof(changed), name_a, 0x8a00, &output) == 0);
    passed++;
    memset(&output, 0xa5, sizeof(output));
    before = output;
    changed[23] = 1;
    assert(wmt_patch_parse(changed, sizeof(changed), name_a, 0x8a00, &output) == 1);
    assert(!memcmp(&output, &before, sizeof(output)));
    passed++;
    for (size_t size = 0; size < sizeof(a); size++) {
        assert(wmt_patch_parse(a, size, name_a, 0x8a00, &output) == -EMSGSIZE);
        assert(!memcmp(&output, &before, sizeof(output)));
    }
    passed++;
    memcpy(changed, a, sizeof(a));
    for (unsigned count = 0; count <= 15; count++) {
        if (count && count <= WMT_MAX_PATCHES)
            continue;
        changed[24] = (count << 4) | 1;
        assert(wmt_patch_parse(changed, sizeof(changed), name_a, 0x8a00, &output) == -EINVAL);
        assert(!memcmp(&output, &before, sizeof(output)));
    }
    passed++;
    for (unsigned seq = 0; seq <= 15; seq++) {
        if (seq && seq <= 2)
            continue;
        changed[24] = 0x20 | seq;
        assert(wmt_patch_parse(changed, sizeof(changed), name_a, 0x8a00, &output) == -EINVAL);
    }
    passed++;

    saved = set;
    output = first;
    output.info.address[2] = 0xff;
    assert(wmt_patch_set_add(&set, &output) == -EEXIST);
    assert(!memcmp(&set, &saved, sizeof(set)));
    passed++;
    output.count = 3;
    output.info.sequence = 3;
    assert(wmt_patch_set_add(&set, &output) == -EINVAL);
    assert(!memcmp(&set, &saved, sizeof(set)));
    passed++;
    memset(&set, 0, sizeof(set));
    assert(wmt_patch_set_complete(&set) == -ENOENT);
    passed++;
    output = first;
    output.count = WMT_MAX_PATCHES;
    for (unsigned seq = WMT_MAX_PATCHES; seq > 0; seq--) {
        output.info.sequence = seq;
        assert(wmt_patch_set_add(&set, &output) == 0);
    }
    assert(wmt_patch_set_complete(&set) == 0);
    passed++;

    memset(name, 'x', sizeof(name));
    name[WMT_PATCH_NAME_SIZE - 1] = '\0';
    assert(wmt_patch_parse(a, sizeof(a), name, 0x8a00, &output) == 0);
    name[WMT_PATCH_NAME_SIZE - 1] = 'x';
    name[WMT_PATCH_NAME_SIZE] = '\0';
    assert(wmt_patch_parse(a, sizeof(a), name, 0x8a00, &output) == -EINVAL);
    passed++;
    assert(wmt_patch_parse(a, sizeof(a), "", 0x8a00, &output) == -EINVAL);
    assert(wmt_patch_parse(a, sizeof(a), "/vendor/firmware/patch.bin", 0x8a00, &output) == -EINVAL);
    passed++;
    assert(wmt_patch_build_version(a, sizeof(a), version) == 0);
    assert(!strcmp(version, "20200629194517a"));
    assert(wmt_patch_build_version(b, sizeof(b), version) == 0);
    assert(!strcmp(version, "20200629194517a"));
    memset(version, 'x', sizeof(version));
    assert(wmt_patch_build_version(a, 15, version) == -EMSGSIZE);
    assert(version[15] == 'x');
    passed++;
    assert(wmt_patch_parse(NULL, sizeof(a), name_a, 0x8a00, &output) == -EINVAL);
    assert(wmt_patch_parse(a, sizeof(a), NULL, 0x8a00, &output) == -EINVAL);
    assert(wmt_patch_parse(a, sizeof(a), name_a, 0x8a00, NULL) == -EINVAL);
    assert(wmt_patch_build_version(NULL, sizeof(a), version) == -EINVAL);
    assert(wmt_patch_build_version(a, sizeof(a), NULL) == -EINVAL);
    assert(wmt_patch_set_add(NULL, &first) == -EINVAL);
    assert(wmt_patch_set_add(&set, NULL) == -EINVAL);
    assert(wmt_patch_set_complete(NULL) == -EINVAL);
    passed++;
    printf("{\"passed\":%u,\"total\":17}\n", passed);
    return passed == 17 ? 0 : 1;
}

/* Design artifact only: proposed paired WMT command ABI, not installed UAPI. */
#ifndef WMT_COMMAND_V2_DESIGN_H
#define WMT_COMMAND_V2_DESIGN_H

#include <stdint.h>

/* Every multibyte field is little-endian. Both target ABIs are little-endian. */
typedef uint64_t wmt_cmd2_u64 __attribute__((aligned(8)));

#define WMT_CMD2_MAGIC UINT32_C(0x32544d57) /* W M T 2 in byte order */
#define WMT_CMD2_VERSION 2
#define WMT_CMD2_COMMAND_MAX 255
#define WMT_CMD2_PATCH_MAX 10
#define WMT_CMD2_ROM_MAX 5
#define WMT_CMD2_FRAME_HEADER_SIZE 32
#define WMT_CMD2_RECORD_SIZE 264
#define WMT_CMD2_READ_MAX (32 + WMT_CMD2_COMMAND_MAX)
#define WMT_CMD2_WRITE_MAX (32 + 8 + WMT_CMD2_PATCH_MAX * WMT_CMD2_RECORD_SIZE)

enum wmt_cmd2_kind {
    WMT_CMD2_COMMAND = 1,
    WMT_CMD2_STATUS = 2,
    WMT_CMD2_PATCH_LIST = 3,
    WMT_CMD2_ROM_LIST = 4,
};

struct wmt_cmd2_header {
    uint32_t magic;               /* +0 */
    uint16_t version;             /* +4 */
    uint16_t kind;                /* +6 */
    wmt_cmd2_u64 session_id;      /* +8: nonzero, unique during the boot */
    wmt_cmd2_u64 transaction_id;  /* +16: nonzero, never reused in a session */
    uint32_t payload_len;         /* +24: exact bytes following this header */
    int32_t result;               /* +28: request/list success=0; error<0 */
};

struct wmt_cmd2_record {
    uint32_t index;               /* +0: patch sequence 1..N, or ROM type 0..4 */
    uint8_t address[4];           /* +4: opaque address bytes, no integer cast */
    uint8_t name[256];            /* +8: nonempty, NUL-terminated filename */
};

struct wmt_cmd2_list {
    uint32_t count;               /* +0 */
    uint32_t reserved;            /* +4: must be zero */
    struct wmt_cmd2_record record[]; /* +8 */
};

enum wmt_cmd2_session_action {
    WMT_CMD2_BIND = 1,
    WMT_CMD2_UNBIND = 2,
};

struct wmt_cmd2_session {
    uint32_t version;             /* +0: input=2, output=2 */
    uint32_t action;              /* +4: BIND or UNBIND */
    wmt_cmd2_u64 session_id;      /* +8: BIND input=0; UNBIND input=current ID */
    uint32_t max_read_bytes;      /* +16: input=0, output=287 */
    uint32_t max_write_bytes;     /* +20: input=0, output=2680 */
    uint32_t flags;               /* +24: input/output=0 in v2 */
    uint32_t reserved;            /* +28: input/output=0 */
};

/* _IOWR(0xa0, 64, struct wmt_cmd2_session), identical native/compat number.
 * The paired kernel UAPI should define this with its actual _IOWR macro and
 * __u32/__s32/__aligned_u64 types. No pointer-sized fields or nested pointers.
 */
#define WMT_IOCTL_CMD2_SESSION UINT32_C(0xc020a040)

#endif

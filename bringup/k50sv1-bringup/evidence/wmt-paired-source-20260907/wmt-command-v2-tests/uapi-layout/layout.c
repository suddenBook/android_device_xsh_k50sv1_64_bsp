#include "/home/desmond/Downloads/k50sv1_64_bsp/work/.capture-staging/source-replacement-20260905/wmt-command-v2-kernel-work/include/uapi/linux/mtk_wmt_cmd.h"
#define OFF(type,member) __builtin_offsetof(struct type,member)
_Static_assert(sizeof(struct wmt_cmd2_header)==32,"header");
_Static_assert(sizeof(struct wmt_cmd2_session)==32,"session");
_Static_assert(sizeof(struct wmt_cmd2_record)==264,"record");
_Static_assert(sizeof(struct wmt_cmd2_list)==8,"list");
_Static_assert(OFF(wmt_cmd2_header,session_id)==8,"session offset");
_Static_assert(OFF(wmt_cmd2_header,transaction_id)==16,"transaction offset");
_Static_assert(OFF(wmt_cmd2_header,payload_len)==24,"payload offset");
_Static_assert(OFF(wmt_cmd2_header,result)==28,"result offset");
_Static_assert(OFF(wmt_cmd2_session,session_id)==8,"bind id offset");
_Static_assert(OFF(wmt_cmd2_session,max_read_bytes)==16,"read maximum offset");
_Static_assert(OFF(wmt_cmd2_session,reserved)==28,"reserved offset");
_Static_assert(WMT_IOCTL_CMD2_SESSION==0xc020a040U,"native/compat ioctl");

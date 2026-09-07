#include <stddef.h>
#include <stdbool.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sound/asound.h>
#include <sound/compress_params.h>
#include <sound/compress_offload.h>
#include <tinycompress/tinycompress.h>
#if defined(__aarch64__)
_Static_assert(sizeof(struct compr_config) == 16, "64-bit config");
#else
_Static_assert(sizeof(struct compr_config) == 12, "32-bit config");
#endif
_Static_assert(offsetof(struct compr_config, codec) == 8, "codec pointer");
_Static_assert(sizeof(struct snd_codec) == 120, "codec");
_Static_assert(_Alignof(struct snd_codec) == 4, "codec alignment");
_Static_assert(offsetof(struct snd_codec, options) == 44, "codec options");
_Static_assert(sizeof(((struct snd_codec *)0)->options) == 64, "options size");
_Static_assert(offsetof(struct snd_codec, reserved) == 108, "reserved");
_Static_assert(sizeof(struct snd_compr_params) == 132, "params");
_Static_assert(offsetof(struct snd_compr_params, codec) == 8, "params codec");
_Static_assert(offsetof(struct snd_compr_params, no_wake_mode) == 128, "wake mode");
_Static_assert(sizeof(struct snd_compr_caps) == 196, "caps");
_Static_assert(sizeof(struct snd_compr_tstamp) == 20, "tstamp");
_Static_assert(sizeof(struct snd_compr_avail) == 28, "avail");
_Static_assert(SNDRV_COMPRESS_GET_CAPS == 0xc0c44310u, "GET_CAPS");
_Static_assert(SNDRV_COMPRESS_SET_PARAMS == 0x40844312u, "SET_PARAMS");
_Static_assert(SNDRV_COMPRESS_TSTAMP == 0x80144320u, "TSTAMP");
_Static_assert(SNDRV_COMPRESS_AVAIL == 0x801c4321u, "AVAIL");
int layout_contract;

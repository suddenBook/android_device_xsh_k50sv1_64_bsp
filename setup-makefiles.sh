#!/bin/bash

set -e

DEVICE=k50sv1_64_bsp
VENDOR=xsh
INITIAL_COPYRIGHT_YEAR=2026

[[ $# -le 1 ]] || { echo "Usage: $0 [Android source root]" >&2; exit 2; }
if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
    echo "Usage: $0 [Android source root]"
    exit 0
fi
ANDROID_ROOT_ARG="${1:-${ANDROID_BUILD_TOP:-}}"

# Keep the invocation path while locating the checkout: it may pass through
# device/xsh/<device> in a different checkout than the physical repository.
MY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${ANDROID_ROOT_ARG}" ]]; then
    ROOT_CANDIDATES=("${ANDROID_ROOT_ARG}")
else
    ROOT_CANDIDATES=("${MY_DIR}/../../.." "${MY_DIR}/../../lineage-17.1")
fi
LINEAGE_ROOT=
for candidate in "${ROOT_CANDIDATES[@]}"; do
    if candidate="$(cd -L "${candidate}" 2>/dev/null && pwd -P)" &&
            [[ -f "${candidate}/vendor/lineage/build/tools/extract_utils.sh" ]]; then
        LINEAGE_ROOT="${candidate}"
        break
    fi
done
if [[ -z "${LINEAGE_ROOT}" ]]; then
    echo "Unable to find extract_utils.sh; pass an Android source root or set ANDROID_BUILD_TOP." >&2
    exit 2
fi
MY_DIR="$(cd "${MY_DIR}" && pwd -P)"
HELPER="${LINEAGE_ROOT}/vendor/lineage/build/tools/extract_utils.sh"

# shellcheck source=/dev/null
source "${HELPER}"

setup_vendor "${DEVICE}" "${VENDOR}" "${LINEAGE_ROOT}"
# Generate and validate the complete set before updating the existing files.
MAKEFILE_OUTPUTS=("${ANDROIDMK}" "${BOARDMK}" "${PRODUCTMK}" "${ANDROIDBP}")
SETUP_STAGE="$(mktemp -d "${LINEAGE_ROOT}/${OUTDIR}/.setup-makefiles.XXXXXX")"
trap 'rm -rf -- "${SETUP_STAGE}"; cleanup' EXIT
ANDROIDMK="${SETUP_STAGE}/${ANDROIDMK##*/}"
BOARDMK="${SETUP_STAGE}/${BOARDMK##*/}"
PRODUCTMK="${SETUP_STAGE}/${PRODUCTMK##*/}"
ANDROIDBP="${SETUP_STAGE}/${ANDROIDBP##*/}"

write_headers
write_makefiles "${MY_DIR}/proprietary-files.txt"

# Finish the staged Android.mk before validating the generated Soong modules.
write_footers

# The generated vendor product owns all blob copies. Append one stable include
# that filters only the exact legacy ePDG/strongSwan closure from Tier 3; the
# included file asserts that all 29 generated entries still exist, so a future
# extraction cannot silently weaken or broaden the release exclusion. This is
# after write_footers so a write failure cannot leave Android.mk unterminated.
printf '\ninclude device/%s/%s/legacy-vowifi-vendor-filter.mk\n' \
    "${VENDOR}" "${DEVICE}" >>"${PRODUCTMK}"

# ImsService is defined by hand in device/xsh/k50sv1_64_bsp/ims/Android.mk so
# that the privileged APK actually lands in /system/priv-app and can be
# dexpreopted; Android Q's Soong android_app_import cannot do either. Drop the
# generated duplicate here. Each android_app_import is parsed as a balanced
# block so a formatting change cannot make this delete a neighbouring module.
(
    patched_bp="$(mktemp "${ANDROIDBP}.ims.XXXXXX")"
    trap 'rm -f -- "${patched_bp}"' EXIT

    perl - "${ANDROIDBP}" >"${patched_bp}" <<'PERL'
use strict;
use warnings;

my $path = shift @ARGV;
open my $input, '<', $path or die "Cannot read $path: $!\n";
local $/;
my $text = <$input>;
close $input or die "Cannot close $path: $!\n";

my @lines = split /(?<=\n)/, $text, -1;
my $output = '';
my $removed = 0;

for (my $index = 0; $index < @lines;) {
    if ($lines[$index] !~ /^android_app_import\s*\{\s*$/) {
        $output .= $lines[$index++];
        next;
    }

    my $block = '';
    my $depth = 0;
    do {
        die "Unterminated android_app_import in $path\n" if $index >= @lines;
        my $line = $lines[$index++];
        $block .= $line;
        $depth += () = $line =~ /\{/g;
        $depth -= () = $line =~ /\}/g;
        die "Unbalanced android_app_import in $path\n" if $depth < 0;
    } while ($depth != 0);

    if ($block =~ /^\s*name:\s*"ImsService",\s*$/m) {
        ++$removed;
        # Also swallow the blank separator line the generator emits.
        ++$index if $index < @lines && $lines[$index] =~ /^\s*$/;
        next;
    }

    $output .= $block;
}

die "Expected exactly one generated ImsService module in $path\n"
    unless $removed == 1;
print $output;
PERL

    chmod --reference="${ANDROIDBP}" "${patched_bp}"
    mv -f -- "${patched_bp}" "${ANDROIDBP}"
)

for output in "${MAKEFILE_OUTPUTS[@]}"; do
    mv -f -- "${SETUP_STAGE}/${output##*/}" "${output}"
done

#!/bin/bash

set -e

DEVICE=k50sv1_64_bsp
VENDOR=xsh
INITIAL_COPYRIGHT_YEAR=2026

MY_DIR="${BASH_SOURCE%/*}"
if [[ ! -d "${MY_DIR}" ]]; then
    MY_DIR="${PWD}"
fi

LINEAGE_ROOT="${MY_DIR}/../../.."
HELPER="${LINEAGE_ROOT}/vendor/lineage/build/tools/extract_utils.sh"

if [[ ! -f "${HELPER}" ]]; then
    echo "Unable to find extract_utils.sh at ${HELPER}" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "${HELPER}"

setup_vendor "${DEVICE}" "${VENDOR}" "${LINEAGE_ROOT}"
write_headers
write_makefiles "${MY_DIR}/proprietary-files.txt"

# Close the vendor Android.mk's `ifeq` BEFORE the Soong patch below, not after.
# write_headers appends `ifeq ($(TARGET_DEVICE),k50sv1_64_bsp)` to $ANDROIDMK
# (extract_utils.sh write_headers) and write_footers appends the matching
# `endif` (extract_utils.sh write_footers); nothing between them touches
# $ANDROIDMK. The patch below has three `die` paths, and under `set -e` any of
# them would abort the script with $ANDROIDMK left unterminated -- every later
# lunch/make then fails inside the vendor tree with an error that points nowhere
# near the cause. Ordering it this way makes that impossible rather than
# recoverable.
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

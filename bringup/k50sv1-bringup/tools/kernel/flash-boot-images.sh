#!/usr/bin/env bash
# Kernel-only iteration flash for k50sv1_64_bsp.
#
# When only the kernel changed, the four-image contract build/stage/flash
# chain (run-lineage-build.sh -> stage-tier-images.sh -> flash-tier-images.sh)
# is a full clean build for no benefit.  This flashes the freshly built
# boot.img and recovery.img from out/ over an unchanged system/vendor, with
# the mandatory userdata/metadata/cache erase, and writes a receipt that
# records exactly what was flashed and which source revisions produced it.
# It is not a stage contract; the next four-image flash re-establishes one.
#
# usage: flash-boot-images.sh <fastboot-serial> [receipt-dir]
set -euo pipefail

SERIAL="${1:?fastboot serial}"
ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
OUT="${ROOT}/lineage-17.1/out/target/product/k50sv1_64_bsp"
RECEIPT_DIR="${2:-${ROOT}/work/.capture-staging/flash-receipts}"
EXPECT_PRODUCT="$(cat "${ROOT}/work/k50sv1-bringup/tools/.expected-fastboot-product")"
FASTBOOT="${FASTBOOT:-/home/desmond/Android/Sdk/platform-tools/fastboot}"
ADB="${ADB:-/home/desmond/Android/Sdk/platform-tools/adb}"
export ADB_LIBUSB=1

for img in boot recovery; do
    [[ -s "${OUT}/${img}.img" ]] || { echo "missing ${OUT}/${img}.img" >&2; exit 1; }
done

fb() { "${FASTBOOT}" -s "${SERIAL}" "$@"; }

if "${ADB}" -s "${SERIAL}" get-state >/dev/null 2>&1; then
    "${ADB}" -s "${SERIAL}" reboot bootloader
fi
for _ in $(seq 1 60); do
    fb devices 2>/dev/null | grep -q "^${SERIAL}" && break
    sleep 1
done
product="$(fb getvar product 2>&1 | awk -F': ' '/^product:/{print $2; exit}')"
[[ "${product}" == "${EXPECT_PRODUCT}" ]] || {
    echo "bootloader product '${product}' != '${EXPECT_PRODUCT}', refusing" >&2
    exit 1
}

mkdir -p "${RECEIPT_DIR}"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
receipt="${RECEIPT_DIR}/kernel-only-${stamp}.txt"
{
    echo "flash_kind=kernel-only boot+recovery over unchanged system/vendor"
    echo "flashed_at_utc=${stamp}"
    echo "fastboot_serial=${SERIAL}"
    echo "bootloader_product=${product}"
    for repo in work lineage-17.1/device/xsh/k50sv1_64_bsp lineage-17.1/kernel/xsh/k50sv1_64_bsp; do
        echo "repo.$(basename "${repo}").head=$(git -C "${ROOT}/${repo}" rev-parse HEAD)"
        echo "repo.$(basename "${repo}").dirty=$(git -C "${ROOT}/${repo}" status --porcelain | wc -l)"
    done
    for img in boot recovery; do
        echo "image.${img}.sha256=$(sha256sum "${OUT}/${img}.img" | cut -d' ' -f1)"
        echo "image.${img}.bytes=$(stat -c %s "${OUT}/${img}.img")"
    done
    echo "kernel.image_gz.sha256=$(sha256sum "${OUT}/obj/KERNEL_OBJ/arch/arm64/boot/Image.gz" | cut -d' ' -f1)"
} > "${receipt}"

# Owner policy: every OS flash wipes userdata, metadata and cache.
for part in userdata metadata cache; do
    fb erase "${part}"
    echo "erase.${part}=ok" >> "${receipt}"
done
for img in boot recovery; do
    fb flash "${img}" "${OUT}/${img}.img"
    echo "flash.${img}=ok" >> "${receipt}"
done
fb reboot
echo "status=PASS" >> "${receipt}"
echo "receipt: ${receipt}"

#!/usr/bin/env bash
# Flash the separately authorized MTK logo partition to one exact, verified
# fastboot device. This does not flash the OS and deliberately does not wipe
# userdata/metadata/cache.

set -euo pipefail

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGO_IMAGE="${1:-}"
FB_SERIAL="${2:-${K50SV1_FASTBOOT_SERIAL:-}}"
EXPECTED_PRODUCT="${K50SV1_EXPECT_PRODUCT:-}"
EXPECTED_FILE="${TOOL_DIR}/.expected-fastboot-product"
LOGO_BYTES=8388608

if [[ -z "${LOGO_IMAGE}" || -z "${FB_SERIAL}" ]]; then
    printf 'usage: %s <logo-image> <fastboot-serial>\n' "$0" >&2
    exit 2
fi
if [[ ! -f "${LOGO_IMAGE}" || -L "${LOGO_IMAGE}" || ! -r "${LOGO_IMAGE}" ]]; then
    printf 'missing, unreadable, or symlinked logo image: %s\n' "${LOGO_IMAGE}" >&2
    exit 2
fi
for command in awk fastboot python3 sed seq sha256sum sleep stat; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        printf 'missing host command: %s\n' "${command}" >&2
        exit 2
    fi
done

actual_bytes="$(stat -c %s "${LOGO_IMAGE}")"
if [[ "${actual_bytes}" -ne "${LOGO_BYTES}" ]]; then
    printf 'refusing logo flash: %s is %s bytes; expected exactly %s\n' \
        "${LOGO_IMAGE}" "${actual_bytes}" "${LOGO_BYTES}" >&2
    exit 1
fi
logo_report="$(python3 "${TOOL_DIR}/logo/mtk_logo.py" "${LOGO_IMAGE}")"
if [[ "${logo_report%%$'\n'*}" != blocks=80\ * ]]; then
    printf 'refusing logo flash: unexpected MTK logo layout:\n%s\n' \
        "${logo_report}" >&2
    exit 1
fi
printf 'logo sha256: '
sha256sum "${LOGO_IMAGE}"

if [[ -z "${EXPECTED_PRODUCT}" && -r "${EXPECTED_FILE}" ]]; then
    EXPECTED_PRODUCT="$(<"${EXPECTED_FILE}")"
fi
if [[ -z "${EXPECTED_PRODUCT}" ]]; then
    printf 'refusing logo flash: no expected product; restore %s or set K50SV1_EXPECT_PRODUCT\n' \
        "${EXPECTED_FILE}" >&2
    exit 1
fi

printf 'waiting up to 120 s for fastboot serial %s\n' "${FB_SERIAL}"
found=false
for _ in $(seq 1 120); do
    while IFS= read -r attached; do
        if [[ "${attached}" == "${FB_SERIAL}" ]]; then
            found=true
            break
        fi
    done < <(fastboot devices 2>/dev/null | awk 'NF { print $1 }')
    [[ "${found}" == true ]] && break
    sleep 1
done
if [[ "${found}" != true ]]; then
    printf 'refusing logo flash: fastboot serial %s did not appear\n' \
        "${FB_SERIAL}" >&2
    exit 1
fi

fb() { command fastboot -s "${FB_SERIAL}" "$@"; }
if ! getvar_out="$(fb getvar product 2>&1)"; then
    printf 'refusing logo flash: cannot query product from %s:\n%s\n' \
        "${FB_SERIAL}" "${getvar_out}" >&2
    exit 1
fi
product_lines="$(sed -n 's/^product: *//p' <<<"${getvar_out}")"
product="${product_lines%%$'\n'*}"
if [[ "${product}" != "${EXPECTED_PRODUCT}" ]]; then
    printf 'refusing logo flash: product is %s, expected %s\n' \
        "${product:-<unset>}" "${EXPECTED_PRODUCT}" >&2
    exit 1
fi

printf 'flashing logo on verified %s (%s)\n' "${FB_SERIAL}" "${product}"
fb flash logo "${LOGO_IMAGE}"
printf 'logo written; rebooting verified device\n'
fb reboot

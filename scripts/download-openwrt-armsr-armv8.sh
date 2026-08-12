#!/usr/bin/env bash
# Download official OpenWrt armsr/armv8 QEMU disk image + U-Boot (no image build).
# Usage:
#   RELEASE=24.10.8 ./scripts/download-openwrt-armsr-armv8.sh
#   RELEASE=23.05.5 ./scripts/download-openwrt-armsr-armv8.sh
#
# Outputs under lab/images/ (gitignored):
#   openwrt-armsr-armv8-<RELEASE>.img  — uncompressed ext4 combined EFI image
#   u-boot-qemu_armv8-<RELEASE>.bin    — for qemu -bios (per release)
#
# Legacy symlink (default RELEASE only): openwrt-armsr-armv8.img
set -euo pipefail

RELEASE="${RELEASE:-24.10.8}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/lab/images"
mkdir -p "${OUT}"

# Verify a downloaded artifact against an upstream sha256sums manifest.
# Args: <local_file> <manifest_name> <sha256sums_file> <strict>
#   strict=1: abort if no manifest entry (disk images are always published)
#   strict=0: note + skip if no entry (e.g. u-boot.bin on older armsr releases)
verify_downloaded_sha256() {
	local file="$1" name="$2" manifest="$3" strict="${4:-1}" expected actual
	expected="$(awk -v n="$name" '$2 == "*" n {print $1; exit}' "$manifest")"
	if [[ -z "$expected" ]]; then
		if [[ "$strict" == 1 ]]; then
			rm -f "$file"
			echo "verify: sha256sums has no entry for '${name}' — cannot verify, aborting" >&2
			exit 1
		fi
		echo "verify: no sha256sums entry for '${name}' (upstream has no checksum for this release) — skipping" >&2
		return 0
	fi
	if ! command -v sha256sum >/dev/null 2>&1; then
		echo "verify: 'sha256sum' not available — cannot verify '${name}'" >&2
		rm -f "$file"
		exit 1
	fi
	actual="$(sha256sum "$file" | awk '{print $1}')"
	if [[ "$actual" != "$expected" ]]; then
		rm -f "$file"
		echo "verify: sha256 MISMATCH for '${name}'" >&2
		echo "  expected: ${expected}" >&2
		echo "  actual:   ${actual}" >&2
		exit 1
	fi
	echo "verify: ${name} OK (${expected})" >&2
}

# Optional usign verification of the sha256sums manifest signature.
# Opt-in: FWLIVE_VERIFY_SIGNATURE=1. Non-blocking — if usign or the keys are
# unavailable the sha256 checks above are unaffected.
maybe_verify_sha256sums_signature() {
	[[ "${FWLIVE_VERIFY_SIGNATURE:-0}" == 1 ]] || return 0
	local manifest="$1" base="$2" asc
	if ! command -v usign >/dev/null 2>&1; then
		echo "verify: FWLIVE_VERIFY_SIGNATURE=1 but 'usign' not found — signature check skipped" >&2
		return 0
	fi
	if [[ -z "${FWLIVE_USIGN_KEY:-}" || ! -r "${FWLIVE_USIGN_KEY}" ]]; then
		echo "verify: 'usign' found but FWLIVE_USIGN_KEY not set/readable — signature check skipped" >&2
		return 0
	fi
	asc="$(mktemp -t fwlive-sha256sums.asc.XXXXXX)"
	if ! curl -fsSL -o "$asc" "${base}/sha256sums.asc"; then
		echo "verify: sha256sums.asc not published (or fetch failed) — signature check skipped" >&2
		rm -f "$asc"; return 0
	fi
	if ! usign -V -m "$manifest" -p "$FWLIVE_USIGN_KEY" -x "$asc" >/dev/null 2>&1; then
		echo "verify: usign signature check FAILED for ${base}/sha256sums" >&2
		rm -f "$asc"; exit 1
	fi
	rm -f "$asc"
	echo "verify: sha256sums.asc signature OK" >&2
}

if [[ "$RELEASE" == "snapshot" ]]; then
	BASE="https://downloads.openwrt.org/snapshots/targets/armsr/armv8"
	IMG_OUT="openwrt-armsr-armv8-snapshot.img"
	UBOOT_OUT="u-boot-qemu_armv8-snapshot.bin"
	IMG_VARIANTS=(
		"openwrt-armsr-armv8-generic-ext4-combined-efi.img.gz"
		"openwrt-armsr-armv8-generic-ext4-combined.img.gz"
	)
else
	BASE="https://downloads.openwrt.org/releases/${RELEASE}/targets/armsr/armv8"
	IMG_OUT="openwrt-armsr-armv8-${RELEASE}.img"
	UBOOT_OUT="u-boot-qemu_armv8-${RELEASE}.bin"
	# 24.10+ ships combined-efi; 23.05 uses combined (no -efi suffix).
	IMG_VARIANTS=(
		"openwrt-${RELEASE}-armsr-armv8-generic-ext4-combined-efi.img.gz"
		"openwrt-${RELEASE}-armsr-armv8-generic-ext4-combined.img.gz"
	)
fi
IMG_GZ=""
for candidate in "${IMG_VARIANTS[@]}"; do
	if curl -fsSIL "${BASE}/${candidate}" >/dev/null 2>&1; then
		IMG_GZ="$candidate"
		break
	fi
done
[[ -n "$IMG_GZ" ]] || { echo "no combined disk image found under ${BASE}/" >&2; exit 1; }

SUM_MANIFEST="$(mktemp -t fwlive-armsr-sha256sums.XXXXXX)"
trap 'rm -f "${SUM_MANIFEST}"' EXIT
echo "Fetching sha256sums from ${BASE}/ ..."
curl -fsSL -o "${SUM_MANIFEST}" "${BASE}/sha256sums"
maybe_verify_sha256sums_signature "${SUM_MANIFEST}" "${BASE}"

echo "Fetching ${IMG_GZ} ..."
curl -fsSL -o "${OUT}/${IMG_GZ}" "${BASE}/${IMG_GZ}"
verify_downloaded_sha256 "${OUT}/${IMG_GZ}" "${IMG_GZ}" "${SUM_MANIFEST}" 1
echo "Decompressing ..."
# Some release artifacts have trailing bytes (gzip exit 2); verify output size.
set +e
gzip -dc "${OUT}/${IMG_GZ}" > "${OUT}/${IMG_OUT}"
gz_rc=$?
set -e
rm -f "${OUT}/${IMG_GZ}"
if [[ ! -s "${OUT}/${IMG_OUT}" ]]; then
	echo "decompress failed (gzip exit ${gz_rc})" >&2
	exit 1
fi
if [[ $gz_rc -ne 0 && $gz_rc -ne 2 ]]; then
	echo "decompress failed (gzip exit ${gz_rc})" >&2
	exit 1
fi

echo "Fetching u-boot-qemu_armv8/u-boot.bin ..."
curl -fsSL -o "${OUT}/${UBOOT_OUT}" "${BASE}/u-boot-qemu_armv8/u-boot.bin"
# u-boot.bin: strict=0 — upstream omits the checksum for some releases
# (e.g. 22.03.7); verify when present, otherwise skip with a note.
verify_downloaded_sha256 "${OUT}/${UBOOT_OUT}" "u-boot-qemu_armv8/u-boot.bin" "${SUM_MANIFEST}" 0

if [[ "${RELEASE}" == "24.10.8" ]]; then
	ln -sf "${IMG_OUT}" "${OUT}/openwrt-armsr-armv8.img"
	ln -sf "${UBOOT_OUT}" "${OUT}/u-boot-qemu_armv8.bin"
fi

echo "Done."
echo "  OWRT_IMG=${OUT}/${IMG_OUT}"
echo "  OWRT_UBOOT=${OUT}/${UBOOT_OUT}"
echo "Run: OWRT_IMG=${OUT}/${IMG_OUT} OWRT_UBOOT=${OUT}/${UBOOT_OUT} ${ROOT}/scripts/run-openwrt-armsr-armv8-qemu.sh"

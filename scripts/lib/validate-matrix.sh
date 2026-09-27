#!/usr/bin/env bash
# QEMU + SDK validation helpers for luci-app-fwlive.
# Source from validate-openwrt.sh / validate-openwrt-all.sh — do not execute directly.
set -euo pipefail

VALIDATE_MATRIX_QEMU_TARGETS=(x86 armsr)

validate_matrix_root() {
	local here
	here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
	printf '%s' "$here"
}

# shellcheck source=sdk-matrix.sh
source "$(dirname "${BASH_SOURCE[0]}")/sdk-matrix.sh"
# shellcheck source=qemu-lab-net.sh
source "$(dirname "${BASH_SOURCE[0]}")/qemu-lab-net.sh"

validate_matrix_die() { echo "validate: $*" >&2; exit 1; }

validate_matrix_validate_qemu_target() {
	local t
	for t in "${VALIDATE_MATRIX_QEMU_TARGETS[@]}"; do
		[[ "$1" == "$t" ]] && return 0
	done
	validate_matrix_die "invalid qemu target $1 (choose: ${VALIDATE_MATRIX_QEMU_TARGETS[*]})"
}

# User version key → release patch for downloads (23.05 → 23.05.5; snapshot → empty).
validate_matrix_release_patch() {
	sdk_matrix_version_patch "$1"
}

# Lab image filename slug (snapshot uses literal "snapshot", not empty).
validate_matrix_lab_slug() {
	local patch
	patch="$(validate_matrix_release_patch "$1")"
	if [[ -z "$patch" ]]; then
		printf '%s' 'snapshot'
	else
		printf '%s' "$patch"
	fi
}

validate_matrix_version_label() {
	sdk_matrix_version_label "$1"
}

validate_matrix_image_path() {
	local qemu_target="$1" version_key="$2" root lab_slug
	root="$(validate_matrix_root)"
	lab_slug="$(validate_matrix_lab_slug "$version_key")"
	case "$qemu_target" in
		x86) printf '%s/lab/images/openwrt-x86-64-%s.img' "$root" "$lab_slug" ;;
		armsr) printf '%s/lab/images/openwrt-armsr-armv8-%s.img' "$root" "$lab_slug" ;;
		*) validate_matrix_die "unknown qemu target: $qemu_target" ;;
	esac
}

validate_matrix_download_image() {
	local qemu_target="$1" version_key="$2" root release_arg
	root="$(validate_matrix_root)"
	if [[ -z "$(validate_matrix_release_patch "$version_key")" ]]; then
		release_arg='snapshot'
	else
		release_arg="$(validate_matrix_lab_slug "$version_key")"
	fi
	case "$qemu_target" in
		x86)
			RELEASE="$release_arg" "${root}/scripts/download-openwrt-x86-64.sh"
			;;
		armsr)
			RELEASE="$release_arg" "${root}/scripts/download-openwrt-armsr-armv8.sh"
			;;
	esac
}

validate_matrix_prepare_image() {
	local img="$1"
	sudo OWRT_IMG="$img" "$(validate_matrix_root)/scripts/qemu-lab-prepare-image.sh"
}

validate_matrix_console_log() {
	local qemu_target="$1" root
	root="$(validate_matrix_root)"
	case "$qemu_target" in
		x86) printf '%s' "${OWRT_CONSOLE_LOG:-${root}/lab/qemu-x86-console.log}" ;;
		armsr) printf '%s' "${OWRT_CONSOLE_LOG:-${root}/lab/qemu-console.log}" ;;
		*) validate_matrix_die "unknown qemu target: $qemu_target" ;;
	esac
}

validate_matrix_dump_console() {
	local console="$1"
	if [[ -f "$console" ]]; then
		echo "validate: last 40 lines of ${console}:" >&2
		tail -n 40 "$console" >&2 || true
	else
		echo "validate: no console log at ${console}" >&2
	fi
}

# Liveness + hostfwd SSH listen check before the long qemu-wait-guest poll (#805).
validate_matrix_assert_qemu_up() {
	local qemu_target="$1" pid="$2" port console tries i
	port="${OPENWRT_SSH_PORT:-2222}"
	console="$(validate_matrix_console_log "$qemu_target")"
	qemu_lab_validate_port OPENWRT_SSH_PORT "$port" || return 1
	if ! kill -0 "$pid" 2>/dev/null; then
		echo "validate: QEMU process ${pid} is not running" >&2
		validate_matrix_dump_console "$console"
		return 1
	fi
	tries="${OWRT_VALIDATE_QEMU_PORT_TRIES:-20}"
	qemu_lab_validate_int OWRT_VALIDATE_QEMU_PORT_TRIES "$tries" 1 120 || return 1
	for ((i = 0; i < tries; i++)); do
		if qemu_lab_host_port_listening "$port"; then
			return 0
		fi
		if ! kill -0 "$pid" 2>/dev/null; then
			echo "validate: QEMU process ${pid} died while waiting for port ${port}" >&2
			validate_matrix_dump_console "$console"
			return 1
		fi
		sleep 1
	done
	echo "validate: QEMU pid ${pid} is up but SSH port ${port} is not listening" >&2
	validate_matrix_dump_console "$console"
	return 1
}

validate_matrix_stop_one() {
	local qemu_target="$1" root
	root="$(validate_matrix_root)"
	case "$qemu_target" in
		x86) "${root}/scripts/run-openwrt-x86-qemu.sh" --stop ;;
		armsr) "${root}/scripts/run-openwrt-armsr-armv8-qemu.sh" --stop ;;
		*) validate_matrix_die "unknown qemu target: $qemu_target" ;;
	esac
}

validate_matrix_stop_qemu() {
	local rc=0 ar=0
	validate_matrix_stop_one x86 || rc=$?
	validate_matrix_stop_one armsr || ar=$?
	if [[ "$rc" -ne 0 ]]; then
		return "$rc"
	fi
	return "$ar"
}

validate_matrix_start_qemu() {
	local qemu_target="$1" version_key="$2" root lab_slug child_pid
	root="$(validate_matrix_root)"
	lab_slug="$(validate_matrix_lab_slug "$version_key")"
	validate_matrix_stop_one "$qemu_target"
	# Reset U-Boot/OVMF boot state between matrix runs (avoids hung GRUB paths).
	cp /usr/share/OVMF/OVMF_VARS_4M.fd "${root}/lab/images/OVMF_VARS_4M.fd" 2>/dev/null || true
	case "$qemu_target" in
		x86)
			OWRT_RELEASE="$lab_slug" OWRT_QEMU_SERIAL_SOCKET=1 \
				"${root}/scripts/run-openwrt-x86-qemu.sh" &
			child_pid=$!
			;;
		armsr)
			OWRT_RELEASE="$lab_slug" "${root}/scripts/run-openwrt-armsr-armv8-qemu.sh" &
			child_pid=$!
			;;
		*) validate_matrix_die "unknown qemu target: $qemu_target" ;;
	esac
	# Minimum attach delay, then liveness + port probe (avoids a 300–1800s SSH timeout).
	sleep "${OWRT_VALIDATE_QEMU_BOOT_DELAY:-15}"
	validate_matrix_assert_qemu_up "$qemu_target" "$child_pid"
}

validate_matrix_ssh_max_wait() {
	case "$1" in
		armsr) printf '%s' "${OWRT_VALIDATE_SSH_WAIT_ARMSR:-1800}" ;;
		x86) printf '%s' "${OWRT_VALIDATE_SSH_WAIT_X86:-300}" ;;
		*) printf '%s' '300' ;;
	esac
}

validate_matrix_wait_ssh() {
	local qemu_target="$1" root max_wait
	root="$(validate_matrix_root)"
	max_wait="$(validate_matrix_ssh_max_wait "$qemu_target")"
	MAX_WAIT="$max_wait" "${root}/scripts/qemu-wait-guest.sh"
}

validate_matrix_sdk_build() {
	local sdk_target="$1" version_key="$2" root
	root="$(validate_matrix_root)"
	"${root}/scripts/docker-sdk.sh" build --target "$sdk_target" --version "$version_key"
}

validate_matrix_install_ipk() {
	local version_label="$1" qemu_target="$2" root
	root="$(validate_matrix_root)"
	case "$qemu_target" in
		x86) export OWRT_FWLIVE_ARCH=x86_64 ;;
		armsr) export OWRT_FWLIVE_ARCH=aarch64_generic ;;
	esac
	OWRT_FWLIVE_VERSION="$version_label" "${root}/scripts/qemu-install-fwlive.sh" --artifact-only
}

validate_matrix_smoke() {
	"$(validate_matrix_root)/scripts/qemu-smoke-fwlive.sh" --require-log-pipeline
}

# End-to-end: build (optional) → image → QEMU → install → smoke.
# Args: version_key qemu_target sdk_target skip_build
validate_matrix_run_cell() {
	local version_key="$1" qemu_target="$2" sdk_target="$3" skip_build="${4:-0}"
	local release_patch version_label lab_slug img root
	root="$(validate_matrix_root)"
	release_patch="$(validate_matrix_release_patch "$version_key")"
	lab_slug="$(validate_matrix_lab_slug "$version_key")"
	version_label="$(validate_matrix_version_label "$version_key")"
	img="$(validate_matrix_image_path "$qemu_target" "$version_key")"

	cleanup_on_fail() {
		local rc=$?
		[[ $rc -eq 0 ]] && return 0
		validate_matrix_stop_qemu
		return "$rc"
	}
	trap cleanup_on_fail EXIT

	echo "== validate ${version_key} (lab ${lab_slug}) qemu=${qemu_target} sdk=${sdk_target} ==" >&2

	if [[ "$skip_build" -eq 0 ]]; then
		echo "→ SDK build..." >&2
		validate_matrix_sdk_build "$sdk_target" "$version_key"
	fi

	if [[ ! -f "$img" ]]; then
		echo "→ download lab image..." >&2
		validate_matrix_download_image "$qemu_target" "$version_key"
	fi
	img="$(validate_matrix_image_path "$qemu_target" "$version_key")"
	[[ -f "$img" ]] || validate_matrix_die "missing image after download: $img"

	echo "→ prepare image..." >&2
	validate_matrix_prepare_image "$img"

	echo "→ start QEMU (${qemu_target})..." >&2
	validate_matrix_start_qemu "$qemu_target" "$version_key"

	echo "→ wait for SSH..." >&2
	validate_matrix_wait_ssh "$qemu_target"

	echo "→ install fwlive..." >&2
	validate_matrix_install_ipk "$version_label" "$qemu_target"

	echo "→ smoke..." >&2
	validate_matrix_smoke

	validate_matrix_stop_qemu
	trap - EXIT
	echo "== validate passed: ${version_key} / ${qemu_target} ==" >&2
}

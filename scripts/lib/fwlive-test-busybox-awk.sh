# Assert awk resolved inside the lane's pinned `busybox sh` is BusyBox >= 1.37.
fwlive_test_assert_busybox_awk_lane() {
	local bin="$1" banner major minor
	banner="$(PATH="${bin}:${PATH}" busybox sh -c 'awk 2>&1 | head -1' 2>/dev/null || true)"
	if [[ ! "$banner" =~ BusyBox\ v([0-9]+)\.([0-9]+) ]]; then
		echo "FAIL: BusyBox awk lane: awk inside 'busybox sh' did not report a BusyBox version (got: ${banner})" >&2
		return 1
	fi
	major="${BASH_REMATCH[1]}"
	minor="${BASH_REMATCH[2]}"
	if (( major > 1 || (major == 1 && minor >= 37) )); then
		return 0
	fi
	echo "FAIL: BusyBox awk lane: awk inside 'busybox sh' reports ${major}.${minor}, need >= 1.37 (use the prepared busybox on PATH, not the host applet)" >&2
	return 1
}

# Prepare the pinned BusyBox awk lane. The caller runs the tests after success.
# Return 0 when ready, 2 for an explicitly counted local skip, and 1 on failure.
fwlive_test_prepare_busybox_awk() {
	local root="$1" system arch strict=0
	FWLIVE_BUSYBOX_AWK_BIN=""
	system="$(uname -s)"
	arch="$(uname -m)"
	if [[ "${CI:-}" == "true" || "${FWLIVE_TEST_REQUIRE_ZERO_SKIPS:-}" == "1" ]]; then
		strict=1
	fi

	if [[ "$system" != "Linux" || "$arch" != "x86_64" ]]; then
		if [[ "$strict" -eq 1 ]]; then
			echo "FAIL: BusyBox awk >= 1.37 is required in CI, but this host is ${system}/${arch}." >&2
			return 1
		fi
		fwlive_runner_gate_skips=$((fwlive_runner_gate_skips + 1))
		echo "SKIP: BusyBox awk >= 1.37 lane requires Linux x86_64 (found ${system}/${arch}); counted." >&2
		return 2
	fi

	if FWLIVE_BUSYBOX_AWK_BIN="$("${root}/scripts/ensure-busybox-awk.sh")"; then
		return 0
	fi

	if [[ "$strict" -eq 0 && "${FWLIVE_ALLOW_SKIP:-}" == "1" ]]; then
		fwlive_runner_gate_skips=$((fwlive_runner_gate_skips + 1))
		echo "SKIP: BusyBox awk >= 1.37 lane could not be prepared; FWLIVE_ALLOW_SKIP=1. Counted." >&2
		return 2
	fi

	echo "FAIL: Could not prepare the pinned BusyBox awk >= 1.37 lane. Check network access and host prerequisites; local runs may set FWLIVE_ALLOW_SKIP=1 to skip." >&2
	return 1
}

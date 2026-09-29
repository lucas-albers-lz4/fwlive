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
		fwlive_skipped_gates=$((fwlive_skipped_gates + 1))
		echo "SKIP: BusyBox awk >= 1.37 lane requires Linux x86_64 (found ${system}/${arch}); counted." >&2
		return 2
	fi

	if FWLIVE_BUSYBOX_AWK_BIN="$("${root}/scripts/ensure-busybox-awk.sh")"; then
		return 0
	fi

	if [[ "$strict" -eq 0 && "${FWLIVE_ALLOW_SKIP:-}" == "1" ]]; then
		fwlive_skipped_gates=$((fwlive_skipped_gates + 1))
		echo "SKIP: BusyBox awk >= 1.37 lane could not be prepared; FWLIVE_ALLOW_SKIP=1. Counted." >&2
		return 2
	fi

	echo "FAIL: Could not prepare the pinned BusyBox awk >= 1.37 lane. Check network access and host prerequisites; local runs may set FWLIVE_ALLOW_SKIP=1 to skip." >&2
	return 1
}

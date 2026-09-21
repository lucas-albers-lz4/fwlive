#!/bin/sh
# Parse and enforce src-git commit pins in scripts/feeds.lock/*.
# POSIX: sourced from bash tests and from dash inside the SDK image.
# Do not execute directly.

feeds_lock_require_pins() {
	_lock="${1:-}"
	_line=''
	[ -n "$_lock" ] && [ -f "$_lock" ] || {
		echo "feeds-lock: missing lockfile: ${_lock:-<empty>}" >&2
		return 1
	}
	while IFS= read -r _line || [ -n "$_line" ]; do
		case "$_line" in
		'' | '#'*)
			continue
			;;
		src-link*)
			continue
			;;
		src-git*)
			printf '%s\n' "$_line" | grep -Eq '^src-git( --root=[^[:space:]]+)? [^[:space:]]+ [^[:space:]]+\^[0-9a-f]{40}$' || {
				echo "feeds-lock: unpinned src-git: $_line" >&2
				return 1
			}
			;;
		*)
			echo "feeds-lock: unexpected lock line: $_line" >&2
			return 1
			;;
		esac
	done <"$_lock"
}

# Print "name sha" for each src-git pin. Requires a passing require_pins first.
feeds_lock_each_pin() {
	_lock="${1:-}"
	_line=''
	_rest=''
	_name=''
	_urlsha=''
	_sha=''
	while IFS= read -r _line || [ -n "$_line" ]; do
		case "$_line" in
		src-git*)
			_rest="${_line#src-git }"
			case "$_rest" in
			--root=*)
				_rest="${_rest#* }"
				;;
			esac
			_name="${_rest%% *}"
			_urlsha="${_rest#* }"
			_sha="${_urlsha##*^}"
			printf '%s %s\n' "$_name" "$_sha"
			;;
		esac
	done <"$_lock"
}

feeds_lock_git_dir() {
	_feeds="${1:-}"
	_name="${2:-}"
	if [ -d "$_feeds/$_name/.git" ]; then
		printf '%s\n' "$_feeds/$_name"
		return 0
	fi
	if [ -d "$_feeds/${_name}_root/.git" ]; then
		printf '%s\n' "$_feeds/${_name}_root"
		return 0
	fi
	echo "feeds-lock: no git dir for feed $_name under $_feeds" >&2
	return 1
}

# Exit 0 when each named feed (or every pin if no names) matches HEAD and is clean.
# Extra unused lock pins (routing, telephony, video) are ignored unless named.
feeds_lock_assert_heads() {
	_lock="${1:-}"
	_feeds="${2:-}"
	shift 2 || true
	_want="$*"
	_pair=''
	_name=''
	_sha=''
	_repo=''
	_head=''
	_status=''
	_needed=''
	feeds_lock_require_pins "$_lock" || return 1
	[ -n "$_feeds" ] && [ -d "$_feeds" ] || {
		echo "feeds-lock: missing feeds dir: ${_feeds:-<empty>}" >&2
		return 1
	}
	while IFS= read -r _pair || [ -n "$_pair" ]; do
		[ -n "$_pair" ] || continue
		_name="${_pair%% *}"
		_sha="${_pair#* }"
		if [ -n "$_want" ]; then
			_needed=0
			for _need in $_want; do
				if [ "$_need" = "$_name" ]; then
					_needed=1
					break
				fi
			done
			[ "$_needed" -eq 1 ] || continue
		fi
		_repo="$(feeds_lock_git_dir "$_feeds" "$_name")" || return 1
		_head="$(git -C "$_repo" rev-parse HEAD)" || return 1
		if [ "$_head" != "$_sha" ]; then
			echo "feeds-lock: $_name HEAD $_head != pin $_sha" >&2
			return 1
		fi
		_status="$(git -C "$_repo" status --porcelain)" || return 1
		if [ -n "$_status" ]; then
			echo "feeds-lock: $_name work tree is not clean" >&2
			return 1
		fi
	done <<EOF
$(feeds_lock_each_pin "$_lock")
EOF
}

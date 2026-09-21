#!/bin/sh
# Parse and enforce src-git commit pins in scripts/feeds.lock/*.
# POSIX: sourced from bash tests and from dash inside the SDK image.
# Do not execute directly.

feeds_lock_require_pins() {
	_lock="${1:-}"
	_line=''
	_rest=''
	_name=''
	_have_base=0
	_have_packages=0
	_have_luci=0
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
			_rest="${_line#src-git }"
			case "$_rest" in
			--root=*)
				_rest="${_rest#* }"
				;;
			esac
			_name="${_rest%% *}"
			case "$_name" in
			base) _have_base=1 ;;
			packages) _have_packages=1 ;;
			luci) _have_luci=1 ;;
			esac
			;;
		*)
			echo "feeds-lock: unexpected lock line: $_line" >&2
			return 1
			;;
		esac
	done <"$_lock"
	[ "$_have_base" -eq 1 ] && [ "$_have_packages" -eq 1 ] && [ "$_have_luci" -eq 1 ] || {
		echo "feeds-lock: lock must pin base, packages, and luci" >&2
		return 1
	}
}

# Print "name sha" or "name sha rootpath" for each src-git pin.
# Requires a passing require_pins first.
feeds_lock_each_pin() {
	_lock="${1:-}"
	_line=''
	_rest=''
	_root=''
	_name=''
	_urlsha=''
	_sha=''
	while IFS= read -r _line || [ -n "$_line" ]; do
		case "$_line" in
		src-git*)
			_rest="${_line#src-git }"
			_root=''
			case "$_rest" in
			--root=*)
				_root="${_rest%% *}"
				_root="${_root#--root=}"
				_rest="${_rest#* }"
				;;
			esac
			_name="${_rest%% *}"
			_urlsha="${_rest#* }"
			_sha="${_urlsha##*^}"
			if [ -n "$_root" ]; then
				printf '%s %s %s\n' "$_name" "$_sha" "$_root"
			else
				printf '%s %s\n' "$_name" "$_sha"
			fi
			;;
		esac
	done <"$_lock"
}

feeds_lock_has_git() {
	git -C "${1:-}" rev-parse --git-dir >/dev/null 2>&1
}

# --root=package → clone at <name>_root, symlink <name> -> <name>_root/<root>.
feeds_lock_root_link_ok() {
	_feeds="${1:-}"
	_name="${2:-}"
	_root="${3:-}"
	_link="$_feeds/$_name"
	_want="${_name}_root/${_root}"
	_got=''
	[ -L "$_link" ] || {
		echo "feeds-lock: $_name must be a symlink to $_want" >&2
		return 1
	}
	_got="$(readlink "$_link")" || return 1
	_got="${_got%/}"
	_got="${_got#./}"
	case "$_got" in
	"$_want" | "$_feeds/$_want")
		return 0
		;;
	esac
	echo "feeds-lock: $_name symlink '$_got' is not $_want" >&2
	return 1
}

feeds_lock_git_dir() {
	_feeds="${1:-}"
	_name="${2:-}"
	_root="${3:-}"
	_repo=''
	if [ -n "$_root" ]; then
		_repo="$_feeds/${_name}_root"
		feeds_lock_has_git "$_repo" || {
			echo "feeds-lock: no git dir for feed ${_name}_root under $_feeds" >&2
			return 1
		}
		feeds_lock_root_link_ok "$_feeds" "$_name" "$_root" || return 1
		printf '%s\n' "$_repo"
		return 0
	fi
	_repo="$_feeds/$_name"
	feeds_lock_has_git "$_repo" || {
		echo "feeds-lock: no git dir for feed $_name under $_feeds" >&2
		return 1
	}
	printf '%s\n' "$_repo"
}

feeds_lock_drop_name() {
	_haystack="${1:-}"
	_needle="${2:-}"
	_out=''
	_word=''
	for _word in $_haystack; do
		[ "$_word" = "$_needle" ] || _out="${_out} ${_word}"
	done
	printf '%s' "${_out# }"
}

# Exit 0 when each named feed (or every pin if no names) matches HEAD and is clean.
# Extra unused lock pins (routing, telephony, video) are ignored unless named.
# Requested names missing from the lock fail closed.
feeds_lock_assert_heads() {
	_lock="${1:-}"
	_feeds="${2:-}"
	shift 2 || true
	_want="$*"
	_missing="$_want"
	_pair=''
	_name=''
	_rest=''
	_sha=''
	_root=''
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
		_rest="${_pair#* }"
		_sha="${_rest%% *}"
		_root=''
		case "$_rest" in
		*" "*)
			_root="${_rest#* }"
			;;
		esac
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
		_missing="$(feeds_lock_drop_name "$_missing" "$_name")"
		_repo="$(feeds_lock_git_dir "$_feeds" "$_name" "$_root")" || return 1
		_head="$(git -C "$_repo" rev-parse HEAD)" || return 1
		if [ "$_head" != "$_sha" ]; then
			echo "feeds-lock: $_name HEAD $_head != pin $_sha" >&2
			return 1
		fi
		# `git status --porcelain` hides tracked edits when an index entry has
		# skip-worktree or assume-unchanged set. A cache with either flag is not
		# trustworthy, even when the visible work tree looks clean.
		if git -C "$_repo" ls-files -v | grep -Eq '^(S|[a-z]) '; then
			echo "feeds-lock: $_name has hidden tracked-file index flags" >&2
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
	if [ -n "$_want" ] && [ -n "$_missing" ]; then
		echo "feeds-lock: requested feed(s) not in lock: $_missing" >&2
		return 1
	fi
}

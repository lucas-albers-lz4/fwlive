#!/usr/bin/env bash
# Semantic gate: every src-git lock entry must be a 40-hex commit pin (#411).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/feeds-lock.sh
source "${ROOT}/scripts/lib/feeds-lock.sh"

ok() { echo "ok: $*"; }
fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }

LOCKDIR="${ROOT}/scripts/feeds.lock"
for lock in "$LOCKDIR"/*/feeds.conf; do
	if feeds_lock_require_pins "$lock"; then
		ok "pinned $(basename "$(dirname "$lock")")"
	else
		bad "unpinned src-git in $lock"
	fi
done

base23="$(feeds_lock_each_pin "$LOCKDIR/23.05.5/feeds.conf" | awk '$1=="base"{print $2}')"
if [[ "$base23" == "28cf53e6bd9bb68958aae7958e7950d967f02b46" ]]; then
	ok "23.05.5 base is peeled v23.05.5"
else
	bad "23.05.5 base pin is '$base23'"
fi

if grep -RIn --include='feeds.conf' -E 'src-git .*openwrt\.git;openwrt-' "$LOCKDIR"; then
	bad "mutable OpenWrt branch still present in feeds.lock"
else
	ok "no mutable openwrt-NN.NN branch refs"
fi

neg="$(mktemp -d)"
trap 'rm -rf "$neg"' EXIT
cp "$LOCKDIR/23.05.5/feeds.conf" "$neg/feeds.conf"
sed -i 's/\^28cf53e6bd9bb68958aae7958e7950d967f02b46/;openwrt-23.05/' "$neg/feeds.conf"
if feeds_lock_require_pins "$neg/feeds.conf" 2>/dev/null; then
	bad "branch ref must fail require_pins"
else
	ok "branch ref fails require_pins"
fi

: >"$neg/empty.conf"
if feeds_lock_require_pins "$neg/empty.conf" 2>/dev/null; then
	bad "empty lock must fail require_pins"
else
	ok "empty lock fails require_pins"
fi

grep -v '^src-git luci ' "$LOCKDIR/23.05.5/feeds.conf" >"$neg/noluci.conf"
if feeds_lock_require_pins "$neg/noluci.conf" 2>/dev/null; then
	bad "lock missing luci must fail require_pins"
else
	ok "lock missing luci fails require_pins"
fi

cp "$LOCKDIR/25.12.5/feeds.conf" "$neg/traverse.conf"
sed -i 's|--root=package|--root=../../outside|' "$neg/traverse.conf"
if feeds_lock_require_pins "$neg/traverse.conf" 2>/dev/null; then
	bad "traversal --root must fail require_pins"
else
	ok "traversal --root fails require_pins"
fi

cp "$LOCKDIR/25.12.5/feeds.conf" "$neg/absroot.conf"
sed -i 's|--root=package|--root=/tmp/evil|' "$neg/absroot.conf"
if feeds_lock_require_pins "$neg/absroot.conf" 2>/dev/null; then
	bad "absolute --root must fail require_pins"
else
	ok "absolute --root fails require_pins"
fi

git_init() {
	local dir="$1" sha_msg="$2"
	mkdir -p "$dir"
	git -C "$dir" init -q
	git -C "$dir" config user.email test@example.com
	git -C "$dir" config user.name test
	git -C "$dir" config commit.gpgsign false
	printf '%s\n' "$sha_msg" >"$dir/README"
	git -C "$dir" add README
	git -C "$dir" commit -q -m "$sha_msg"
}

feeds="$neg/feeds"
mkdir -p "$feeds"
# A lock with one pin; clone at that commit by copying after commit and resetting.
git_init "$feeds/packages" packages-ok
pkg_sha="$(git -C "$feeds/packages" rev-parse HEAD)"
git_init "$feeds/luci" luci-ok
luci_sha="$(git -C "$feeds/luci" rev-parse HEAD)"
git_init "$feeds/base" base-ok
base_sha="$(git -C "$feeds/base" rev-parse HEAD)"

cat >"$neg/one.conf" <<EOF
src-git base https://github.com/openwrt/openwrt.git^${base_sha}
src-git packages https://github.com/openwrt/packages.git^${pkg_sha}
src-git luci https://github.com/openwrt/luci.git^${luci_sha}
src-link fwlive /work/fwlive/openwrt-feed
EOF

if feeds_lock_assert_heads "$neg/one.conf" "$feeds" base packages luci; then
	ok "matching HEADs pass"
else
	bad "matching HEADs must pass"
fi

# Cache-hit mismatch: base HEAD differs from the pin.
git -C "$feeds/base" commit -q --allow-empty -m drift
if feeds_lock_assert_heads "$neg/one.conf" "$feeds" base packages luci 2>/dev/null; then
	bad "mismatched feed HEAD must fail"
else
	ok "mismatched feed HEAD fails closed"
fi
git -C "$feeds/base" reset -q --hard "$base_sha"

# Dirty tracked file.
printf dirty >>"$feeds/base/README"
if feeds_lock_assert_heads "$neg/one.conf" "$feeds" base packages luci 2>/dev/null; then
	bad "dirty work tree must fail"
else
	ok "dirty work tree fails closed"
fi
git -C "$feeds/base" checkout -q -- README

# Hidden index flags can suppress both porcelain and diff output; fail closed.
printf hidden >>"$feeds/base/README"
git -C "$feeds/base" update-index --skip-worktree README
if feeds_lock_assert_heads "$neg/one.conf" "$feeds" base packages luci 2>/dev/null; then
	bad "skip-worktree tracked edit must fail"
else
	ok "skip-worktree tracked edit fails closed"
fi
git -C "$feeds/base" update-index --no-skip-worktree README
git -C "$feeds/base" checkout -q -- README

printf hidden >>"$feeds/base/README"
git -C "$feeds/base" update-index --assume-unchanged README
if feeds_lock_assert_heads "$neg/one.conf" "$feeds" base packages luci 2>/dev/null; then
	bad "assume-unchanged tracked edit must fail"
else
	ok "assume-unchanged tracked edit fails closed"
fi
git -C "$feeds/base" update-index --no-assume-unchanged README
git -C "$feeds/base" checkout -q -- README

if feeds_lock_assert_heads "$neg/one.conf" "$feeds" base packages luci routing 2>/dev/null; then
	bad "requested feed missing from lock must fail"
else
	ok "requested feed missing from lock fails closed"
fi

# gitfile (.git is a file) must still resolve HEAD.
mv "$feeds/packages/.git" "$neg/packages.git"
printf 'gitdir: %s\n' "$neg/packages.git" >"$feeds/packages/.git"
if feeds_lock_assert_heads "$neg/one.conf" "$feeds" base packages luci; then
	ok "gitfile checkout matches pin"
else
	bad "gitfile checkout must match pin"
fi
rm -f "$feeds/packages/.git"
mv "$neg/packages.git" "$feeds/packages/.git"

# --root=package layout (25.12/snapshot): git lives in base_root.
rm -rf "$feeds/base" "$feeds/base_root"
git_init "$feeds/base_root" base-root-ok
base_root_sha="$(git -C "$feeds/base_root" rev-parse HEAD)"
mkdir -p "$feeds/base_root/package"
ln -s base_root/package "$feeds/base"
cat >"$neg/root.conf" <<EOF
src-git --root=package base https://github.com/openwrt/openwrt.git^${base_root_sha}
src-git packages https://github.com/openwrt/packages.git^${pkg_sha}
src-git luci https://github.com/openwrt/luci.git^${luci_sha}
src-git routing https://github.com/openwrt/routing.git^aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
src-link fwlive /work/fwlive/openwrt-feed
EOF
if feeds_lock_assert_heads "$neg/root.conf" "$feeds" base packages luci; then
	ok "base_root layout matches pin; unused routing pin ignored"
else
	bad "base_root layout must match pin"
fi

root_fields="$(feeds_lock_each_pin "$neg/root.conf" | awk '$1=="base"{print $2, $3}')"
if [[ "$root_fields" == "$base_root_sha package" ]]; then
	ok "each_pin keeps --root=package on base"
else
	bad "each_pin --root fields are '$root_fields'"
fi

# --root=package: a plain directory at feeds/base must not ride on a clean base_root.
rm -f "$feeds/base"
mkdir -p "$feeds/base"
printf 'evil\n' >"$feeds/base/Makefile"
if feeds_lock_assert_heads "$neg/root.conf" "$feeds" base packages luci 2>/dev/null; then
	bad "replaced --root base symlink must fail"
else
	ok "replaced --root base symlink fails closed"
fi

if [[ "$fail" -ne 0 ]]; then
	exit 1
fi
echo "feeds-lock pin tests passed"

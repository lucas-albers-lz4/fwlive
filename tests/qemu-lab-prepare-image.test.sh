#!/usr/bin/env bash
# Ownership contracts with PATH fixtures only; never attach an actual image.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "image ownership FAIL: $*" >&2; exit 1; }
mkdir -p "$WORK/bin" "$WORK/tmp"
printf image > "$WORK/image"
cat > "$WORK/bin/stub" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
name="${0##*/}"
printf '%s %s\n' "$name" "$*" >> "$IMAGE_CALLS"
case "$name" in
 id) echo 0 ;;
 losetup)
  if [[ "$1" == -d ]]; then exit 0; fi
  [[ "${IMAGE_CASE:-}" != allocation ]] || exit 1
  printf '/dev/fwlive-fake-%s\n' "$IMAGE_ID" ;;
 mktemp)
  [[ "${IMAGE_CASE:-}" != private-dir ]] || exit 1
  exec /usr/bin/mktemp "$@" ;;
 mount)
  [[ "${IMAGE_CASE:-}" != mount-fail ]] || exit 32
  mnt="${@: -1}"
  mkdir -p "$mnt/etc/config" "$mnt/etc/init.d" "$mnt/etc/rc.d"
  cat > "$mnt/etc/config/network" <<'CFG'
config interface 'lan'
 option proto 'dhcp'
CFG
  printf '%s' "$mnt" > "$IMAGE_POINT"
  if [[ "${IMAGE_CASE:-}" == concurrent ]]; then
   touch "$IMAGE_READY/$IMAGE_ID"
   for ((i=0;i<100;i++)); do
    [[ -e "$IMAGE_READY/a" && -e "$IMAGE_READY/b" ]] && exit 0
    sleep .02
   done
   exit 90
  fi ;;
 findmnt)
  [[ "${IMAGE_CASE:-}" != source-unreadable ]] || exit 1
  if [[ "${IMAGE_CASE:-}" == foreign-source ]]; then echo /dev/foreign; else printf '/dev/fwlive-fake-%sp2\n' "$IMAGE_ID"; fi ;;
 umount)
  [[ "${IMAGE_CASE:-}" != unmount-fail ]] || exit 32
  # Empty the simulated mounted tree, then production rmdir may remove its point.
  /bin/rm -rf "${1:?}/etc" ;;
 *) exit 99 ;;
esac
STUB
chmod +x "$WORK/bin/stub"
for tool in id losetup mktemp mount findmnt umount; do ln -s stub "$WORK/bin/$tool"; done
run_case() {
 local kind="$1" want="$2" id="${3:-$1}" status=0
 IMAGE_CASE="$kind" IMAGE_ID="$id" IMAGE_CALLS="$WORK/$id.calls" IMAGE_POINT="$WORK/$id.point" \
 IMAGE_READY="$WORK/ready" OWRT_IMG="$WORK/image" TMPDIR="$WORK/tmp" PATH="$WORK/bin:$PATH" \
 bash "$ROOT/scripts/qemu-lab-prepare-image.sh" > "$WORK/$id.out" 2>&1 || status=$?
 if [[ "$want" == success ]]; then [[ "$status" == 0 ]] || fail "$kind expected success ($status)";
 else [[ "$status" != 0 ]] || fail "$kind expected failure"; fi
}
for kind in private-dir allocation mount-fail; do
 run_case "$kind" failure
 ! grep -q '^umount ' "$WORK/$kind.calls" || fail "$kind must not unmount"
 if [[ "$kind" == mount-fail ]]; then
  grep -q '^losetup -d /dev/fwlive-fake-mount-fail$' "$WORK/$kind.calls" || fail 'detach acquired loop after failed mount'
 else
  ! grep -q '^losetup -d ' "$WORK/$kind.calls" || fail "$kind must not detach unacquired loop"
 fi
done
run_case normal success
grep -q '^umount ' "$WORK/normal.calls" || fail 'unmount owned source'
grep -q '^losetup -d /dev/fwlive-fake-normal$' "$WORK/normal.calls" || fail 'detach owned loop'
[[ ! -e "$(cat "$WORK/normal.point")" ]] || fail 'remove empty private mountpoint'
for kind in foreign-source source-unreadable unmount-fail; do
 run_case "$kind" success
 ! grep -q '^losetup -d ' "$WORK/$kind.calls" || fail "$kind must retain loop"
 [[ -d "$(cat "$WORK/$kind.point")" ]] || fail "$kind retain private mountpoint"
 if [[ "$kind" != unmount-fail ]]; then
  ! grep -q '^umount ' "$WORK/$kind.calls" || fail "$kind must not unmount foreign/unverified mount"
 fi
done
mkdir "$WORK/ready"
run_case concurrent success a & first=$!
run_case concurrent success b & second=$!
wait "$first"; wait "$second"
[[ "$(cat "$WORK/a.point")" != "$(cat "$WORK/b.point")" ]] || fail 'concurrent mountpoints must differ'
for id in a b; do
 grep -Fqx "umount $(cat "$WORK/$id.point")" "$WORK/$id.calls" || fail 'unmount only own private point'
 grep -q "^losetup -d /dev/fwlive-fake-$id$" "$WORK/$id.calls" || fail 'detach only own loop'
done
! grep -q '/mnt/owrt-lab' "$WORK/"*.calls || fail 'fixed foreign mountpoint must never be touched'
echo 'lab image ownership host fixtures passed (no real mounts)'

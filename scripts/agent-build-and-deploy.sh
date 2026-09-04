#!/usr/bin/env bash
# Deploy luci-app-fwlive .ipk to a running OpenWrt guest.
#
# Linux x86_64 + run-openwrt-armsr-armv8-qemu.sh: --legacy-hostfwd (127.0.0.1:2222, LuCI :8080).
# Legacy macOS vmnet: archive/scripts/legacy/ (unmaintained).
# Usage:
#   export QEMU_MAC_LAN=52:54:00:44:55:66
#   ./scripts/agent-build-and-deploy.sh --ipk out/luci-app-fwlive_*.ipk
#
#   OPENWRT_HOST=192.168.1.1 ./scripts/agent-build-and-deploy.sh --ipk path/to.ipk
#
#   ./scripts/agent-build-and-deploy.sh --legacy-hostfwd --lab-only --ipk out/luci-app-fwlive_*.ipk
#
# Host-key verification is ON by default. QEMU/ephemeral guests need an explicit
# opt-in: ALLOW_INSECURE_SSH=1 or --lab-only (prints a warning).
set -euo pipefail

LEASES_FILE="${DHCPD_LEASES:-/var/db/dhcpd_leases}"

OPENWRT_SSH_PORT="${OPENWRT_SSH_PORT:-22}"
OPENWRT_USER="${OPENWRT_USER:-root}"
OPENWRT_HOST="${OPENWRT_HOST:-}"
LEGACY_HOSTFWD=0
LAB_ONLY=0
IPK_PATH=""
SKIP_CURL=0
# Default: normal host-key verification. Opt in to lab insecure SSH via
# ALLOW_INSECURE_SSH=1 or --lab-only (see apply_ssh_opts).
SSH_OPTS=()

apply_legacy_defaults() {
	if [[ "$LEGACY_HOSTFWD" -ne 1 ]]; then
		return
	fi
	OPENWRT_HOST="${OPENWRT_HOST:-127.0.0.1}"
	OPENWRT_SSH_PORT="${OPENWRT_SSH_LEGACY_PORT:-2222}"
}

apply_ssh_opts() {
	local insecure=0
	if [[ "${ALLOW_INSECURE_SSH:-0}" == "1" || "$LAB_ONLY" -eq 1 ]]; then
		insecure=1
	fi
	if [[ "$insecure" -eq 1 ]]; then
		SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
		echo "warn: insecure SSH enabled (StrictHostKeyChecking=no) — lab/QEMU only; MITM can swap the uploaded .ipk" >&2
	else
		SSH_OPTS=()
	fi
}

die() { echo "error: $*" >&2; exit 1; }

usage() {
	sed -n '1,25p' "$0" | tail -n +2
	exit "${1:-0}"
}

discover_ip_from_leases() {
	local want_mac="$1"
	local file="$2"
	[[ -f "$file" ]] || die "leases file not found: $file"

	python3 - "$file" "$want_mac" <<'PY'
import re, sys

def norm_mac(s: str) -> str:
    s = s.strip()
    if "," in s:
        s = s.split(",", 1)[1]
    parts = [int(x, 16) for x in s.split(":") if x]
    return ":".join(f"{b:02x}" for b in parts)

path, want = sys.argv[1], norm_mac(sys.argv[2])
text = open(path, encoding="utf-8", errors="replace").read()
# Split rough "lease { ... }" style blocks (macOS dhcpd_leases)
blocks = re.split(r"\n(?=\{)", text)
best_ip = None
for b in blocks:
    m_ip = re.search(r"ip_address\s*=\s*([0-9.]+)", b)
    m_hw = re.search(r"hw_address\s*=\s*([^\s}]+)", b)
    if not m_ip or not m_hw:
        continue
    try:
        if norm_mac(m_hw.group(1)) == want:
            best_ip = m_ip.group(1)
            break
    except Exception:
        continue
if best_ip:
    print(best_ip)
else:
    sys.exit(1)
PY
}

resolve_host() {
	if [[ -n "$OPENWRT_HOST" ]]; then
		echo "$OPENWRT_HOST"
		return
	fi
	local mac="${QEMU_MAC_LAN:-}"
	[[ -z "$mac" ]] && mac="${QEMU_MAC_WAN:-}"
	[[ -z "$mac" ]] && die "Set OPENWRT_HOST or QEMU_MAC_LAN / QEMU_MAC_WAN (or pass discovery env after reading $LEASES_FILE)"
	local ip
	ip="$(discover_ip_from_leases "$mac" "$LEASES_FILE")" || die "No lease in $LEASES_FILE for MAC $mac (see QEMU_MAC_* / OPENWRT_HOST)"
	echo "$ip"
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		-h|--help) usage 0 ;;
		--legacy-hostfwd) LEGACY_HOSTFWD=1 ;;
		--lab-only) LAB_ONLY=1 ;;
		--ipk) shift; [[ $# -gt 0 ]] || die "--ipk needs a path"; IPK_PATH="$1" ;;
		--skip-curl) SKIP_CURL=1 ;;
		*) die "unknown arg: $1 (try --help)" ;;
	esac
	shift
done

[[ -n "$IPK_PATH" ]] || die "required: --ipk path/to/luci-app-fwlive_*.ipk"
[[ -f "$IPK_PATH" ]] || die "ipk not found: $IPK_PATH"

apply_legacy_defaults
apply_ssh_opts

HOST="$(resolve_host)"
REMOTE_IPK="/tmp/luci-app-fwlive.ipk"

echo "Target: ${OPENWRT_USER}@${HOST} (ssh port ${OPENWRT_SSH_PORT})"
echo "Installing: ${IPK_PATH}"

if [[ "$LEGACY_HOSTFWD" -eq 1 ]]; then
	echo "Legacy mode: assuming QEMU hostfwd tcp::${OPENWRT_SSH_PORT}-:22 and LuCI on host port 8080→guest 80."
fi

if scp -O -P "${OPENWRT_SSH_PORT}" "${SSH_OPTS[@]}" "$IPK_PATH" \
	"${OPENWRT_USER}@${HOST}:${REMOTE_IPK}" 2>/dev/null; then
	:
else
	ssh -p "${OPENWRT_SSH_PORT}" "${SSH_OPTS[@]}" "${OPENWRT_USER}@${HOST}" \
		"cat > ${REMOTE_IPK}" < "$IPK_PATH"
fi
ssh -p "${OPENWRT_SSH_PORT}" "${SSH_OPTS[@]}" "${OPENWRT_USER}@${HOST}" \
	"opkg install ${REMOTE_IPK}"

if [[ "$SKIP_CURL" -eq 0 ]]; then
	if [[ "$LEGACY_HOSTFWD" -eq 1 ]]; then
		echo "Smoke test: curl -fsSIL http://127.0.0.1:8080/ ..."
		curl -fsSIL --connect-timeout 5 "http://127.0.0.1:8080/" || echo "warn: curl failed (guest may still be fine)."
	else
		echo "Smoke test: curl http://${HOST}/ ..."
		if curl -fsSIL --connect-timeout 5 "http://${HOST}/" >/dev/null 2>&1; then
			:
		elif curl -fsSIL --connect-timeout 5 -k "https://${HOST}/" >/dev/null 2>&1; then
			:
		else
			echo "warn: curl failed (check LuCI on 80/443 and firewall)."
		fi
	fi
fi

echo "Done. Open LuCI → Status → Firewall Live View. If the table is empty, add nft/fw4 rules with log for the traffic you test."

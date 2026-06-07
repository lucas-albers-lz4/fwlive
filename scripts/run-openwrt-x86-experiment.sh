#!/usr/bin/env bash
# x86_64 OpenWrt access experiment (official ghcr.io/openwrt/rootfs:x86-64 in Docker).
# Fastest path to LuCI in a desktop browser while debugging network/hostfwd issues.
#
# Usage:
#   ./scripts/run-openwrt-x86-experiment.sh          # start or reuse container + bootstrap
#   ./scripts/run-openwrt-x86-experiment.sh --fresh  # remove container and start clean
#   ./scripts/run-openwrt-x86-experiment.sh --stop   # docker rm -f owrt-x64-exp
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTAINER="${OWRT_CONTAINER:-owrt-x64-exp}"
FRESH=0
STOP=0

for arg in "$@"; do
	case "$arg" in
		--fresh) FRESH=1 ;;
		--stop) STOP=1 ;;
		-h|--help)
			sed -n '2,10p' "$0"
			exit 0
			;;
		*) echo "unknown arg: $arg" >&2; exit 1 ;;
	esac
done

if [[ "$STOP" -eq 1 ]]; then
	docker rm -f "$CONTAINER" 2>/dev/null || true
	echo "Stopped $CONTAINER" >&2
	exit 0
fi

if [[ "$FRESH" -eq 1 ]]; then
	docker rm -f "$CONTAINER" 2>/dev/null || true
fi

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
	echo "Starting ghcr.io/openwrt/rootfs:x86-64 ..." >&2
	docker run -d --name "$CONTAINER" \
		--privileged \
		--cap-add NET_ADMIN \
		--cap-add NET_RAW \
		-p 8080:80 \
		-p 8443:443 \
		-p 2222:22 \
		ghcr.io/openwrt/rootfs:x86-64 \
		/sbin/init

	echo "Waiting for firstboot (/etc/config/network + network.lan) ..." >&2
	for _ in $(seq 1 60); do
		docker exec "$CONTAINER" sh -c 'test -f /etc/config/network && uci -q get network.lan >/dev/null' 2>/dev/null && break
		sleep 2
	done
	sleep 3
fi

"${ROOT}/scripts/docker-rootfs-x86-bootstrap.sh"

ok=0
for _ in $(seq 1 15); do
	if curl -sS -m 5 -I http://127.0.0.1:8080/cgi-bin/luci/ 2>/dev/null | grep -qi 'x-luci-login-required'; then
		ok=1
		break
	fi
	sleep 2
done
if [[ "$ok" -eq 1 ]]; then
	echo "OK: LuCI login page reachable." >&2
else
	echo "WARN: http://127.0.0.1:8080/cgi-bin/luci/ did not return LuCI headers — check: docker logs $CONTAINER" >&2
	exit 1
fi

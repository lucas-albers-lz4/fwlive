#!/usr/bin/env bash
# Host proof for lab ping helpers: nft remove matches installed prefixes
# including the trailing space (#1286), and iptables LOG stays ahead of
# ACCEPT (#1287). Docker/SSH are stubbed so the production guest bodies run
# against fake nft/iptables.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
die() { echo "fwlive-ping-log-helpers test FAIL: $*" >&2; exit 1; }
ok() { echo "fwlive-ping-log-helpers test OK: $*"; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"
mkdir -p "$BIN"

cat >"$BIN/docker" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == inspect ]]; then
	exit 0
fi
if [[ "${1:-}" == exec ]]; then
	shift
	shift
	exec "$@"
fi
echo "unexpected docker args: $*" >&2
exit 1
EOS
chmod +x "$BIN/docker"

# --- nft listing + delete (#1286) ---
NFT_LIST="$WORK/nft.list"
NFT_DELETES="$WORK/nft.deletes"
: >"$NFT_DELETES"
cat >"$NFT_LIST" <<'EOS'
table inet fw4 {
	chain input {
		type filter hook input priority filter; policy drop;
		ip protocol icmp icmp type echo-request log prefix "fwlive-ping " accept # handle 10
		ip6 nexthdr ipv6-icmpv6 icmpv6 type echo-request log prefix "fwlive-ping6 " accept # handle 11
		iifname "lo" accept comment "!fw4: Accept traffic from loopback" # handle 12
	}
}
EOS

cat >"$BIN/nft" <<EOS
#!/usr/bin/env bash
set -euo pipefail
LIST="$NFT_LIST"
DELETES="$NFT_DELETES"
if [[ "\${1:-}" == -a && "\${2:-}" == list ]]; then
	cat "\$LIST"
	exit 0
fi
if [[ "\${1:-}" == list ]]; then
	cat "\$LIST"
	exit 0
fi
if [[ "\${1:-}" == delete && "\${2:-}" == rule && "\${6:-}" == handle ]]; then
	h="\${7:-}"
	echo "\$h" >>"\$DELETES"
	tmp=\$(mktemp)
	grep -v "handle \${h}\$" "\$LIST" >"\$tmp"
	mv "\$tmp" "\$LIST"
	exit 0
fi
if [[ "\${1:-}" == insert ]]; then
	echo "nft insert: \$*" >&2
	exit 0
fi
echo "unexpected nft args: \$*" >&2
exit 1
EOS
chmod +x "$BIN/nft"

PATH="$BIN:$PATH" "$ROOT/scripts/fwlive-nft-ping-log.sh" remove >"$WORK/nft-remove.out"
grep -Fxq '10' "$NFT_DELETES" || die "nft remove missed IPv4 handle 10: $(cat "$NFT_DELETES")"
grep -Fxq '11' "$NFT_DELETES" || die "nft remove missed IPv6 handle 11: $(cat "$NFT_DELETES")"
if grep -Fxq '12' "$NFT_DELETES"; then
	die "nft remove deleted unrelated handle 12"
fi
grep -q 'deleted handle 10' "$WORK/nft-remove.out" || die "missing IPv4 delete log"
grep -q 'deleted handle 11' "$WORK/nft-remove.out" || die "missing IPv6 delete log"
if grep -q 'fwlive-ping ' "$NFT_LIST"; then
	die "installed fwlive-ping prefix still listed after remove"
fi
if grep -q 'fwlive-ping6 ' "$NFT_LIST"; then
	die "installed fwlive-ping6 prefix still listed after remove"
fi
grep -q 'handle 12' "$NFT_LIST" || die "unrelated loopback rule must remain"
ok "#1286 nft remove matches trailing-space prefixes and spares unrelated rules"

# Space-stripped grep must not be what remove uses (the original bug).
if grep -F 'pat%\\ ' "$ROOT/scripts/fwlive-nft-ping-log.sh"; then
	die "nft remove still strips the trailing space from the prefix matcher"
fi
ok "#1286 nft remove keeps the installed trailing space in the matcher"

# --- iptables LOG-before-ACCEPT (#1287) ---
IPT_CHAIN="$WORK/ipt.chain"
: >"$IPT_CHAIN"

cat >"$BIN/iptables" <<EOS
#!/usr/bin/env bash
set -euo pipefail
CHAIN="$IPT_CHAIN"
args=("\$@")
join() { local IFS=' '; echo "\${args[*]}"; }
line=\$(join)

is_log() { [[ "\$line" == *"-j LOG"* ]]; }
is_accept() { [[ "\$line" == *"-j ACCEPT"* ]]; }

if [[ "\${1:-}" == -C ]]; then
	if is_log && grep -q ' -j LOG ' "\$CHAIN" 2>/dev/null; then
		exit 0
	fi
	if is_accept && grep -q ' -j ACCEPT' "\$CHAIN" 2>/dev/null; then
		exit 0
	fi
	exit 1
fi

if [[ "\${1:-}" == -I && "\${2:-}" == INPUT ]]; then
	pos=1
	rest=("\${args[@]:2}")
	if [[ "\${args[2]:-}" =~ ^[0-9]+\$ ]]; then
		pos="\${args[2]}"
		rest=("\${args[@]:3}")
	fi
	entry="\$pos \${rest[*]}"
	# Build new chain: insert at 1-based pos.
	mapfile -t cur <"\$CHAIN" || true
	idx=\$((pos - 1))
	if [[ \$idx -lt 0 ]]; then idx=0; fi
	new=()
	i=0
	inserted=0
	for r in "\${cur[@]}"; do
		if [[ \$i -eq \$idx ]]; then
			new+=("\$entry")
			inserted=1
		fi
		new+=("\$r")
		i=\$((i + 1))
	done
	if [[ \$inserted -eq 0 ]]; then
		new+=("\$entry")
	fi
	printf '%s\n' "\${new[@]}" >"\$CHAIN"
	exit 0
fi

if [[ "\${1:-}" == -D ]]; then
	tmp=\$(mktemp)
	if is_log; then
		grep -v ' -j LOG ' "\$CHAIN" >"\$tmp" || true
	elif is_accept; then
		grep -v ' -j ACCEPT' "\$CHAIN" >"\$tmp" || true
	else
		cp "\$CHAIN" "\$tmp"
	fi
	mv "\$tmp" "\$CHAIN"
	exit 0
fi

if [[ "\${1:-}" == -L ]]; then
	n=1
	while IFS= read -r row; do
		[[ -n "\$row" ]] || continue
		if [[ " \$* " == *" --line-numbers "* ]]; then
			echo "\$n \${row#* }"
		else
			echo "\$row"
		fi
		n=\$((n + 1))
	done <"\$CHAIN"
	exit 0
fi

echo "unexpected iptables args: \$*" >&2
exit 1
EOS
chmod +x "$BIN/iptables"

PATH="$BIN:$PATH" "$ROOT/scripts/fwlive-iptables-ping-log.sh" add >"$WORK/ipt-add.out"
[[ -s "$IPT_CHAIN" ]] || die "iptables add left an empty INPUT chain"
mapfile -t rules <"$IPT_CHAIN"
[[ ${#rules[@]} -ge 2 ]] || die "expected LOG and ACCEPT, got: $(cat "$IPT_CHAIN")"
[[ "${rules[0]}" == *"-j LOG"* ]] || die "position 1 must be LOG, got '${rules[0]}'"
[[ "${rules[1]}" == *"-j ACCEPT"* ]] || die "position 2 must be ACCEPT, got '${rules[1]}'"
grep -q 'added: INPUT icmp LOG' "$WORK/ipt-add.out" || die "missing LOG add log"
grep -q 'added: INPUT icmp ACCEPT' "$WORK/ipt-add.out" || die "missing ACCEPT add log"
ok "#1287 iptables add keeps LOG ahead of ACCEPT"

# Adding again must be a no-op (check hits) and preserve order.
PATH="$BIN:$PATH" "$ROOT/scripts/fwlive-iptables-ping-log.sh" add >"$WORK/ipt-add2.out"
mapfile -t rules2 <"$IPT_CHAIN"
[[ ${#rules2[@]} -eq 2 ]] || die "second add mutated chain: $(cat "$IPT_CHAIN")"
grep -q 'already present' "$WORK/ipt-add2.out" || die "second add should report already present"
ok "#1287 iptables add is idempotent"

# An existing LOG rule further down the chain must stay ahead of the new ACCEPT.
: >"$IPT_CHAIN"
printf '%s\n' \
	'1 -p tcp -j DROP' \
	'8 -p icmp --icmp-type echo-request -m comment --comment fwlive-ping -j LOG --log-prefix "fwlive-ping: "' \
	>"$IPT_CHAIN"
PATH="$BIN:$PATH" "$ROOT/scripts/fwlive-iptables-ping-log.sh" add >"$WORK/ipt-existing-log.out"
mapfile -t rules3 <"$IPT_CHAIN"
log_at=0
acc_at=0
i=0
for r in "${rules3[@]}"; do
	i=$((i + 1))
	[[ "$r" == *"-j LOG"* ]] && log_at=$i
	[[ "$r" == *"-j ACCEPT"* ]] && acc_at=$i
done
[[ "$log_at" -gt 0 && "$acc_at" -gt "$log_at" ]] || die "ACCEPT landed before existing LOG: $(cat "$IPT_CHAIN")"
ok "#1287 ACCEPT is inserted after an existing LOG rule"

echo "fwlive-ping-log-helpers tests passed"

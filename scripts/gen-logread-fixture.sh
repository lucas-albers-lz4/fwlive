#!/usr/bin/env bash
# Generate tests/fixtures/logread-2000.json from logread-mixed.json (#308 R1).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT}/tests/fixtures/logread-mixed.json"
OUT="${ROOT}/tests/fixtures/logread-2000.json"
COUNT="${1:-2000}"

NODE="${NODE:-}"
if [[ -z "$NODE" ]]; then
	command -v node >/dev/null 2>&1 && NODE=node || NODE=nodejs
fi

"$NODE" - "$SRC" "$OUT" "$COUNT" <<'NODE'
const fs = require('fs');
const [src, out, countStr] = process.argv.slice(2);
const want = parseInt(countStr, 10);
if (!Number.isFinite(want) || want < 1) {
	console.error('usage: gen-logread-fixture.sh [count]');
	process.exit(1);
}
const base = JSON.parse(fs.readFileSync(src, 'utf8'));
if (!Array.isArray(base.log) || base.log.length === 0) {
	console.error('source fixture must have a non-empty log array');
	process.exit(1);
}
const log = [];
for (let i = 0; i < want; i++) {
	const e = base.log[i % base.log.length];
	/* logd's id is monotonic for the lifetime of the logd instance. */
	log.push({ id: i, time: (e.time || 0) + i, msg: e.msg });
}
fs.writeFileSync(out, JSON.stringify({ log }));
const bytes = fs.statSync(out).size;
console.log(`wrote ${out}: ${want} entries, ${bytes} bytes`);
NODE

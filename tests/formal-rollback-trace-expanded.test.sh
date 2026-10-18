#!/usr/bin/env bash
# Expanded observation/projector checks; TLC conformance runs separately.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CAPTURE="$ROOT/tests/fwlive-rollback-trace-capture.sh"
PROJECT="$ROOT/scripts/formal-rollback-trace-project.py"
HELPER="$ROOT/openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-logging.sh"
python3 "$ROOT/tests/lib/rollback-trace-cases.py" --generated 4 > "$WORK/cases"
count=0
while IFS='|' read -r name mode intent initial schedule; do
	[[ "$schedule" != - ]] || schedule=''
	"$CAPTURE" "$HELPER" "$mode" "$WORK/$name" "$intent" "$initial" "$schedule" > "$WORK/$name.capture"
	python3 "$PROJECT" "$WORK/$name/observations.tsv" "$WORK/$name.cfg" > "$WORK/$name.projected"
	grep -Fq "PrimaryIntent = \"$intent\"" "$WORK/$name.cfg"
	if [[ "$initial" == 0 ]]; then grep -Fq 'InitialValue = "off"' "$WORK/$name.cfg"; fi
	case "$mode" in
		success) terminal=RestoreCommitSuccess ;;
		aba|noop|failed|failedstage) terminal=SkipNewerIntent ;;
		refusal) terminal=RestorePendingRefusal ;;
		reacquire) terminal=ReacquireUnavailable ;;
		generation) terminal=RestoreGenerationRefusal ;;
		stage) terminal=RestoreStageFailure ;;
		poststage) terminal=RestorePostStageRefusal ;;
		commit) terminal=RestoreCommitFailure ;;
		*) terminal='' ;;
	esac
	[[ -z "$terminal" ]] || grep -Fq "$terminal" "$WORK/$name.projected"
	count=$((count + 1))
done < "$WORK/cases"
[[ "$count" -eq 37 ]]
# Diagnostic English must have no bearing on projected model actions.
python3 - "$WORK/enable-unset-success/observations.tsv" "$WORK/logs-rewritten.tsv" <<'PY'
from pathlib import Path
import sys
lines = []
for line in Path(sys.argv[1]).read_text().splitlines():
    if line.startswith('LOG|'):
        line = '|'.join(line.split('|')[:-1] + ['unrelated rewritten message'])
    lines.append(line)
Path(sys.argv[2]).write_text('\n'.join(lines) + '\n')
PY
python3 "$PROJECT" "$WORK/logs-rewritten.tsv" "$WORK/logs-rewritten.cfg" > /dev/null
cmp "$WORK/enable-unset-success.cfg" "$WORK/logs-rewritten.cfg"
# Final state and terminal JSON are independent checks, not logger guesses.
python3 - "$WORK/enable-unset-success/observations.tsv" "$WORK" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
work = Path(sys.argv[2])
rows = text.splitlines()
for i, row in enumerate(rows):
    if row.startswith('SNAP|') and '|primary|' in row and '|return:' in row:
        changed = rows.copy()
        fields = row.split('|')
        fields[-1] = '3'
        changed[i] = '|'.join(fields)
        (work / 'bad-final.tsv').write_text('\n'.join(changed) + '\n')
        break
else:
    raise SystemExit('missing terminal observation mutation site')
(work / 'bad-json.tsv').write_text(text.replace('firewall_reload_failed', 'invented_result'))
(work / 'bad-kind.tsv').write_text(text + 'UNKNOWN|not-an-observation\n')
import json

def rewrite_json(source, destination, role, change):
    result = []
    for row in source.splitlines():
        fields = row.split('|')
        if fields[0] == 'JSON' and fields[2] == role:
            body = json.loads(fields[-1])
            change(body)
            fields[-1] = json.dumps(body, separators=(',', ':'))
        result.append('|'.join(fields))
    (work / destination).write_text('\n'.join(result) + '\n')

rewrite_json(text, 'bad-primary-json.tsv', 'primary',
             lambda body: body.update(ok=True, changed=True))
noop = (work / 'enable-unset-noop/observations.tsv').read_text()
rewrite_json(noop, 'bad-noop-json.tsv', 'secondary',
             lambda body: body.update(ok=False))
aba = (work / 'enable-unset-aba/observations.tsv').read_text()
missing = [row for row in aba.splitlines()
           if not (row.startswith('JSON|') and '|secondary|' in row)
           and not (row.startswith('SNAP|') and '|secondary|' in row and '|return:' in row)]
(work / 'bad-secondary-terminal.tsv').write_text('\n'.join(missing) + '\n')
rewrite_json(aba, 'bad-secondary-json.tsv', 'secondary',
             lambda body: body.update(ok=False, changed=False, error='invented_result'))
# A fatal setup error cannot be erased by later contention and success.
fatal = []
inserted = False
reload_seen = False
for row in rows:
    fields = row.split('|')
    if fields[0] == 'RELOAD' and fields[2] == 'primary':
        reload_seen = True
    if reload_seen and not inserted and fields[0] == 'FLOCK' and fields[2] == 'primary' and fields[5] == '-n 9':
        for rc in ['2', '1']:
            bad = fields.copy()
            bad[6] = rc
            fatal.append('|'.join(bad))
        inserted = True
    fatal.append(row)
if not inserted:
    raise SystemExit('missing flock history mutation site')
(work / 'bad-fatal-lock.tsv').write_text('\n'.join(fatal) + '\n')


PY
for mode in bad-final bad-json bad-kind bad-primary-json bad-noop-json bad-secondary-terminal bad-secondary-json bad-fatal-lock; do
	if python3 "$PROJECT" "$WORK/$mode.tsv" "$WORK/$mode.cfg" > "$WORK/$mode.log" 2>&1; then
		echo "expanded rollback: accepted $mode corruption" >&2
		exit 1
	fi
done
echo 'expanded rollback: 33 deterministic + 4 generated captures, logger independence, malformed final/JSON/kind and secondary-terminal rejection passed'

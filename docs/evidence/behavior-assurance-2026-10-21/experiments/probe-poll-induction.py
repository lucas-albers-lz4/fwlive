"""A controlled slow successful poll must induce the next request's cap.

Runs shipped rpcd/filter/classifier/adaptive assets, matched jshn and host ash.
Only the clock and logd/jsonfilter OS-service seams are controlled. This is not
an elapsed-time or installed-router performance measurement.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[4]
rpc = ROOT / 'openwrt-feed/luci-app-fwlive/root/usr/libexec/rpcd/fwlive'
src = rpc.read_text()
needle = '\t\tfwlive_adaptive_record "$_dur" "$lines"'
assert src.count(needle) == 1
mutant = src.replace(needle, '\t\tif [ "$_dur" -lt 800 ]; then\n' + needle + '\n\t\tfi')
pair = Path.home() / '.cache/fwlive-jshn/24.10'
assert (pair / 'bin/jshn').exists() and (pair / 'share/jshn.sh').exists()
rows = []
with tempfile.TemporaryDirectory(prefix='fwlive-poll-induction-') as td:
    scratch = Path(td)
    for variant, source in [('baseline', src), ('drop-slow-successful-samples', mutant)]:
        lib = scratch / variant / 'libexec'
        shutil.copytree(rpc.parent.parent, lib)
        plugin = lib / 'rpcd/fwlive'
        plugin.write_text(source)
        # The appended override is the same seam used by the existing clock
        # regression. Every poll calls it once before and once after filtering.
        with (lib / 'fwlive-adaptive-cap.sh').open('a') as stream:
            stream.write('''
fwlive_adaptive_clock_cs() {
    n=0
    if [ -f "$PROBE_CLOCK_CALLS" ]; then read -r n < "$PROBE_CLOCK_CALLS"; fi
    n=$((n + 1))
    printf '%s\\n' "$n" > "$PROBE_CLOCK_CALLS"
    if [ "$n" = 1 ]; then printf '%s\\n' "$PROBE_START";
    else printf '%s\\n' "$PROBE_END"; fi
}
''')
        tools = scratch / variant / 'bin'
        tools.mkdir()
        payload = json.dumps({'log': [{'id': 1, 'msg':
            'kernel: DROP IN=wan OUT= SRC=192.0.2.1 DST=198.51.100.2 PROTO=TCP DPT=443'}]})
        (tools / 'ubus').write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$PROBE_UBUS_LOG"\ncat "$PROBE_LOG_INPUT"\n')
        node = shutil.which('node')
        (tools / 'jsonfilter').write_text('#!' + node + '''
const assert = require('node:assert/strict');
const fs = require('node:fs');
assert.deepEqual(process.argv.slice(2), ['-e', '@.log[*]']);
for (const entry of JSON.parse(fs.readFileSync(0, 'utf8')).log)
    process.stdout.write(JSON.stringify(entry) + '\\n');
''')
        for p in tools.iterdir():
            p.chmod(0o755)
        input_file = scratch / variant / 'log.json'
        input_file.write_text(payload)
        for cadence in (100, 500):
            work = scratch / variant / str(cadence)
            # The real adaptive writer refuses group/other-writable state
            # directories. Preserve that prerequisite regardless of umask.
            work.mkdir(mode=0o700)
            state = work / 'state.json'
            env = dict(os.environ, PATH=f'{tools}:{pair / "bin"}:{os.environ["PATH"]}',
                       FWLIVE_JSHN_SH=str(pair / 'share/jshn.sh'), FWLIVE_ADAPTIVE='1',
                       FWLIVE_ADAPTIVE_STATE_FILE=str(state), FWLIVE_ADAPTIVE_OFF_FILE=str(work / 'off'),
                       PROBE_CLOCK_CALLS=str(work / 'clock'), PROBE_UBUS_LOG=str(work / 'ubus'),
                       PROBE_LOG_INPUT=str(input_file))
            trace = []
            # Four slow successes, then healthy samples with the same explicit
            # retained backlog. This controls service time; no real sleep.
            for i, duration_ms in enumerate([900] * 4 + [20] * 5):
                (work / 'clock').unlink(missing_ok=True)
                start = 10000 + i * cadence
                callenv = dict(env, PROBE_START=str(start), PROBE_END=str(start + duration_ms // 10))
                result = subprocess.run(['busybox', 'sh', str(plugin), 'call', 'poll', '{"addresses":["2000"]}'],
                                        env=callenv, capture_output=True, text=True, timeout=15)
                assert result.returncode == 0, result.stderr
                reply = json.loads(result.stdout)
                assert reply.get('error') is None and reply['messages_received'] == 1
                assert len(reply['log']) == 1
                ubus_line = (work / 'ubus').read_text().splitlines()[-1]
                assert ubus_line.startswith('-t 5 call log read '), ubus_line
                actual_request = json.loads(ubus_line[len('-t 5 call log read '):])
                assert actual_request['stream'] is False
                assert actual_request['lines'] == reply['effective_limit'], (actual_request, reply)
                recorded = json.loads(state.read_text()) if state.exists() else None
                trace.append(dict(duration_ms=duration_ms, effective_limit=reply.get('effective_limit'),
                                  actual_ubus_lines=actual_request['lines'],
                                  truncated=reply.get('truncated'), shed=reply.get('shed'),
                                  state=recorded))
            limits = [x['effective_limit'] for x in trace]
            expected = [2000, 250, 250, 250, 250, 500, 1000, 2000, 2000]
            if variant == 'baseline':
                assert limits == expected, (variant, cadence, trace)
            else:
                assert limits == [2000] * 9, (variant, cadence, trace)
            rows.append(dict(probe='production-poll-controlled-clock', variant=variant,
                             cadence_cs=cadence, limits=limits, expected_limits=expected,
                             matches_expected=limits == expected, trace=trace))
    # Check the untouched existing RPC suite against the faulty source, with
    # the normal fixture ROOT and dependencies. The existing suite contains
    # clock/read/filter-failure controls but does not induce hot state from a
    # successful slow poll. Logging's separate shell suite is not rerun here.
    original_test = (ROOT / 'tests/fwlive-rpcd-security.test.js').read_text()
    original_test = original_test.replace("require('./lib/child-process-timeout')",
                                          'require(' + json.dumps(str(ROOT / 'tests/lib/child-process-timeout')) + ')')
    original_test = original_test.replace("const ROOT = path.join(__dirname, '..');",
                                          'const ROOT = ' + json.dumps(str(ROOT)) + ';')
    for variant, source in [('baseline', src), ('drop-slow-successful-samples', mutant)]:
        lib = scratch / ('suite-' + variant) / 'libexec'
        shutil.copytree(rpc.parent.parent, lib)
        (lib / 'rpcd/fwlive').write_text(source)
        text = original_test.replace("const RPCD = path.join(ROOT, 'openwrt-feed/luci-app-fwlive/root/usr/libexec/rpcd/fwlive');",
                                     'const RPCD = ' + json.dumps(str(lib / 'rpcd/fwlive')) + ';')
        test_file = scratch / ('suite-' + variant + '.js')
        test_file.write_text(text)
        result = subprocess.run(['node', str(test_file)], env=dict(os.environ, FWLIVE_LOGGING_VIA_RUNNER='1'),
                                capture_output=True, text=True, timeout=90)
        assert result.returncode == 0, (variant, result.stdout, result.stderr)
        # Preserve the diagnostic but not the random temporary workspace name.
        rows.append(dict(probe='existing-RPC-suite', variant=variant, exit_code=result.returncode,
                         stdout=result.stdout.replace(str(scratch), '<TMPDIR>/fwlive-poll-induction'),
                         stderr=result.stderr.replace(str(scratch), '<TMPDIR>/fwlive-poll-induction')))
        print('existing RPC suite', variant, result.returncode, flush=True)
(Path(__file__).with_name('poll-induction-result.json')).write_text(json.dumps(rows, indent=2) + '\n')
for row in rows:
    print(json.dumps({k:v for k,v in row.items() if k not in ('trace', 'stdout', 'stderr')}))

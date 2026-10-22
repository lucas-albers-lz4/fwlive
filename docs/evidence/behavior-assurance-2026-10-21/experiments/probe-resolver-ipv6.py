"""Reproduce the resolver IPv6-loop regression discrimination check."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[4]
RPC = ROOT / 'openwrt-feed/luci-app-fwlive/root/usr/libexec/rpcd/fwlive'
TEST = ROOT / 'tests/fwlive-jshn-compat.test.py'
needle = '\t\t# Producer already validated; skip repeats before they cost a slot.\n'
source = RPC.read_text()
assert source.count(needle) == 1, 'fault target must remain unique'
fault = source.replace(needle, needle +
                       '\t\tcase "$ip" in *:*) continue ;; esac # deliberate IPv6-loop fault\n')

def run(env):
    return subprocess.run([sys.executable, str(TEST)], cwd=ROOT, env=env,
                          capture_output=True, text=True, timeout=120)

baseline = run(os.environ.copy())
assert baseline.returncode == 0, (baseline.stdout, baseline.stderr)
with tempfile.TemporaryDirectory(prefix='fwlive-ipv6-fault-') as temporary:
    source_copy = Path(temporary) / 'rpcd-fault'
    source_copy.write_text(fault)
    env = dict(os.environ, FWLIVE_RPCD_TEST_SOURCE=str(source_copy))
    mutant = run(env)
    assert mutant.returncode != 0, 'the exact lookup-loop fault must be detected'
    temporary_root = str(Path(temporary))
    result = {
        'baseline_command': 'python3 tests/fwlive-jshn-compat.test.py',
        'baseline_exit': baseline.returncode,
        'baseline_log': baseline.stdout.strip(),
        'fault': 'Skip IPv6 addresses only in the production resolve lookup loop.',
        'mutation_command': 'FWLIVE_RPCD_TEST_SOURCE=<temporary mutant copy> python3 tests/fwlive-jshn-compat.test.py',
        'mutation_exit': mutant.returncode,
        'mutation_log': mutant.stderr.replace(temporary_root, '<TMPDIR>/fwlive-ipv6-fault')
            .replace(str(ROOT), '<REPO>').strip(),
        'diagnostic_note': 'Temporary paths normalized; assertion and actual correlation retained.'
    }
    output = Path(__file__).with_name('resolver-ipv6-result.json')
    output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({key: value for key, value in result.items()
                      if key not in ('baseline_log', 'mutation_log')}, indent=2))

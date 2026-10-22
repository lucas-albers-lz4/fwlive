"""Falsify the existing SDK-path oracle; never contacts Docker or uses real keys.

The extracted SDK shell body executes under host /bin/sh with fixed /feed paths
relocated into a temporary directory. This preserves shell error ordering, not
container isolation, SDK binary semantics or cryptographic validity.
"""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[4]
source = (ROOT / 'scripts/lib/feed-publish.sh').read_text()
needle = '\t\t\tgrep -vE "^(Maintainer|LicenseFiles|Source|SourceName|Require|SourceDateEpoch)" "$RAW" > Packages'
assert source.count(needle) == 1
mutant = source.replace(needle, needle + ' || [ "$?" -eq 2 ]')
start = source.index('feed_publish_stage_opkg_sdk() {')
end = source.index('\nfeed_publish_stage_opkg()', start)
block = source[start:end]
open_marker = "\t\tsh -ec '\n"
body_start = block.index(open_marker) + len(open_marker)
body_end = block.index("\n\t\t\t'\n\tthen", body_start)
body = block[body_start:body_end]
records = []
with tempfile.TemporaryDirectory(prefix='fwlive-index-probe-') as td:
    scratch = Path(td)
    # Copy only the unchanged test and the helper's same-directory dependencies.
    tree = scratch / 'tree'
    (tree / 'scripts').mkdir(parents=True)
    shutil.copytree(ROOT / 'scripts/lib', tree / 'scripts/lib')
    (tree / 'tests').mkdir()
    shutil.copy2(ROOT / 'tests/feed-publish-copy-keys.test.sh', tree / 'tests')
    for name, text in [('baseline', source), ('SDK-grep-error-accepted', mutant)]:
        (tree / 'scripts/lib/feed-publish.sh').write_text(text)
        check = subprocess.run(['bash', str(tree / 'tests/feed-publish-copy-keys.test.sh')],
                               capture_output=True, text=True, timeout=30)
        records.append(dict(probe='existing-host-and-source-guard', variant=name,
                            exit_code=check.returncode, stdout=check.stdout, stderr=check.stderr))
    for variant in ('baseline', 'SDK-grep-error-accepted'):
        for mode in ('valid-index', 'partial-index-exit-2'):
            feed = scratch / (variant + '-' + mode)
            tools = feed / 'tools'
            pkg = feed / 'pkgdir'
            tools.mkdir(parents=True)
            pkg.mkdir()
            stubs = {
                'ipkg-make-index.sh': '#!/bin/sh\nprintf "Package: luci-app-fwlive\\nMaintainer: fixture\\nVersion: 0.0.1\\n"\n',
                'mkhash': '#!/bin/sh\nprintf "dummy-hash\\n"\n',
                'usign': '#!/bin/sh\nprintf "dummy-signature\\n" > Packages.sig\n',
                'grep': ('#!/bin/sh\nprintf "Package: partial-index\\n"\nexit 2\n'
                         if mode.startswith('partial') else '#!/bin/sh\nexec /usr/bin/grep "$@"\n'),
            }
            for name, content in stubs.items():
                p = tools / name
                p.write_text(content)
                p.chmod(0o755)
            executable = body
            if variant != 'baseline':
                assert needle in executable
                executable = executable.replace(needle, needle + ' || [ "$?" -eq 2 ]')
            # All /feed occurrences in this static block refer to mounts whose
            # paths are controlled here. No production /feed path is touched.
            executable = executable.replace('/feed/', str(feed) + '/')
            check = subprocess.run(['/bin/sh', '-ec', executable], capture_output=True,
                                   text=True, timeout=15)
            records.append(dict(probe='extracted-SDK-shell-body-host-only', variant=variant,
                                fault=mode, exit_code=check.returncode,
                                compressed=(pkg / 'Packages.gz').exists(),
                                signed_sentinel=(pkg / 'Packages.sig').exists(),
                                index=(pkg / 'Packages').read_text() if (pkg / 'Packages').exists() else None,
                                stdout=check.stdout, stderr=check.stderr))
out = Path(__file__).with_name('index-filter-result.json')
for row in records:
    if row['probe'] == 'existing-host-and-source-guard':
        assert row['exit_code'] == 0, row
    elif row['fault'] == 'partial-index-exit-2' and row['variant'] == 'baseline':
        assert row['exit_code'] == 2 and not row['compressed'] and not row['signed_sentinel'], row
    else:
        assert row['exit_code'] == 0 and row['compressed'] and row['signed_sentinel'], row
out.write_text(json.dumps(records, indent=2) + '\n')
for row in records:
    print(json.dumps({k: v for k, v in row.items() if k not in ('stdout', 'stderr', 'index')}))

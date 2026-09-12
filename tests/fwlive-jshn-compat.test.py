#!/usr/bin/env python3
"""Exercise production RPC paths with real, matched libubox jshn pairs."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PREFIX = Path(os.environ.get('FWLIVE_JSHN_PREFIX', Path.home() / '.cache/fwlive-jshn'))
RPC = ROOT / 'openwrt-feed/luci-app-fwlive/root/usr/libexec/rpcd/fwlive'
RELEASES = ('21.02', '22.03', '23.05', '24.10', '25.12')


def main():
    busybox = shutil.which('busybox')
    assert busybox, 'busybox required'
    source = Path(os.environ.get('FWLIVE_RPCD_TEST_SOURCE', RPC)).read_text()
    for release in RELEASES:
        pair = PREFIX / release
        assert (pair / 'bin/jshn').is_file(), f'Install real jshn: scripts/install-host-jshn.sh --all ({release} missing)'
        assert (pair / 'share/jshn.sh').is_file(), f'{release}: missing matched helper'
        with tempfile.TemporaryDirectory(prefix='fwlive-compat-') as tmp:
            work = Path(tmp)
            libexec = work / 'libexec'
            shutil.copytree(RPC.parent.parent, libexec)
            plugin = libexec / 'rpcd/fwlive'
            text = source.replace('/usr/share/libubox/jshn.sh', str(pair / 'share/jshn.sh'))
            # BusyBox may prefer its timeout applet, whose nslookup applet
            # bypasses PATH stubs. Bind the OS service to host timeout.
            text = 'timeout() { /usr/bin/timeout "$@"; }\n' + text
            plugin.write_text(text)
            bindir = work / 'bin'
            bindir.mkdir()
            # Only OS services are stubbed; JSON binary and shell library are real.
            lookup_log = work / 'lookups'
            stubs = {
                'nslookup': '#!/bin/sh\nprintf "%s\\n" "$*" >> "$LOOKUP_LOG"\nprintf "1.2.0.192.in-addr.arpa name = host.example.\\nAddress: 192.0.2.1\\n"\n',
                'ubus': '#!/bin/sh\nprintf "%s" "$4" > "$POLL_REQUEST"\nexit 1\n',
            }
            for name, body in stubs.items():
                path = bindir / name
                path.write_text(body)
                path.chmod(0o755)
            env = dict(os.environ, PATH=f'{bindir}:{pair / "bin"}:/usr/bin:/bin',
                       LOOKUP_LOG=str(lookup_log), POLL_REQUEST=str(work / 'poll'),
                       FWLIVE_ADAPTIVE='1',
                       FWLIVE_ADAPTIVE_STATE_FILE=str(work / 'adaptive-state.json'),
                       FWLIVE_ADAPTIVE_OFF_FILE=str(work / 'adaptive-off-absent'))

            def run(method, data, plugin=plugin, env=env, release=release):
                result = subprocess.run([busybox, 'sh', '-eu', str(plugin), 'call', method],
                                        input=data, text=True, capture_output=True, env=env, timeout=15)
                assert result.returncode == 0, (release, method, data, result.stderr)
                return json.loads(result.stdout)

            for data in ('not-json{{{', '{', ''):
                assert run('resolve', data) == {'names': {}, 'error': 'invalid_input'}, (release, data)
            for data in ('{}', '{"addresses":[]}', '{"addresses":null}', '{"addresses":"bad"}'):
                assert run('resolve', data) == {'names': {}}, (release, data)
            resolved = run('resolve', '{"addresses":["192.0.2.1"]}')
            assert resolved == {'names': {'192.0.2.1': 'host.example'}}, (release, resolved, lookup_log.read_text() if lookup_log.exists() else 'no lookup')
            assert run('resolve', json.dumps({'addresses': ['bad', '192.0.2.1', '2001:db8::1']})) == {
                'names': {'192.0.2.1': 'host.example', '2001:db8::1': 'host.example'}}
            lookup_log.unlink()
            assert run('resolve', json.dumps({'addresses': ['192.0.2.1\n192.0.2.2']})) == {'names': {}}
            assert not lookup_log.exists(), 'newline must not become two valid addresses'
            for data, expected in [('not-json{{{', 50), ('{}', 50), ('{"addresses":[]}', 50),
                                   ('{"addresses":["500"]}', 500), ('{"addresses":["0"]}', 50), ('{"addresses":["0005"]}', 5), ('{"addresses":["999999999999999999999"]}', 2000)]:
                got = run('poll', data)
                assert got.get('log') == [] and got.get('error') == 'log_read_failed', (release, data, got)
                assert got.get('adaptive') == 1, (release, got)
                assert 'messages_received' in got, (release, got)
                assert json.loads((work / 'poll').read_text())['lines'] == expected
            # Source only function definitions; verify functions return before
            # checking flags, so an unrelated abort cannot masquerade as proof.
            definitions = libexec / 'rpcd/definitions'
            dispatch = 'case "${1:-}" in\n\t__selftest)'
            assert text.count(dispatch) == 1, 'production dispatch boundary changed'
            definitions.write_text(text.split(dispatch)[0])
            for function in ('poll_lines_from_input', 'resolve_addresses'):
                for data in ('{}', 'not-json{{{', '{"addresses":["192.0.2.1"]}'):
                    check = '. "$1"; ' + function + ' "$2" >/dev/null; case "$-" in *e*u*|*u*e*) echo restored;; *) exit 7;; esac'
                    result = subprocess.run([busybox, 'sh', '-eu', '-c', check, str(plugin), str(definitions), data],
                                            env=env, capture_output=True, text=True, timeout=15)
                    assert result.returncode == 0 and result.stdout.strip() == 'restored', (release, function, data, result.stderr)
            result = subprocess.run([busybox, 'sh', str(plugin), '__selftest'], env=env, capture_output=True, text=True, timeout=30)
            assert result.returncode == 0, (release, result.stderr)
        print(f'jshn compat: {release} poll, resolve, invalid input, boundaries, strict mode, selftest PASS')


if __name__ == '__main__':
    main()

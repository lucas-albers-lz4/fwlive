#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Copyright 2026 Lucas Albers <lucas.b.albers@gmail.com>
"""Exercise launch argv and guest transactions without root or a real guest."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
GUEST = (ROOT / 'scripts/qemu-forwarding-slo-guest.sh').read_text().split("<<'REMOTE'\n", 1)[1].rsplit('\nREMOTE', 1)[0]


class Controls(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='fwlive-controls-')
        self.addCleanup(self.tmp.cleanup)
        self.p = Path(self.tmp.name)
        self.bin = self.p / 'bin'
        self.bin.mkdir()
        self.env = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}', LAB=str(self.p))

    def stub(self, name, code):
        p = self.bin / name
        p.write_text(code)
        p.chmod(0o755)

    def guest_setup(self):
        for dev, mac in [('eth1', '52:54:00:30:77:01'), ('eth2', '52:54:00:30:77:02')]:
            p = self.p / 'net' / dev
            p.mkdir(parents=True)
            (p / 'address').write_text(mac)
            (p / 'flags').write_text('0x0')
        (self.p / 'printk').write_text('7 4 1 7\n')
        (self.p / 'forward').write_text('0\n')
        self.stub('ip', '#!/bin/sh\nexit 0\n')
        self.stub('sysctl', '#!/bin/sh\nprintf "%s\\n" "$*" >> "$LAB/sysctl-calls"\n')
        self.stub('logread', '#!/bin/sh\ncat "$LAB/logs"\n')
        self.stub('nft', '''#!/usr/bin/env python3
import os, pathlib, sys
p = pathlib.Path(os.environ['LAB'])
a = sys.argv[1:]
rules = p / 'rules'
if a == ['-f', '-']:
    data = sys.stdin.read()
    (p / 'submitted-nft').write_text(data)
    if os.environ.get('FAIL_NFT') == '1': sys.exit(1)
    assert 'log prefix "fwlive-slo "' in data
    rules.write_text(data)
elif a[:5] == ['-a', 'list', 'chain', 'inet', 'fw4']:
    for n, line in enumerate(rules.read_text().splitlines() if rules.exists() else [], 1):
        print(line + ' # handle ' + str(n))
elif a[:4] == ['delete', 'rule', 'inet', 'fw4']:
    if os.environ.get('FAIL_DELETE') == '1': sys.exit(1)
    # Removal is checked by the real helper's subsequent chain listing.
    rules.write_text('')
else: sys.exit(2)
''')
        script = GUEST.replace('/sys/class/net', str(self.p / 'net'))
        script = script.replace('/proc/sys/kernel/printk', str(self.p / 'printk'))
        script = script.replace('/proc/sys/net/ipv4/ip_forward', str(self.p / 'forward'))
        script = script.replace('/var/run/fwlive-slo-guest.state', str(self.p / 'state'))
        self.remote = self.p / 'remote.sh'
        self.remote.write_text(script)

    def guest(self, action, **overrides):
        return subprocess.run(['sh', str(self.remote), action, '52:54:00:30:77:01',
                               '52:54:00:30:77:02', '192.0.2.1', '198.51.100.1', '4', '250'],
                              env=dict(self.env, **overrides), capture_output=True, text=True)

    def test_guest_quoted_batch_log_visibility_and_restore(self):
        self.guest_setup()
        result = self.guest('configure')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.p / 'state').stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.p / 'printk').read_text(), '4\n')
        self.assertIn('limit rate 250/second log prefix "fwlive-slo "', (self.p / 'submitted-nft').read_text())
        (self.p / 'logs').write_text('kernel: fwlive-slo IN=eth1 OUT=eth2 SRC=192.0.2.2\n')
        self.assertEqual(self.guest('check-logs').returncode, 0)
        (self.p / 'logs').write_text('kernel: fwlive-sloIN=eth1 OUT=eth2\n')
        self.assertNotEqual(self.guest('check-logs').returncode, 0)
        (self.p / 'logs').write_text('kernel: unrelated\n')
        self.assertNotEqual(self.guest('check-logs').returncode, 0)
        result = self.guest('cleanup')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.p / 'printk').read_text(), '7\n')
        self.assertFalse((self.p / 'state').exists())

    def test_guest_batch_failure_rolls_back_console_and_state(self):
        self.guest_setup()
        result = self.guest('configure', FAIL_NFT='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.p / 'printk').read_text(), '7\n')
        self.assertFalse((self.p / 'state').exists())
        self.assertIn('net.ipv4.ip_forward=0', (self.p / 'sysctl-calls').read_text())

    def test_failed_cleanup_retains_state_but_restores_console(self):
        self.guest_setup()
        self.assertEqual(self.guest('configure').returncode, 0)
        result = self.guest('cleanup', FAIL_DELETE='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.p / 'state').exists())
        self.assertEqual((self.p / 'printk').read_text(), '7\n')

    def launcher(self, **options):
        self.stub('ss', '#!/bin/sh\nexit 0\n')
        self.stub('qemu-system-x86_64', '#!/usr/bin/env python3\nimport json,os,sys\nopen(os.environ["LAB"]+"/argv", "w").write(json.dumps(sys.argv[1:]))\n')
        for f in ['disk', 'code', 'vars']:
            (self.p / f).touch()
        env = dict(self.env, OWRT_X86_IMG=str(self.p / 'disk'), OVMF_CODE=str(self.p / 'code'),
                   OVMF_VARS=str(self.p / 'vars'), OWRT_CONSOLE_LOG=str(self.p / 'console'),
                   OWRT_QEMU_PIDFILE=str(self.p / 'qemu.pid'), OWRT_HOSTFWD_HTTP='13080',
                   OWRT_HOSTFWD_SSH='13022', OWRT_HOSTFWD_BIND='127.0.0.1')
        env.update(options)
        return subprocess.run([str(ROOT / 'scripts/run-openwrt-x86-qemu.sh')], env=env,
                              capture_output=True, text=True)

    def test_launcher_default_and_larger_multiqueue_guest(self):
        result = self.launcher()
        self.assertEqual(result.returncode, 0, result.stderr)
        args = json.loads((self.p / 'argv').read_text())
        self.assertEqual(args[args.index('-smp') + 1], '2')
        self.assertNotIn('-netdev', args)
        result = self.launcher(OWRT_QEMU_SMP='8', OWRT_QEMU_DISK_FORMAT='qcow2',
                               OWRT_QEMU_FORWARDING_SLO='1', FWLIVE_SLO_QEMU_VHOST='1',
                               FWLIVE_SLO_QEMU_QUEUES='4')
        self.assertEqual(result.returncode, 0, result.stderr)
        args = json.loads((self.p / 'argv').read_text())
        self.assertEqual(args[args.index('-smp') + 1], '8')
        self.assertLess(args.index('-nic'), args.index('-device'))
        self.assertIn('model=virtio-net-pci', args[args.index('-nic') + 1])
        self.assertTrue(any('vhost=on,queues=4' in arg for arg in args))
        self.assertTrue(any('mq=on,vectors=10' in arg for arg in args))
        self.assertTrue(any('format=qcow2,if=virtio' in arg for arg in args))

    def test_launcher_rejects_invalid_options_before_start(self):
        for options in [dict(OWRT_QEMU_SMP='0'), dict(OWRT_QEMU_SMP='65'),
                        dict(OWRT_QEMU_SMP='8,cores=64'), dict(OWRT_QEMU_DISK_FORMAT='auto'),
                        dict(OWRT_QEMU_MEM='1G'), dict(OWRT_QEMU_FORWARDING_SLO='yes')]:
            with self.subTest(options=options):
                self.assertNotEqual(self.launcher(**options).returncode, 0)
                self.assertFalse((self.p / 'argv').exists())


if __name__ == '__main__':
    unittest.main()

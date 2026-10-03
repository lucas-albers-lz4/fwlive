#!/usr/bin/env node
import assert from 'node:assert/strict';
import { summarizeTelemetry } from './lib/fwlive-forwarding-slo-telemetry.mjs';

function snapshot({ cpu0, cpu1, irq0, irq1, soft0, soft1, net0, net1, printk, logBytes, dmesg }) {
return `###identity
Linux lab 6.1.0 x86_64
OpenWrt 24.10.8
###busybox_banner
BusyBox v1.36.1 multi-call binary.
###package_manager
apk-tools 3.0.5
busybox-1.37.0-r6
###source_hashes
abc123  /usr/libexec/rpcd/fwlive
###cmdline
console=ttyS0,115200
###printk
${printk}
###proc_stat
cpu  0 0 0 0 0 0 0 0 0 0
cpu0 ${cpu0}
cpu1 ${cpu1}
###interrupts
           CPU0       CPU1
  1: ${irq0} ${irq1} IO-APIC edge timer
###softirqs
                    CPU0       CPU1
NET_RX: ${soft0} ${soft1}
###softnet_stat
${net0}
${net1}
###dmesg_ring
10 ${dmesg}
###console_log
bytes=${logBytes}
###devices
device=eth1 rx_queues=1 tx_queues=1
`;
}

const report = summarizeTelemetry({
	hostBefore: snapshot({
		cpu0: '100 0 30 1000 5 4 2 0 0 0', cpu1: '80 0 20 900 0 3 1 0 0 0',
		irq0: '100', irq1: '200', soft0: '10', soft1: '20',
		net0: '64 0a 02 00 0 0 0 0 0 0 00', net1: '32 05 01 00 0 0 0 0 0 0 00',
		printk: '7 4 1 7', logBytes: '100', dmesg: '1000'
	}),
	hostAfter: snapshot({
		cpu0: '120 0 40 1090 5 9 7 0 0 0', cpu1: '90 0 30 950 0 6 3 0 0 0',
		irq0: '110', irq1: '220', soft0: '15', soft1: '28',
		net0: '6e 0c 05 00 0 0 0 0 0 0 02', net1: '3c 06 02 00 0 0 0 0 0 0 01',
		printk: '4 4 1 7', logBytes: '180', dmesg: '1080'
	}),
	guestBefore: snapshot({
		cpu0: '100 0 30 1000 5 4 2 0 0 0', cpu1: '80 0 20 900 0 3 1 0 0 0',
		irq0: '100', irq1: '200', soft0: '10', soft1: '20',
		net0: '64 0a 02 00 0 0 0 0 0 0 00', net1: '32 05 01 00 0 0 0 0 0 0 00',
		printk: '7 4 1 7', logBytes: '', dmesg: '1000'
	}),
	guestAfter: snapshot({
		cpu0: '120 0 40 1090 5 9 7 0 0 0', cpu1: '90 0 30 950 0 6 3 0 0 0',
		irq0: '110', irq1: '220', soft0: '15', soft1: '28',
		net0: '6e 0c 05 00 0 0 0 0 0 0 02', net1: '3c 06 02 00 0 0 0 0 0 0 01',
		printk: '4 4 1 7', logBytes: '', dmesg: '1080'
	})
});

assert.equal(report.host.cpu_per_core.cpu0.busy_ticks, 40);
assert.equal(report.host.cpu_per_core.cpu0.busy_pct, 30.769);
assert.equal(report.host.interrupts.by_cpu.cpu0, 10);
assert.equal(report.host.softirqs.by_cpu.cpu1, 8);
assert.equal(report.host.softnet.per_cpu[0].processed, 10);
assert.equal(report.host.softnet.per_cpu[0].dropped, 2);
assert.equal(report.host.console_policy.before.console_loglevel, 7);
assert.equal(report.host.console_policy.after.console_loglevel, 4);
assert.equal(report.host.console_policy.qemu_console_log_bytes_delta, 80);
assert.equal(report.host.console_policy.dmesg_ring_is_occupancy_not_emitted_volume, true);
assert.equal(report.guest.console_policy.qemu_console_log_available, false);
assert.match(report.guest.busybox_banner, /BusyBox v1\.36\.1/);
assert.match(report.guest.package_manager, /apk-tools 3\.0\.5/);
assert.match(report.guest.installed_source_hashes, /abc123/);
// Real 15-column kernel layout: CPU 7 is the only online row; the backlog
// drains from six to zero while processed/drop/time_squeeze counters increase.
const modernBefore = '###softnet_stat\n64 0a 02 0 0 0 0 0 0 0 0 6 7 5 1\n###meminfo\nMemAvailable: 900000 kB\n';
const modernAfter = '###softnet_stat\n6e 0c 05 0 0 0 0 0 0 0 0 0 7 0 0\n###meminfo\nMemAvailable: 910000 kB\n';
const modern = summarizeTelemetry({ hostBefore: modernBefore, hostAfter: modernAfter, guestBefore: '', guestAfter: '' });
assert.equal(modern.host.softnet.per_cpu.length, 1);
assert.equal(modern.host.softnet.per_cpu[0].cpu, 'cpu7');
assert.equal(modern.host.softnet.per_cpu[0].processed, 10);
assert.equal(modern.host.softnet.per_cpu[0].dropped, 2);
assert.equal(modern.host.softnet.per_cpu[0].time_squeeze, 3);
assert.equal(modern.host.softnet.per_cpu[0].counter_reset_or_wrap, false);
assert.equal(modern.host.softnet.per_cpu[0].raw_before[11], 6);
assert.equal(modern.host.softnet.per_cpu[0].raw_after[11], 0);
assert.equal('cpu_collision' in modern.host.softnet.per_cpu[0], false);
assert.equal(modern.raw_snapshots.host_before, modernBefore);
assert.match(modern.host.memory_after, /910000/);
const reset = summarizeTelemetry({ hostBefore: modernAfter, hostAfter: modernBefore, guestBefore: '', guestAfter: '' });
assert.equal(reset.host.softnet.per_cpu[0].processed, null);
assert.equal(reset.host.softnet.per_cpu[0].counter_reset_or_wrap, true);
console.log('fwlive forwarding SLO telemetry tests passed');

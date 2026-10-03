/* SPDX-License-Identifier: GPL-2.0-only */
import fs from 'node:fs';

function sections(text) {
	const out = {};
	let current = null;
	for (const line of String(text).split(/\r?\n/)) {
		const marker = /^###([A-Za-z0-9_]+)$/.exec(line);
		if (marker) {
			current = marker[1];
			out[current] = [];
		} else if (current) {
			out[current].push(line);
		}
	}
	return Object.fromEntries(Object.entries(out).map(([key, value]) => [key, value.join('\n').trim()]));
}

function cpuCounters(text) {
	const result = {};
	for (const line of text.split(/\r?\n/)) {
		const match = /^(cpu\d+)\s+([0-9 ]+)$/.exec(line.trim());
		if (match) result[match[1]] = match[2].trim().split(/\s+/).map(Number);
	}
	return result;
}

function tableCounters(text) {
	const lines = text.split(/\r?\n/).filter(Boolean);
	if (!lines.length) return { cpus: [], rows: {} };
	const cpus = (lines[0].match(/CPU\d+/g) || []).map((cpu) => Number(cpu.slice(3)));
	const rows = {};
	for (const line of lines.slice(1)) {
		const match = /^\s*([^:]+):\s*(.*)$/.exec(line);
		if (!match) continue;
		const values = match[2].trim().split(/\s+/).slice(0, cpus.length).map((value) => {
			const parsed = Number(value);
			return Number.isFinite(parsed) ? parsed : null;
		});
		if (values.length === cpus.length) rows[match[1].trim()] = values;
	}
	return { cpus, rows };
}

function softnetCounters(text) {
	return text.split(/\r?\n/).filter(Boolean).map((line) =>
		line.trim().split(/\s+/).map((value) => {
			const parsed = Number.parseInt(value, 16);
			return Number.isFinite(parsed) ? parsed : null;
		})
	);
}

function delta(before, after) {
	if (!Number.isFinite(before) || !Number.isFinite(after) || after < before) return null;
	return after - before;
}

function sum(values) {
	return values.reduce((total, value) => total + (Number.isFinite(value) ? value : 0), 0);
}

function cpuSummary(beforeText, afterText) {
	const before = cpuCounters(beforeText);
	const after = cpuCounters(afterText);
	const result = {};
	for (const cpu of Object.keys(before)) {
		if (!after[cpu] || before[cpu].length !== after[cpu].length) continue;
		const changes = before[cpu].map((value, index) => delta(value, after[cpu][index]));
		if (changes.some((value) => value === null)) continue;
		const idle = (changes[3] || 0) + (changes[4] || 0);
		// Linux user/nice counters already include guest/guest_nice fields.
		const total = sum(changes.slice(0, 8));
		const busy = total - idle;
		result[cpu] = {
			total_ticks: total,
			busy_ticks: busy,
			busy_pct: total > 0 ? Number((100 * busy / total).toFixed(3)) : null,
			user_ticks: changes[0] || 0,
			system_ticks: changes[2] || 0,
			irq_ticks: changes[5] || 0,
			softirq_ticks: changes[6] || 0,
			steal_ticks: changes[7] || 0
		};
	}
	return result;
}

function interruptSummary(beforeText, afterText) {
	const before = tableCounters(beforeText);
	const after = tableCounters(afterText);
	const byCpu = {};
	const byInterrupt = {};
	for (const [name, previous] of Object.entries(before.rows)) {
		const current = after.rows[name];
		if (!current || current.length !== previous.length) continue;
		const changes = previous.map((value, index) => delta(value, current[index]));
		if (changes.some((value) => value === null)) continue;
		byInterrupt[name] = changes;
		changes.forEach((value, index) => {
			const cpu = `cpu${before.cpus[index]}`;
			byCpu[cpu] = (byCpu[cpu] || 0) + value;
		});
	}
	return { by_cpu: byCpu, by_interrupt: byInterrupt };
}

function softirqSummary(beforeText, afterText) {
	return interruptSummary(beforeText, afterText);
}

function softnetSummary(beforeText, afterText) {
	// Linux net/core/net-procfs.c (v6.6, v6.12, v6.17): only the
	// first three fields here are monotonic counters. Later fields include
	// backlog gauges and an explicit CPU ID; a falling gauge is not a reset.
	const keyed = (text) => new Map(softnetCounters(text).filter((row) => row.length >= 3)
		.map((row, index) => [row.length >= 13 && Number.isInteger(row[12]) ? row[12] : index, row]));
	const before = keyed(beforeText);
	const after = keyed(afterText);
	const perCpu = [];
	for (const [cpu, previous] of before) {
		const current = after.get(cpu);
		if (!current) continue;
		const changes = previous.slice(0, 3).map((value, index) => delta(value, current[index]));
		perCpu.push({
			cpu: `cpu${cpu}`,
			cpu_mapping: previous.length >= 13 ? 'explicit CPU ID (column 13)' : 'legacy row order',
			processed: changes[0],
			dropped: changes[1],
			time_squeeze: changes[2],
			counter_deltas: changes,
			counter_reset_or_wrap: changes.some((value) => value === null),
			raw_before: previous,
			raw_after: current
		});
	}
	return { per_cpu: perCpu };
}

function wcSummary(text) {
	const match = /^\s*(\d+)\s+(\d+)/.exec(text);
	return match ? { lines: Number(match[1]), bytes: Number(match[2]) } : null;
}

function printkPolicy(text) {
	const values = text.trim().split(/\s+/).map(Number);
	return values.length >= 4 && values.slice(0, 4).every(Number.isFinite)
		? { console_loglevel: values[0], default_message_loglevel: values[1], minimum_console_loglevel: values[2], default_console_loglevel: values[3] }
		: null;
}

function scopeSummary(before, after) {
	const beforeProc = sections(before);
	const afterProc = sections(after);
	const beforeDmesg = wcSummary(beforeProc.dmesg_ring || '');
	const afterDmesg = wcSummary(afterProc.dmesg_ring || '');
	const beforeConsole = /^bytes=(\d+)/m.exec(beforeProc.console_log || '');
	const afterConsole = /^bytes=(\d+)/m.exec(afterProc.console_log || '');
	const consoleDelta = beforeConsole && afterConsole
		? delta(Number(beforeConsole[1]), Number(afterConsole[1]))
		: null;
	return {
		identity: beforeProc.identity || null,
		busybox_banner: beforeProc.busybox_banner || null,
		package_manager: beforeProc.package_manager || null,
		installed_source_hashes: beforeProc.source_hashes || null,
		cmdline: beforeProc.cmdline || null,
		cpu_affinity_before: beforeProc.affinity || null,
		cpu_affinity_after: afterProc.affinity || null,
		guest_cpu_online: beforeProc.cpu_online || null,
		guest_irq_affinity: beforeProc.irq_affinity || null,
		console_policy: {
			before: printkPolicy(beforeProc.printk || ''),
			after: printkPolicy(afterProc.printk || ''),
			qemu_console_log_bytes_before: beforeConsole ? Number(beforeConsole[1]) : null,
			qemu_console_log_bytes_after: afterConsole ? Number(afterConsole[1]) : null,
			qemu_console_log_bytes_delta: consoleDelta,
			qemu_console_log_available: !!(beforeConsole && afterConsole && consoleDelta !== null),
			dmesg_ring_before: beforeDmesg,
			dmesg_ring_after: afterDmesg,
			dmesg_ring_is_occupancy_not_emitted_volume: true
		},
		memory_before: beforeProc.meminfo || null,
		memory_after: afterProc.meminfo || null,
		devices: beforeProc.devices || null,
		devices_after: afterProc.devices || null,
		cpu_per_core: cpuSummary(beforeProc.proc_stat || '', afterProc.proc_stat || ''),
		interrupts: interruptSummary(beforeProc.interrupts || '', afterProc.interrupts || ''),
		softirqs: softirqSummary(beforeProc.softirqs || '', afterProc.softirqs || ''),
		softnet: softnetSummary(beforeProc.softnet_stat || '', afterProc.softnet_stat || '')
	};
}

export function summarizeTelemetry({ hostBefore, hostAfter, guestBefore, guestAfter }) {
	return {
		host: scopeSummary(hostBefore, hostAfter),
		guest: scopeSummary(guestBefore, guestAfter),
		raw_snapshots: { host_before: hostBefore, host_after: hostAfter, guest_before: guestBefore, guest_after: guestAfter }
	};
}

if (process.argv[1] && process.argv[1] === new URL(import.meta.url).pathname) {
	const [hostBeforeFile, guestBeforeFile, hostAfterFile, guestAfterFile] = process.argv.slice(2);
	if (![hostBeforeFile, guestBeforeFile, hostAfterFile, guestAfterFile].every(Boolean)) {
		console.error('usage: fwlive-forwarding-slo-telemetry.mjs HOST-BEFORE GUEST-BEFORE HOST-AFTER GUEST-AFTER');
		process.exit(2);
	}
	const read = (file) => fs.readFileSync(file, 'utf8');
	console.log(JSON.stringify(summarizeTelemetry({
		hostBefore: read(hostBeforeFile),
		guestBefore: read(guestBeforeFile),
		hostAfter: read(hostAfterFile),
		guestAfter: read(guestAfterFile)
	})));
}

#!/usr/bin/env node
'use strict';

function parseKeyValueLog(message) {
	const out = {};
	const re = /\b([A-Z]+)=([^\s]+)/g;
	let match;
	while ((match = re.exec(message)) !== null)
		out[match[1]] = match[2];
	return out;
}

const line = 'fw4: DROP IN=br-lan OUT=eth0 SRC=10.0.0.2 DST=1.1.1.1 PROTO=TCP SPT=49999 DPT=443 MARK=0x1';
const loops = 200000;
const start = Date.now();
for (let i = 0; i < loops; i++)
	parseKeyValueLog(line);
const elapsed = Date.now() - start;
const rate = Math.round((loops / elapsed) * 1000);

console.log(`parsed ${loops} rows in ${elapsed}ms (${rate} rows/sec)`);

#!/usr/bin/env node
'use strict';

const core = require('../core/fwlive-log.js');

const line = 'fw4: DROP IN=br-lan OUT=eth0 SRC=10.0.0.2 DST=1.1.1.1 PROTO=TCP SPT=49999 DPT=443 MARK=0x1';
const entry = { time: 1717675740, msg: line };
const loops = 200000;
const start = Date.now();

for (let i = 0; i < loops; i++) {
	core.parseKeyValueLog(line);
	core.isFirewallEvent(entry);
}

const elapsed = Date.now() - start;
const rate = Math.round((loops / elapsed) * 1000);

console.log(`parsed+classified ${loops} rows in ${elapsed}ms (${rate} rows/sec)`);

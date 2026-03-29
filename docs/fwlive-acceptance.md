# Firewall Live View Acceptance Criteria

## Functional

- Live view refresh interval is approximately one second.
- New firewall log lines appear without page reload.
- Filters apply immediately for action/interface/protocol/src/dst/ports.
- Quick search matches across all normalized fields.
- URL hash preserves active filters on reload.

## Performance

- Parser benchmark target: >= 100k rows/sec on development host.
- Browser render cap: 200 visible rows to keep UI responsive.
- History cap: 2000 rows in memory.
- Typical update processing stays under one second poll interval.

## Validation commands

- Parser test: `node tests/fwlive-parser-filter.test.js`
- Parser benchmark: `node tests/fwlive-parser-bench.js`

# Firewall Live View Acceptance Criteria

## Functional

- Live view refresh interval is approximately one second.
- New firewall log lines appear without page reload.
- Only firewall-shaped `log.read` lines are shown (stage 1).
- Normalized schema: unix `timestamp`, `action` enum, `interface_in`/`out`, `flags`, `length` (stage 2).
- Filters apply immediately for action/interface/protocol/src/dst/ports.
- Quick search matches across all normalized fields.
- URL hash preserves active filters on reload.

## Performance

- Parser benchmark target: >= 100k rows/sec on development host.
- Browser render cap: 200 visible rows to keep UI responsive.
- History cap: 2000 rows in memory.
- Typical update processing stays under one second poll interval.

## Environment

Full loop on **Linux x86_64**: [`dev-environment.md`](dev-environment.md). Enable firewall **`log`**: [`fwlive-nft-logging.md`](fwlive-nft-logging.md).

## Validation commands (no browser)

```sh
./scripts/fwlive-test.sh
node core/fwlive-log.js stats < tests/fixtures/logread-mixed.json
node core/fwlive-log.js filter < tests/fixtures/logread-mixed.json
./scripts/fwlive-ubus-read.sh --stats    # live guest over SSH
```

Stage plan: [`fwlive-development-plan.md`](fwlive-development-plan.md).

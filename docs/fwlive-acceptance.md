# Firewall Live View Acceptance Criteria

## Functional

- Live view refresh interval is approximately one second.
- New firewall log lines appear without page reload.
- Only firewall-shaped `log.read` lines are shown (stage 1).
- Normalized schema: unix `timestamp`, `action` enum, `interface_in`/`out`, `flags`, `length` (stage 2).
- Filters apply immediately for action/interface/protocol/src/dst/ports.
- Quick search matches across all normalized fields.
- URL hash preserves active filters on reload.
- **Auto-refresh** checkbox freezes the table while polling continues; re-check updates the grid (stage 4b).
- **Limit** dropdown (25…2000, default 100) caps buffer and visible rows; persisted in browser (stage 4b).
- **Rule labels** resolve UCI/fw4 names via `ubus fwlive rules` (stage 3.4b); test rule `fwlive-ping` falls back to cosmetic label.
- **Filter operators:** prefix `!` for is-not / not-contains; action dropdown includes **not pass**, **not drop**, etc. (stage 5.6).
- **Flood banner** appears under high ingest rate only (token bucket charges new events per poll, not full row count).

## Performance

- Parser benchmark target: >= 100k rows/sec on development host.
- Browser render cap: ~250 new events/sec before throttle banner; normal 1 pkt/s must not trigger it.
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
./scripts/fwlive-rules-ubus.sh           # rule hint → label map (stage 3.4b)
```

## LuCI smoke (feature completion, pre-backport)

```sh
./scripts/fwlive-nft-ping-log.sh add --ssh
ssh -p 2222 root@127.0.0.1 'ping 127.0.0.1'   # 1 pkt/s baseline
# http://localhost:8080/cgi-bin/luci/admin/status/fwlive
```

| Check | Pass |
| ----- | ---- |
| Rule column shows **fwlive ping** (or UCI name when resolvable) | |
| Action **not pass** hides green pass rows | |
| Src **!127.0.0.1** excludes loopback pings | |
| Limit 250 + 1 pkt/s: **no** flood banner | |
| `ping -A 127.0.0.1`: flood banner appears, UI stays responsive | |
| Uncheck auto-refresh: ingest count rises ~1/s | |

Stage plan: [`fwlive-development-plan.md`](fwlive-development-plan.md).

# Forwarding-SLO evidence

This directory preserves the raw JSON reports produced by the reusable
forwarding-SLO harness. The reports use `fwlive-forwarding-slo/v1` and retain
every pair and sample; the harness report is the durable measurement record.

## Larger-guest controlled qualification (#1134)

The [corrected-prefix high-rate evidence](2026-10-02-highrate/README.md)
records seven passing five-pair 10 Gb/s virtual forwarding cohorts: adaptive
ON/OFF at 2 and 8 vCPUs on 24.10.8, an 8-vCPU adaptive-ON repeat on 25.12.5,
and an 8-vCPU ON/OFF higher-logging browser point. It retains exact tuples,
raw reports, controller pressure/recovery, a latency outlier, and four
single-pair 80 Gb/s-cap boundary screens. Those screens achieved approximately
23–40 Gb/s and do not qualify 80 Gb/s or physical 64-core hardware.
The e1000 records below remain separate historical evidence.

## Supported x86 qualification point

The canonical x86_64 OpenWrt 24.10.8 QEMU/e1000 routed topology used two
traffic namespaces, 10-second iperf3 windows, 20 pings per sample, 25 logged
firewall messages per second per direction, and five no-viewer/active-viewer
pairs for each adaptive mode. All active-viewer polls succeeded and drained.

| adaptive | median throughput degradation | spread | median ping-stddev ratio | spread | result |
|---|---:|---:|---:|---:|---|
| on | 0.022% | 0.118 percentage points | 1.068x | 0.564x | pass |
| off | 0.042% | 0.138 percentage points | 1.085x | 1.836x | pass |

The raw records are [`adaptive-on`](x86-24.10.8-100M-adaptive-on.json) and
[`adaptive-off`](x86-24.10.8-100M-adaptive-off.json). These are controlled
100M forwarding-impact results, not line-rate capacity claims.

## Boundary runs

- The x86 125M five-pair extension was unstable: the first two pairs completed,
  then a later baseline lost ping packets. The one-pair 125M smoke report is
  retained as [`125M smoke`](x86-24.10.8-125M-adaptive-on-smoke.json), not as
  qualification evidence.
- The x86 1G probe exceeded the emulated forwarding path and failed closed
  rather than producing a qualification result.
- The armsr TCG run is a separate limitation signal: under the recorded load,
  viewer polling slowed to roughly 3–5 seconds rather than nominal 1 Hz. It is
  not substituted for the x86 controlled result.

See the [QEMU lab runbook](../../docs/developer/qemu-lab.md) and issue [#344](https://github.com/lucas-albers-lz4/fwlive/issues/344)
for setup, validity gates, and interpretation.


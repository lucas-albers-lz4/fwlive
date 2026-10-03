# Larger-guest forwarding and adaptive evidence (#1134)

These results extend the historical 100 Mb/s e1000 qualification with controlled
10 Gb/s virtual forwarding on virtio/kernel-vhost. The owner's final target is
**80 Gb/s (10 GB/s)** on a larger firewall. Neither the virtual path nor these
8-vCPU guests establish physical 80 Gb/s or 64-core hardware capacity.

## Source and reproducibility

Product source is the merged baseline
`8cafd441696449293b75cff1d71d22598fa83983`. Both actual packages were rebuilt
from that source, installed using artifact-only mode, and their installed
rpcd/adaptive helper hashes verified. They retain development version
`0.1.50-r1`; they are **not** the published v0.1.50 artifacts.

| artifact | SHA-256 |
|---|---|
| 24.10.8 IPK | `c1db476f1b4a9541cc87946def45993647a841257be89f4ce2c7a4a4933dae22` |
| 25.12.5 APK | `f1935860a60f2c1787860f7d776a1890c2b8bd29064d00a111070b6f7c9d716a` |

Installed rpcd SHA-256 is
`d2513f5851914756aa1f1b12b16effd794bf2580823f17966383e3a3f5e79a48`;
adaptive helper SHA-256 is
`5a893dfa0b879fb28e418dadc4f4505de4a3afefc3d189f8e6b6244b33ec255f`.
Prepared backing images have hashes in `provenance.json`; the experiments use
private writable QCOW2 overlays, not modifications to those bases.

Host: Ryzen 7 5800X, 8 physical cores/16 SMT threads, 32 GiB, one NUMA node,
Linux 6.17, QEMU 8.2.2/KVM, iperf3 3.22. One guest at a time, q35/host CPU,
1 GiB guest RAM. OpenWrt 24.10.8 uses kernel 6.6.144 and BusyBox 1.36.1-r3;
25.12.5 uses kernel 6.12.94 and BusyBox 1.37.0-r6. Traffic uses two routed
endpoint namespaces and virtio TAPs with kernel vhost, separate from SLIRP
management. CPU placement is unpinned. Generator, receiver, QEMU and browser
share this host. Offloads remain enabled; coalesced packets are not wire-size
Ethernet packets. Rates are receiver TCP bits/s, not physical-link capacity
or loss-free UDP packet-rate qualification.

Every qualified cohort uses five paired 10-second no-viewer/actual-LuCI-viewer
windows, 20 routed pings/window and a 3-second request drain. Primary cohorts
use one observed stream and one actual RX/TX queue/interface, 25 logged
packets/s/direction, a 128 KiB logd ring and `kernel.printk=4 4 1 7`.
The console threshold is a lab control: warnings remain in logd. It is restored
to the saved threshold after each cohort. Adaptive OFF→ON order at 2 vCPUs and
ON→OFF at 8 vCPUs counterbalance order without multiplying the matrix.

The first five cohorts and direct pressure/recovery probes use instrumentation
revision `e2b1e37eee1f8e9293b557fc347724e75e05f84c`. Their observed poll counts
match retained response counts, and native CPU maps contain every assigned
guest core and all 16 host logical CPUs. Subsequent browser-pressure and queue
probes use the post-review instrumentation revision recorded in each report.
Those revisions await body parsing through drain and retain aborted work.
No result is silently relabeled as a replay of a newer harness.

## Five-pair tested envelope

All rows below pass every gate in their recorded harness revision: complete
pairs, valid traffic with zero ping loss, retained iperf/ping/counter inputs,
observed successful viewer polls, full drain, <10% median forwarding degradation
and <2x median ping-standard-deviation ratio. Newer-harness rows additionally
check response-body parsing drain. Across the seven cohorts, receiver medians
are approximately 9.9996–9.9998 Gb/s. Requested browser budget is 400 raw lines;
returned rows are firewall entries after filtering, not raw input lines.

| report | logs/s/direction; ring | degradation median | ping-SD ratio median | actual polls | poll latency median | returned rows; effective cap |
|---|---|---:|---:|---:|---:|---|
| [paired-24-2-off-10G](paired-24-2-off-10G.json.gz) | 25; 128 KiB | 0.000120% | 1.079x | 50 | 468 ms | 393–400; OFF |
| [paired-24-2-on-10G](paired-24-2-on-10G.json.gz) | 25; 128 KiB | 0.000397% | 0.825x | 25 | 878 ms | 193–400; 200/400 |
| [paired-24-8-off-10G-pressure](paired-24-8-off-10G-pressure.json.gz) | 250; 1024 KiB | 0.000073% | 0.922x | 50 | 417.5 ms | 393–400; OFF |
| [paired-24-8-off-10G](paired-24-8-off-10G.json.gz) | 25; 128 KiB | 0.000401% | 0.925x | 50 | 414 ms | 393–400; OFF |
| [paired-24-8-on-10G-pressure](paired-24-8-on-10G-pressure.json.gz) | 250; 1024 KiB | -0.000264% | 0.816x | 25 | 818 ms | 400–400; 400 |
| [paired-24-8-on-10G](paired-24-8-on-10G.json.gz) | 25; 128 KiB | 0.000253% | 0.862x | 25 | 820 ms | 393–400; 400 |
| [paired-25-8-on-10G](paired-25-8-on-10G.json.gz) | 25; 128 KiB | 0.000488% | 0.929x | 25 | 791 ms | 393–400; 400 |

Filename numbers identify release/vCPUs; every row uses 1 GiB, one active queue
and one observed stream. Adaptive ON uses summary responses and 2-second polling
in these runs; OFF uses table responses and 1-second polling. This comparison
changes summary work, cadence, and sometimes delivered work, so it does not
isolate controller overhead. At the higher logging point, ON returned 400 rows
in all 25 responses; eight carried hot/shed and truncated flags. OFF made 50
polls, returning 393–400 rows. Hot/shed flags include prior-state/cooldown
information and can occur without reducing that response's 400-row count;
flags alone do not establish lost log messages. The visible tradeoff is cadence
and bounded requested/returned work, not complete event capture.

The 25.12.5 primary repeat includes a tail: pair 3 active-viewer ping stddev
0.339 ms versus 0.046 ms baseline (7.37x), with 1,044 retransmits, zero ping loss,
and preserved receive rate. Median gates pass, but every individual pair did
not stay below 2x. One pressure-ON pair has 61 baseline retransmits versus zero in its viewer half.
These samples are retained, not removed or rerun away.

Every captured guest core and all 16 host logical cores are present. No guest
softnet drops/time-squeeze increments occurred in these qualified cohorts;
host counters also show zero drops/squeeze. Minimum captured guest MemAvailable
is 866 MiB, including pressure samples. This is headroom evidence, not peak
RSS or leak qualification. It gives no measured reason to add the optional
2 GiB sizing point. Host CPU counters describe the whole host; they do not
attribute browser, QEMU/vhost, generator, or receiver cost independently.

## Real-log pressure and recovery

Each release has one concurrent 60-second 10 Gb/s backend pressure probe:
8 vCPUs, 1 GiB, one stream/queue, 250 logged packets/s/direction and a 1 MiB ring.
OFF runs before ON; four serialized 2,000-line calls per mode complete while
traffic runs. Both retain valid TCP receive near 9.99995 Gb/s, all 20 pings,
and correct `fwlive-slo IN=` logs, with no malformed prefix.

| release | first ON guest processing; rows | following guest processing; raw cap / rows | explicit drained recovery |
|---|---|---|---|
| [24.10.8](pressure-24-8.json.gz) | 3520 ms; 1992 | 420/240/250 ms; 250/125/125 / 248/123/123 | 250→500→1000→2000, then cold/full cap |
| [25.12.5](pressure-25-8.json.gz) | 3620 ms; 1992 | 430/210/260 ms; 250/125/125 / 248/123/123 | 250→500→1000→2000, then cold/full cap |

The concurrent 60-second traffic probes retain 339 TCP retransmits on 24.10.8
and zero on 25.12.5; both have zero routed ping loss.

The helper records guest processing separately from host SSH wall time. Faster
follow-ups process fewer lines; they are not an equal-work speedup over OFF,
which omits adaptive summary work. Correct-prefix row counts, source-ID ranges,
duplicates and within-response gaps are retained in `pressure-visibility.json`.
ID gaps can include filtered background entries and do not independently
attribute rate-limit suppression, ring overwrite, or browser eviction.

After traffic stops, historic logd work still keeps the controller warm/capped.
Recovery above follows an **explicit logd drain**, not a claim that idle traffic
clears the ring. Empty-address resolve calls are suppressed with `disabled=load`
after hot induction and allowed again after recovery; these prove the load
guard, not successful real DNS resolution. Ring size returns to 128 KiB,
console threshold to `7 4 1 7`, and adaptive override/state is restored/cleared.

## 80 Gb/s cap boundary: screening only

Each cell is one paired 20-second screen at 8 vCPUs/1 GiB, logging 25/s/direction,
128 KiB ring, console threshold 4, with actual streams and guest active channels
verified. A configured TCP cap does not prove the endpoints actually offered
80 Gb/s. Generic one-pair relative SLO `pass` is not five-pair or configured-rate
attainment qualification.

| actual queues / streams | no-viewer receive | viewer receive | relative degradation | retransmits baseline / viewer | relative one-pair gate |
|---|---:|---:|---:|---:|---|
| [1 / 1](diagnostic-24-8-q1-p1-80G.json.gz) | 39.960 Gb/s | 22.806 Gb/s | 42.93% | 40 / 33 | fail |
| [1 / 4](diagnostic-24-8-q1-p4-80G.json.gz) | 37.882 Gb/s | 38.991 Gb/s | -2.93% | 509 / 2418 | pass |
| [4 / 1](diagnostic-24-8-q4-p1-80G.json.gz) | 35.461 Gb/s | 26.671 Gb/s | 24.79% | 136 / 0 | fail |
| [4 / 4](diagnostic-24-8-q4-p4-80G.json.gz) | 37.574 Gb/s | 37.650 Gb/s | -0.20% | 555 / 4605 | pass |

All four cells have zero ping loss and valid tool output, but none sustains the
80 Gb/s cap. Both one-stream screens fail the relative forwarding gate;
multiqueue alone does not resolve that signal. Four streams hold approximately
38–39 Gb/s with large viewer retransmission tails. No guest softnet drop/squeeze
increments were observed. These cells run once and are nonmonotonic; they do
not establish a scaling curve, independent generator capacity, or product
causality. Shared host resources, placement, QEMU/vhost and endpoint cost remain
confounded. We stop the 2x2 matrix here rather than add speculative optimizations.

## Decision and next work

The tested envelope is controlled virtual 10 Gb/s at the exact tuples above.
Existing adaptive behavior sheds real 2,000-line work, preserves the indicated
limited visibility and resolution guard, and recovers after the explicit drain.
No production controller, classifier, threshold, UCI default, parser rewrite,
or additional daemon is justified by this evidence. The filter stage remains
dominant in the existing fixture stage probes; those and C1 flood controls are
retained in `controls-and-smokes.json.gz`, with the older v0.1.50 screening in
`historical-screening.json.gz`. Fixture and real-log observations remain separate.

Before raising the supported rate, isolate the one-stream viewer interference
with independently capable endpoints and explicit CPU/process attribution,
then qualify a fixed sustainable rate with five pairs per mode. Physical target
work needs a separately identified NIC/link/NUMA/CPU topology, a link budget
above 80 Gb/s payload plus overhead, actual queue activation, placement and
offload/log-visibility comparisons. Check small-packet PPS and the owner's
logging policy, then single/multiple operator work if that deployment needs it.
The 64-core/80-Gb/s target remains unqualified; extra vCPUs or a new aggregate
CPU controller are not inferred remedies. Deferred/rejected #308 alternatives
retain their original measurement triggers.

## Durable records and replay

`manifest.json` records compressed and uncompressed SHA-256 and sizes for every
gzip JSON artifact. Reports embed raw client/server iperf JSON, ping output and
all four pre/post counter snapshots per sample, plus each poll observation.
Use `gzip -dc REPORT.json.gz | jq` to inspect them and `report-summary.json` for
a compact index; recompute from the raw records when reviewing a new claim.
`provenance.json` pins source/package/backing-image identities and limits.

`reproduction-scripts.json.gz` retains the exact one-off environment and driver
recipes, including the direct pressure probe. Substitute owned local paths;
do not reuse somebody else's QEMU pidfile, namespaces or writable image.
The supported helpers remain those in the [QEMU runbook](../../../docs/developer/qemu-lab.md).
Build/install the pinned actual package in a prepared guest, use a private
QCOW2 overlay, source matching backend controls before topology setup/launch,
configure/check guest rules, then run, for example:

```sh
FWLIVE_URL=http://127.0.0.1:13080 \
FWLIVE_SLO_IPERF3=/path/to/iperf3 \
./scripts/qemu-forwarding-slo-run.sh --adaptive on --pairs 5 \
  --bitrate 10G --duration 10 --report-file /owned/path/report.json
```

Restore the saved ring and override, run guest cleanup, stop the selected guest
and tear down the same owned topology. Final restoration records prove the
owned resources were removed. No guest images, package binaries, passwords,
private keys or browser-session captures are included. The sanitized 25.12
bootstrap diagnostic retains the stock LuCI access-error scope separately
from successful measured fwlive polls. Aborted harness runs preserve a private
work path; successful reports contain their evidence before temporary cleanup.

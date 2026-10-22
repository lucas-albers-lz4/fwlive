"""Recompute paired descriptive statistics; no population reliability inference."""
import gzip
import hashlib
import json
from pathlib import Path
import statistics

root = Path(__file__).resolve().parents[4]
folder = root / 'lab/forwarding-slo/2026-10-02-highrate'
result = []
for p in sorted(folder.glob('paired-*.json.gz')):
    data = json.loads(gzip.decompress(p.read_bytes()))
    pairs = data['pairs']
    degradation = [x['throughput_degradation_pct'] for x in pairs]
    jitter = [x['ping_stddev_ratio'] for x in pairs]
    metadata = data.get('metadata')
    if metadata:
        # The raw source records a temporary console-log path that is not part
        # of the retained evidence. Keep all other source metadata unchanged.
        metadata = json.loads(json.dumps(metadata))
        metadata.get('traffic_configuration', {}).pop('console_log_path', None)
    result.append(dict(file=p.name, sha256=hashlib.sha256(p.read_bytes()).hexdigest(),
                       pairs=len(pairs),
                       degradation_median_pct=statistics.median(degradation),
                       degradation_max_pct=max(degradation),
                       ping_sd_ratio_median=statistics.median(jitter),
                       ping_sd_ratio_max=max(jitter),
                       pairs_ping_sd_ratio_ge_2=sum(x >= 2 for x in jitter),
                       observed_pings_per_window=20,
                       metadata=metadata,
                       summary_matches=(statistics.median(degradation) == data['throughput_degradation_pct']['median']
                                        and statistics.median(jitter) == data['ping_stddev_ratio']['median'])))
(Path(__file__).with_name('load-recomputed.json')).write_text(json.dumps(result, indent=2) + '\n')
for x in result:
    print(json.dumps({k:v for k,v in x.items() if k not in ('metadata', 'sha256')}))

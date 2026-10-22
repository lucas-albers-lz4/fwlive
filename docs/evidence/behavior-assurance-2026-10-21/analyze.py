"""Reproduce census and material-review accounting from retained inputs."""
from collections import Counter
import gzip
import json
from pathlib import Path

here = Path(__file__).resolve().parent
snapshot = json.loads(gzip.decompress((here / 'tracker-snapshot.json.gz').read_bytes()))
rows = snapshot['issues']
history = json.loads((here / 'history.json').read_text())
by = {x['number']: x for x in history}
assert len(by) == len(history) == len(rows)
assert set(by) == {x['number'] for x in rows}
bugs = [x for x in rows if 'bug' in x['labels']]
full_bug = []
for row in bugs:
    material = by[row['number']]['reviewed_material'].lower()
    assert material and not any(s in material for s in ('partial', 'screen', 'excerpt', 'missing')), row['number']
    full_bug.append(row['number'])
days = Counter(x['created_at'][:10] for x in bugs)
prefixes = ('test:', 'test ', 'ci:', 'test/', 'docs/test', 'test(codegen)')
summary = dict(
    source_pin=snapshot['source_pin'], issues=len(rows), bugs_by_current_label=len(bugs),
    issue_comments=sum(len(x['comments']) for x in rows),
    bug_issue_comments=sum(len(x['comments']) for x in bugs),
    full_material_bug_reviews=len(full_bug),
    current_bug_states=dict(Counter(x['state_reason'] for x in bugs)),
    reporting_days_largest=days.most_common(10),
    five_largest_days=sum(n for _, n in days.most_common(5)),
    bug_test_ci_title_prefixes=sum(x['title'].lower().startswith(prefixes) for x in bugs),
    analyst_classes_all=dict(Counter(x['kind'] for x in history)),
    analyst_classes_bug_label=dict(Counter(by[x['number']]['kind'] for x in bugs)),
    included_report_rows=sum(x['include_in_defect_history'] for x in history),
    included_report_rows_outside_bug_label=sum(x['include_in_defect_history'] and
                                              not x['bug_label_at_snapshot'] for x in history),
    caveat='Analyst report classes and dispositions are not unique defects, current defects, rates, or probabilities.')
(here / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps(summary, indent=2))

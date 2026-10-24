# Prevention ledger

`weekly-development-review` owns the scheduled retrospective cadence; the prevention ledger supplies its authoring-quality inputs.
`data/prevention-ledger/SCHEMA.md` owns the row shape and taxonomy, and `data/prevention-ledger/RUNBOOK.md` owns the exact 30-minute weekly scope.

## What this cadence reads

The weekly review's prevention half reads only ledger rows observed since the previous review.
It reports category deltas, control effectiveness, and exactly one action, and nothing else.
Thread-level evidence from stored development threads stays the review's other half and is unaffected.

## Commands

```
bin/fm-prevention-ledger.py backfill --ledger data/prevention-ledger/runs.jsonl
bin/fm-prevention-ledger.py validate --ledger data/prevention-ledger/runs.jsonl
bin/fm-prevention-ledger.py stats --since <previous review epoch>
```

## Rules the review must not skip

- Compare against the previous week's shares with the denominator in view, and refuse to call a category improved on one cycle.
- Report adoption of each shipped control before reporting its category share; an unexercised control cannot have moved anything.
- Keep escaped defects out of the scorecard until something links a merged PR to a later defect. Reporting zero would be a fabricated improvement.
- Route any new control decision to the maintenance roadmap skill, which owns the control set and its cap.

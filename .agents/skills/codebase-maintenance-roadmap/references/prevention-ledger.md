# Prevention ledger

The prevention ledger is the evidence store for the maintenance program's preventive half.
It records one row per terminal no-mistakes run: findings by fixed category, ask-user decisions, fix commits, CI result, rounds, and wall time.
`data/prevention-ledger/SCHEMA.md` owns the row shape and the eight-category taxonomy, and `data/prevention-ledger/RUNBOOK.md` owns the review cadence.

## Use it when auditing for maintenance value

A whole-repository audit that only looks at the current tree misses the cheapest finding class: defects the review pipeline keeps re-reporting.
Before proposing cleanup workstreams, read the category mix and the top causes in `data/prevention-ledger/catch-up-2026-10-24.md`.
A recurring category with an existing control is a candidate for verifying the control, not for a new workstream.
A category with no control and at least three observed findings is a candidate for exactly one control from the allowed set: a brief-scaffold checklist line, a deterministic pre-flight validator, a fixture, or a plan lint.

## Commands

```
bin/fm-prevention-ledger.py backfill    # append terminal runs not yet in the ledger
bin/fm-prevention-ledger.py export <task>
bin/fm-prevention-ledger.py validate    # row schema, taxonomy, idempotency key
bin/fm-prevention-ledger.py stats --since <epoch>
bin/fm-brief-preflight.py --brief <brief> --project <checkout>
```

`backfill` is idempotent on `(project, run_id)`, and `validate` refuses a finding outside the taxonomy or a null category without its recorded gap token.

## Boundaries

- The ledger never stores a finding description, so it holds no review prose.
- Classification is a reviewed table, `classifications.tsv`; no model call classifies a finding.
- Environment failures are recorded per run and are never counted as authoring defects.
- This skill adds no dashboard, database, or service.

# Slice plan

Inherits `PLAN_TEMPLATE.md`: every required section applies unchanged. A slice plan is the
default kind (`plan_kind: slice`) and the one `bin/fm-plan-lint.py` was written against.

A slice is the smallest unit that produces an observable outcome on its own. It is not the
smallest unit that compiles, and it is not a milestone. If two slices can land in either
order with no code change between them, they are one slice; if one slice needs another's
table to exist first, it is a separate slice with a `depends_on` entry.

## What a slice plan adds

### `## Slice boundary`

**Instruction.** State what this slice covers by naming the stage or seam it starts and ends
at, then list what is deliberately in the next slice. This is where a reader checks that the
slice is independently shippable and that its acceptance does not depend on work in a later
slice.

**Example.**

- Starts at: a decided job row exists with `p_fit` still NULL.
- Ends at: every decided job in one bounded batch has a persisted `p_fit` and `model_rank`.
- Next slice (`example-evaluation-s2`): reads the persisted scores for ranking; nothing here depends on it.
- Explicitly not in this slice: calibration thresholds, review export, historical backfill.

## Slicing rules this template encodes

- One slice owns one observable outcome and one acceptance command set. `PL003` rejects a
  slice whose acceptance only says a later slice will prove it.
- One slice owns one schema change. Two `ALTER TABLE` statements in different slices need an
  ordered `depends_on` chain and a compatibility window in each plan's `Data and migration`.
- A slice that needs a flag turned on to be safe names the flag in `## Contracts` and its
  default in `## Rollout and rollback`.
- If `## Exact change list` exceeds the row limit for its `effort`, split the slice. Raising
  the effort instead is how a "small" task becomes a multi-round pipeline run (`PL006`).

## Front matter example

```yaml
---
plan_id: example-storage-s1
title: "Storage S1: persist scores for decided rows"
task: example-storage-s1
project: example-project
repo: projects/example-project
milestone: M1
slice: S1
owner: serving
status: draft
plan_kind: slice
depends_on: [example-storage-s0]
effort: M
parallel_safe: true
contracts:
  tables: [decisions]
  fields: [decisions.p_fit, decisions.model_rank]
  flags: []
  commands: [scripts/example/check_integrity.py]
finding_ids: ["01M59G7X5YW26CAQ0VCJJ948CM:duplicate-legacy-projection-repair"]
acceptance_commands:
  - id: A1
    command: pytest tests/example/test_runner.py -q
    expect: exit 0 and 6 passed
  - id: A2
    command: scripts/example/check_integrity.py --check scores
    expect: exit 0 and prints "0 mismatches"
rollback: Turn config/example-write-scores off, revert migration 030, and re-run A2 to confirm the schema reports 29.
declared_new_paths:
  - src/example/scores.py
---
```

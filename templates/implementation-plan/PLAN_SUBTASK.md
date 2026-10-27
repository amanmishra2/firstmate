# Subtask plan

Inherits `PLAN_TEMPLATE.md`. Use a subtask plan when one slice is too large to dispatch at
once but the parts are not independently shippable: a subtask lands inside its parent's
branch or immediately after it, and it must never widen the parent's objective.

Set `plan_kind: subtask`, keep the parent's `milestone`, and name the parent plan in
`depends_on` and in the `## Parent plan` section.

## What a subtask plan adds

### `## Parent plan`

**Instruction.** Name the parent `plan_id`, the parent sections this subtask implements, and
what it must not change. A subtask that edits a parent section it does not name is the
mechanism by which a reviewed plan quietly becomes a different change.

**Example.**

- Parent: `example-storage-s1` (persist scores for decided rows).
- Implements: the parent's `Exact change list` row 1 only - the writer in `run_batch`.
- Does not change: the parent's `Contracts` (no new table, field, or flag), the compatibility
  window, or the acceptance commands A1/A2, which stay the parent's proof of outcome.
- Lands: same PR as the parent, before the parent's A2 is run.

## Subtask rules

- The subtask's `## Acceptance criteria` must be runnable on its own. "The parent's acceptance
  covers it" fails `PL003`: a subtask whose only proof is the parent's outcome cannot be
  reviewed or reverted alone.
- `finding_ids` carries the findings this subtask answers, not the parent's whole list.
  A subtask with no finding of its own needs `evidence_note`.
- `effort: S` is allowed only when `depends_on` is empty: name the parent in
  `## Parent plan` and nothing in `depends_on`, and record that it lands with the parent. A
  subtask that must wait on the parent's plan lands first uses `effort: M` and puts the parent
  in `depends_on` (`PL006` rejects S with any dependency).
- A subtask that needs a dependency other than its parent is a slice, not a subtask.
- The parent's `Changelog` gets one line naming the subtask and its PR, so the parent stays
  the single record of what landed.

## Front matter example

```yaml
---
plan_id: example-storage-s1a-writer
title: "Storage S1a: write p_fit and model_rank in the verdict transaction"
task: example-storage-s1a-writer
project: example-project
repo: projects/example-project
milestone: M1
slice: S1
owner: serving
status: draft
plan_kind: subtask
depends_on: [example-storage-s1]
effort: M
parallel_safe: false
serial_reason: Edits the same run_batch transaction body as its parent slice, so the two cannot be in flight together.
contracts:
  tables: [decisions]
  fields: [decisions.p_fit]
  flags: []
  commands: []
finding_ids: ["01M59G7X5YW26CAQ0VCJJ948CM:duplicate-legacy-projection-repair"]
acceptance_commands:
  - id: A1
    command: pytest tests/example/test_runner.py -q -k transaction
    expect: exit 0 and 2 passed
rollback: Revert the writer hunk in src/example/runner.py only; the column and its migration stay, and A1 returns to 0 passed with 2 skipped.
declared_new_paths: []
---
```

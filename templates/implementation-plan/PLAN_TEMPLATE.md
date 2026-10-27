# Implementation plan template

Copy this file, keep the headings, replace every prompt with your own text, then run
`bin/fm-plan-lint.py path/to/PLAN.md` until it exits 0. You do not need to read the linter
source: a failure names the rule, the file and line, and what to write instead.

Two things make a plan dispatchable rather than merely descriptive:

1. Every acceptance criterion is a command with an expected result, written twice on
   purpose - once in `acceptance_commands` and once in `## Acceptance criteria`. The linter
   compares them, so the plan cannot drift from the command a reviewer runs.
2. Every section a review finding can land in exists before the work starts. `PL001` names
   the missing section, and `docs/plan-lifecycle.md` maps each finding category to the
   section it must update.

A plan that is real but not yet dispatchable is `status: draft`. The gate refuses a draft;
it accepts `ready`. Promoting a plan to ready is a deliberate edit by the named owner.

---

## Front matter

```yaml
---
plan_id: example-slice-plan
title: "Example slice: one sentence on the outcome"
task: example-task-id
project: example-project
repo: projects/example-project
milestone: M1
slice: S1
owner: your-name-or-role
status: draft
plan_kind: slice
depends_on: []
effort: M
parallel_safe: true
contracts:
  tables: []
  fields: []
  flags: []
  commands: []
finding_ids: []
evidence_note: "No prior finding applies: this plan opens a surface the ledger has never covered, checked against data/prevention-ledger/runs.jsonl on 2026-01-01."
acceptance_commands:
  - id: A1
    command: pytest tests/example/test_feature.py -q
    expect: exit 0 and 4 passed
  - id: A2
    command: bin/example-check --strict
    expect: exit 0 and prints "0 mismatches"
rollback: Revert the new module and its test, leave the existing table untouched, and re-run A1 to confirm the previous suite still passes.
declared_new_paths:
  - src/example/feature.py
  - tests/example/test_runner.py
---
```

`finding_ids` in a real plan looks like `["01M59G7X5YW26CAQ0VCJJ948CM:duplicate-legacy-projection-repair"]`
- one `<run_id>:<finding_id>` per prevention-ledger row that this plan answers.
When a run produced several findings, list each one separately.
`templates/implementation-plan/PLAN_SCHEMA.yaml` owns the field list, types, and which rule reads each field.

---

## Identity

**Instruction.** Restate the identity a reader needs without the front matter: the task, the
slice, the milestone, and the owner. Name the owner as the person or role who updates this
plan at every handoff in `docs/plan-lifecycle.md`.

**Example.**

| Field | Value |
| --- | --- |
| Task | `example-task-id` |
| Slice | S1 - the storage path only |
| Milestone | M1 |
| Owner | `serving` (updates this plan on every finding, PR, and merge) |

## Objective and non-goals

**Instruction.** One paragraph on the outcome, then an explicit non-goals list. A non-goal
is a thing a reasonable reader might expect and this plan deliberately does not do. If you
cannot name one, the slice is too big.

**Example.**

Objective: persist a calibrated score for every decided job so mining and review can read
it, without changing how a score is produced.

Non-goals:

- No change to the scoring model, its features, or its calibration.
- No change to the decision verdict; only the persisted columns are new.
- No backfill of historical rows beyond the bounded replay in `Data and migration`.

## Current-state evidence

**Instruction.** Every claim about today's behavior needs `path:line` from the project at a
named revision. State the revision once at the top of the section. A claim without a
reference is a guess and fails `PL007` when the path or line is stale.

**Example.**

Today's behavior cited from `projects/example-project` at `d721823`:

| Claim | Evidence |
| --- | --- |
| Score is never written for decided rows | `src/example/runner.py:118-124` |
| Rank is computed from a stale per-batch order | `src/example/ranking/assign.py:41` |

## Contracts

**Instruction.** List the canonical names this plan introduces or consumes: tables, fields,
flags, commands. Every name must exist in `data/plan-contracts.yaml` for this plan's
`project` with status `canonical` or `planned`; a name that is not there yet is how you
declare something new, so add it as `planned` in the same PR. A `deprecated` name fails.

**Example.**

| Kind | Name | Status | Meaning |
| --- | --- | --- | --- |
| table | `decisions` | planned | One row per decided job |
| field | `decisions.p_fit` | planned | Calibrated probability, 0..1, NULL until scored |
| command | `scripts/example/check_integrity.py` | planned | Verifies the persisted columns |

## Exact change list

**Instruction.** One row per file you will touch, with the function or table inside it and
what changes. This list is what `PL006` counts against `effort`; if it is longer than the
effort allows, split the slice instead of raising the effort without thinking.

**Example.**

| File | Function or table | Change |
| --- | --- | --- |
| `src/example/runner.py` | `run_batch` | Write `p_fit` and `model_rank` in the same transaction as the verdict |
| `tests/example/test_runner.py` | new test module | Assert one write per decided row and no write on veto |

## Data and migration

**Instruction.** Name the schema change, its version, the migration id, the backfill (or say
"no backfill" and why), and the compatibility window. "No data change" is a valid answer.

**Example.**

- Schema version 29 to 30, migration `030_add_p_fit.sql`: `ALTER TABLE decisions ADD COLUMN p_fit REAL`.
- No backfill: existing rows stay NULL until requalified, and every reader already treats NULL as unscored.
- Compatibility: readers keep working for one release; the drop lands in `031` after the reader change ships.

## Failure modes

**Instruction.** One row per way this can go wrong, with what the user or operator sees and
what limits the damage. "Handle errors" is a `PL002` placeholder because it decides nothing.

**Example.**

| Failure | Behavior | Limit |
| --- | --- | --- |
| Scorer raises mid-batch | Batch aborts before any write; the verdict transaction is not committed | No partial score rows; the batch is re-runnable |
| Model file missing | Startup refuses with the model path and the expected digest | Never falls back to an uncalibrated default |
| Two writers race on one job | The second write fails the `(job_id, decision_key)` uniqueness check | One row wins; the loser is logged, not overwritten |

## Tests

**Instruction.** Name the test files and the case each one owns. Unit tests prove the unit;
integration tests prove the seam; the acceptance commands below prove the outcome. A test
that asserts implementation source instead of behavior is not a test for this section.

**Example.**

- `tests/example/test_runner.py`: writes a score only for a decided row; leaves a veto untouched.
- `tests/example/test_integrity.py`: a hand-built row set with one missing score is reported as one mismatch.

## Acceptance criteria

**Instruction.** One bullet per `acceptance_commands` entry, with the exact same command in
backticks and the same expected result after the arrow. `PL003` compares the two copies word
for word, so edit both at once. An expected result must be observable: an exit code, a
count, a printed line, a threshold.

**Example.**

- **A1** `pytest tests/example/test_feature.py -q` -> exit 0 and 4 passed
- **A2** `bin/example-check --strict` -> exit 0 and prints "0 mismatches"

## Rollout and rollback

**Instruction.** Say how this ships (behind a flag, two-step migration, straight merge) and
how it is undone. The rollback must name what is restored and how that is verified; the
front matter `rollback` field carries the one-sentence version.

**Example.**

- Rollout: ship the writer first behind `config/example-write-scores`; enable it per host after A1 passes in CI.
- Rollback: turn the flag off (no data written), then revert migration `030` and verify `check_integrity --schema` reports 29.

## Dependencies and parallel-safety

**Instruction.** Name what must land first and what you must not edit concurrently. Every
`depends_on` entry must be a `plan_id` in this set. If this plan cannot run alongside
another, say why in `serial_reason` rather than leaving `parallel_safe: false` unexplained.

**Example.**

- Depends on `example-storage-s0` (adds the column this plan writes).
- Parallel-safe with `example-evaluation-s2` (different module), not with any plan editing `src/example/runner.py`.
- `serial_reason` unset because `parallel_safe: true`.

## Observability

**Instruction.** Name the signal that proves this works in production and the signal that
would prove it broke. A metric without a threshold is decoration; give the threshold or say
explicitly that the signal is read by a human at review time.

**Example.**

- Counter `example.mismatch_rows` after each integrity pass; alert at any non-zero value.
- Log line `example write_failed job_id=...` at WARN, read by the operator on the next sweep.

## Open decisions

**Instruction.** One line per decision a human still owns, as `- [ ] <question> - owner: <who>`.
An unchecked box makes the plan a draft: `PL011` refuses to gate a plan whose open decisions
are unresolved. Check the box in the same commit that records the answer.

**Example.**

- [ ] Does the backfill run inside the migration transaction or as a separate job? - owner: data
- [x] Is `p_fit` NULL or 0 for unscored rows? NULL, so a reader can tell "not scored" from "scored zero".

## Changelog

**Instruction.** One dated line per change to this plan, newest last, format
`- YYYY-MM-DD <what changed> (pr: <url>)`. A plan moving to `status: landed` needs at least
one entry with its PR URL; that line is the post-merge handoff.

**Example.**

- 2026-01-02 Plan created from `example-storage-s0` with front matter and A1-A2.
- 2026-01-09 Split the sweep into its own slice after `effort: M` exceeded 8 change rows.

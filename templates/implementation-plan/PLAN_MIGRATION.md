# Migration plan

Inherits `PLAN_TEMPLATE.md`. Use a migration plan when the change alters stored data, a
schema version, or a long-lived file layout. Migrations are the one kind where "revert the
commit" is almost never the rollback, so the rollback and compatibility sections carry more
weight than the change list.

Set `plan_kind: migration`.

## What a migration plan adds

### `## Migration steps`

**Instruction.** Numbered steps in the exact order an operator runs them, each naming the
command or file and the state it leaves behind. A step that cannot be re-run safely says so.
The linter accepts `## Migration order` or `## Migration runbook` as the same section.

**Example.**

1. `031_add_scores.sql` on a scratch copy; expect `schema_version = 31` and no row changes.
2. Deploy the writer with `config/example-write-scores` off; expect no new writes.
3. Enable the flag per host; expect `check_integrity --check scores` to print `0 mismatches`.
4. `032_drop_legacy_projection.sql` only after step 3 is green for one full sweep.

### `## Backfill and verification`

**Instruction.** State whether a backfill runs, its bound (rows or time), how it resumes, and
the query that proves it finished. An unbounded backfill in a migration transaction is a
failure mode, not a step.

**Example.**

- No backfill of historical rows: NULL means unscored and every reader handles it.
- Bounded replay for the last 2,000 decided rows: `check_integrity --check scores --limit 2000`
  must print `0 mismatches`; it is re-runnable and idempotent.
- Verification query: `SELECT COUNT(*) FROM decisions WHERE p_fit IS NOT NULL AND p_fit NOT BETWEEN 0 AND 1;`
  must return 0.

### `## Compatibility window`

**Instruction.** Say how long old readers keep working, which release drops the old shape,
and what breaks if the two are out of step. Name the release, not "later".

**Example.**

- Readers accept both shapes for one release (v1.14).
- v1.15 drops the legacy projection; nothing may read it after the drop.
- Out of step means a reader sees NULL scores for one sweep, never a wrong verdict.

## Migration rules

- The rollback names the restore path for the data, not just the code: which snapshot, which
  backup, which command proves the restore. `PL008` rejects a bare "revert".
- One migration plan owns one version bump. Two bumps are two plans with a `depends_on` chain
  (`PL009`), and each names its compatibility window.
- Every table and column in `## Contracts` must be in the registry as `planned` or
  `canonical`; a `deprecated` name in a migration plan means the migration is reviving a
  shape that was retired (`PL004`).
- The acceptance commands include one that reads the stored data, not only the code:
  a schema check, a count, or an integrity pass.

## Front matter example

```yaml
---
plan_id: example-data-m030
title: "Data M030: add decisions.p_fit and decisions.model_rank"
task: example-data-m030
project: example-project
repo: projects/example-project
milestone: M1
slice: S1
owner: data
status: draft
plan_kind: migration
depends_on: [example-storage-s0]
effort: M
parallel_safe: false
serial_reason: A schema version bump serializes every other migration in this milestone.
contracts:
  tables: [decisions]
  fields: [decisions.p_fit, decisions.model_rank]
  flags: []
  commands: [scripts/example/check_integrity.py]
finding_ids: ["01M59G7X5YW26CAQ0VCJJ948CM:duplicate-legacy-projection-repair"]
acceptance_commands:
  - id: A1
    command: sqlite3 scratch.db "PRAGMA user_version;"
    expect: prints 30
  - id: A2
    command: scripts/example/check_integrity.py --check schema
    expect: exit 0 and prints "schema 30 ok"
rollback: Restore scratch.db from the pre-migration snapshot taken in step 1, then run A1 to confirm it prints 29.
declared_new_paths:
  - migrations/030_add_scores.sql
---
```

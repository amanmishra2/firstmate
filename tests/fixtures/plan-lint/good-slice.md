---
plan_id: fixture-storage-s1
title: "Fixture slice: persist a computed probability"
task: fixture-storage-s1
project: fixture
repo: repo
milestone: M1
slice: S1
owner: fixture-owner
status: ready
plan_kind: slice
depends_on: []
effort: M
parallel_safe: true
contracts:
  tables: [decisions]
  fields: [decisions.p_fit]
  flags: [--strict]
  commands: [scripts/fixture/check.py]
finding_ids: ["01FIXTURE0000000000000001:review-2"]
acceptance_commands:
  - id: A1
    command: python3 -c "print(1)"
    expect: exit 0 and prints 1
  - id: A2
    command: python3 tests/fixture/test_module.py
    expect: exit 0 and 2 passed
rollback: Remove the writer call, leave the column in place, and re-run A1 to confirm the previous behavior.
declared_new_paths:
  - src/fixture/writer.py
---

# Fixture slice: persist a computed probability

## Identity

| Field | Value |
| --- | --- |
| Task | `fixture-storage-s1` |
| Slice | S1 |
| Milestone | M1 |
| Owner | `fixture-owner` |

## Objective and non-goals

Objective: persist the computed probability on every decided row.

Non-goals:

- No change to how the probability is computed.
- No backfill of historical rows.

## Current-state evidence

| Claim | Evidence |
| --- | --- |
| The writer ignores the computed value | `src/fixture/module.py:4-6` |

## Contracts

| Kind | Name | Status |
| --- | --- | --- |
| table | `decisions` | planned |
| field | `decisions.p_fit` | planned |
| flag | `--strict` | canonical |
| command | `scripts/fixture/check.py` | planned |

## Exact change list

| File | Function or table | Change |
| --- | --- | --- |
| `src/fixture/module.py` | `decide` | Write the probability in the verdict transaction |
| `src/fixture/writer.py` | new module | One write per decided row |

## Data and migration

- No schema change: `decisions.p_fit` already exists in the fixture schema.
- No backfill: NULL means unscored.

## Failure modes

| Failure | Behavior | Limit |
| --- | --- | --- |
| Writer raises | The transaction rolls back before commit | No partial rows |
| Missing model | Startup refuses with the path | No silently unscored writes |

## Tests

- `tests/fixture/test_module.py`: writes once for a decided row and not at all for a veto.

## Acceptance criteria

- **A1** `python3 -c "print(1)"` -> exit 0 and prints 1
- **A2** `python3 tests/fixture/test_module.py` -> exit 0 and 2 passed

## Rollout and rollback

- Rollout: straight merge; the writer is idempotent per decision key.
- Rollback: remove the writer call, leave the column, and re-run A1.

## Dependencies and parallel-safety

- No dependency. Parallel-safe: the only shared file is `src/fixture/module.py`.

## Observability

- Counter `fixture.write_failures`; alert on any non-zero value at review time.

## Open decisions

- [x] Is NULL the right "unscored" value? Yes, readers already treat NULL as unscored.

## Changelog

- 2026-01-02 Plan created with front matter and acceptance A1-A2.

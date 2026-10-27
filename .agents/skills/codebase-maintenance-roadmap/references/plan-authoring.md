# Plan authoring and handoff (reference)

A maintenance campaign that fixes N defects without updating the plan behind them re-raises
the same defects next quarter. This reference is the short version; the contract lives in
`docs/plan-lifecycle.md`.

## When a maintenance finding needs a plan edit

Every finding the prevention ledger classifies names the plan section it must update. The
mapping is the ledger taxonomy, not a judgment call:

| Category | Plan section |
| --- | --- |
| `missing contract` | `## Contracts` |
| `wrong path/name`, `stale assumption` | `## Current-state evidence` |
| `missing test/fixture` | `## Tests` |
| `schema/migration drift` | `## Data and migration` |
| `ambiguous acceptance` | `## Acceptance criteria` and `acceptance_commands` |
| `unsafe edge/rollback` | `## Failure modes`, `## Rollout and rollback` |
| `environment/tooling` | no plan section; record it in the run's `gaps` |

Add the finding's `<run_id>:<finding_id>` to the plan's `finding_ids` in the same edit, so the
plan states its own reasons.

## Authoring a maintenance plan

1. Copy `templates/implementation-plan/PLAN_TEMPLATE.md` (add `PLAN_MIGRATION.md` for schema
   work or `PLAN_SLICE.md` for a normal slice).
2. Name every table, field, flag, and command in `contracts:`; a name that does not exist yet
   goes into `data/plan-contracts.yaml` as `planned`, not into prose.
3. Make every acceptance criterion a command with an observable result, in both
   `acceptance_commands` and `## Acceptance criteria`.
4. Run `bin/fm-plan-lint.py <plan> --home "$FM_HOME"` until it exits 0, then
   `bin/fm-plan-gate.sh --plan <plan>` for the dispatch check.

## What the roadmap audit adds to a plan

An audit produces findings, not fixes: dead code, duplication, unused UI, redundant queries,
disconnected files. Each one lands in a plan section before the campaign is dispatched, and a
campaign that spans several slices gets one plan per slice with `depends_on` between them.
A cleanup with no plan is the pattern that produces review findings instead of removals.

## Handoff owner

The plan's `owner:` field is the person or role who updates it: at the finding, at the PR, and
at the merge. Firstmate records the PR and merge lines; the plan's owner owns everything else.

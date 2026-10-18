# Refactor sequencing

This reference owns when refactors run relative to feature work, how a slice is shaped, and how a seam is extracted safely.

## Sequencing rule

- A refactor slice is a prerequisite, not a side quest: when feature work is planned on a seam the audit flagged, the decoupling slice lands first and the feature rebases onto it.
- Slices run in dependency order, one seam per slice, each leaving the project's tests green.
- A slice never mixes behavior change with code motion; behavior changes ship as their own tasks.
- Cold paths, stable schemas, and grandfathered directories stay unrefactored even when large; the tri-state rules in [`audit-playbook.md`](audit-playbook.md) own that call.

## Slice shape

Every slice in a report's phased slice plan carries exactly three fields:

- Scope: what moves, splits, or gets deleted, bounded to one seam.
- Depends on: the slice or task that must land first, or `nothing`.
- Verification: the exact command that proves the slice, for example the project's focused test selection plus its linter on the touched paths.

A slice that cannot name its verification command is not ready to file.

## Safe seam extraction

1. Identify the seam from the finding's anchor: one responsibility with a stable interface.
2. Move the code without changing behavior: keep public names stable, re-export where callers depend on the old path, and avoid drive-by cleanups inside the move.
3. Update the folder's `SUMMARY.md` in the same change, per [`structure-standard.md`](structure-standard.md).
4. Run the slice's verification command; a red suite stops the slice rather than widening it.
5. Land the slice through the normal task lifecycle; the next dependent slice rebases onto it.

## From plan to backlog

- The phased slice plan is the report's ordering; backlog items carry it forward one slice at a time, with `--blocked-by` chains for hard dependencies.
- Re-check the plan after every landing: a landed slice changes the ranking, and the next slice may no longer be the top finding.
- If a slice grows beyond its seam or its verification stops proving the move, stop and re-scope it through the audit playbook rather than pushing through.

# Prevention loop runbook

One page, four cadences, one owner.
The ledger is the only input and the only durable output beyond one action per review.
`SCHEMA.md` owns the row shape and taxonomy; this file owns when to look and when to stop.

## Roles

**Owner: firstmate.** The primary home runs every cadence, keeps the ledger current, and is the only role that adds or retires a control.
A weekly review with no firstmate present does not happen; the loop is not a background service and must not become one.

## Always: keep the ledger current

Before any review, export the runs that reached a terminal state since the last export.

```
bin/fm-prevention-ledger.py backfill --ledger data/prevention-ledger/runs.jsonl
bin/fm-prevention-ledger.py validate --ledger data/prevention-ledger/runs.jsonl
```

`backfill` is idempotent, so running it twice is free.
When `validate` reports an unclassified finding, classify it into `classifications.tsv` before the review; an unclassified finding is a hole in the mix, not a finding to discuss.

The committed ledger is a reviewed snapshot, not a scratch file.
After a backfill that added rows, read `git diff data/prevention-ledger/runs.jsonl` and confirm every new row is one you expect before committing it.
Never stage that path with a blanket `git add -A` without reading the diff: that is how unreviewed fleet history would reach a public tree.
For a working copy you do not intend to publish, pass `--ledger data/prevention-ledger/live.jsonl`, which stays ignored.

## Weekly: 30 minutes, category deltas and control effectiveness only

Hard scope: new ledger rows since the previous weekly review.
Nothing else is in scope: not open PRs, not the backlog, not a project audit.

Inputs:

- `bin/fm-prevention-ledger.py stats --since <previous review epoch>` for the category mix and first-pass rate of the new rows.
- The previous week's recorded category shares, from last week's `stats` output.
- `state/prevention-preflight.jsonl`, written by `bin/fm-brief-preflight.py --record`, for pass, fail, and declared-`none` counts per check.

Outputs, in this order, and no others:

1. Category deltas: count and share per category, with the denominator, against last week.
2. Control effectiveness: for each shipped control, how often it fired and whether its category share moved in the right direction.
3. Exactly one action: keep the controls as they are, adjust one control, or add the next candidate from the deferred list.

The one action is the whole output.
A review that ends with a list of observations and no action has failed and should be reported as such.
Refuse to call a category "improved" on one week: a weekly cohort is roughly 25 review-bearing runs, and an eight-point share move is inside sampling noise at that size.

Record the review as one note with the `stats` output pasted in, the three outputs above, and the date.
No dashboard, no chart, no database.

## Monthly: deep review, retire and re-check

Roughly 60 minutes, once a month.

- Recompute every category share over the trailing month and compare with the two preceding months.
- Read every finding the taxonomy classified as `missing contract` or `ambiguous acceptance` in the month and confirm the assignment still holds; correct `classifications.tsv` where it does not.
- Re-check escaped defects: if nothing links merged PRs to later defects, say so again rather than reporting zero.
- Retire any control whose category share did not improve after two cycles, using the quarterly rule below, so retirement does not wait for the quarter.
- Re-examine the deferred-control list and decide whether the next candidate is now affordable.

## Quarterly: prune the loop itself

Two questions, both answered with numbers.

1. Did the first-pass gate rate improve against the baseline in `catch-up-2026-10-24.md`?
   If it did not improve across two consecutive quarters, the loop is not working and the controls are retired rather than defended.
2. Is any control's category share worse than its pre-control baseline after two cycles?
   Retire it.
   A control that does not move its category is cost without benefit, and the cap of about ten controls exists so a weak one cannot hide behind a strong one.

Retirement is a one-line removal of the control plus a `classifications.tsv`-compatible note in the next catch-up report saying what was retired, when, and with which numbers.
The ledger keeps every historical row; retiring a control never rewrites history.

## Stop conditions

Stop the loop, and say so, when any of these holds.

- `validate` cannot pass because the no-mistakes state database is unreadable.
  The ledger is not the problem; the source is.
- Fewer than five review-bearing runs landed in the cycle.
  There is no signal to review, so the weekly review is skipped and noted, not padded.
- More than half of the cycle's runs ended on environment failures.
  The pipeline is the bottleneck, not authoring, and the review's one action becomes a runtime-reliability item.
- A control cannot be exercised because briefs are being dispatched without running the pre-flight.
  That is an adoption failure: report it as the weekly action instead of measuring category shares that the control never touched.
- The taxonomy needs a ninth category.
  Stop and change `SCHEMA.md` deliberately; do not invent a category inside a review note.

## Adding a control

Only when a category has at least three observed findings, and only one control per category.
The control must be one of: a brief-scaffold checklist line, a deterministic pre-flight validator, a fixture, or a plan lint.
Before shipping it, write down the expected metric movement and the leading indicator, in the same shape as `catch-up-2026-10-24.md` section 5, so the next weekly review can hold it to that number.

# Evaluation plan

Inherits `PLAN_TEMPLATE.md`. Use an evaluation plan when the deliverable is a measurement, a
gate, or a statistical claim rather than a behavior change. Evaluation plans fail differently
from code plans: they pass while measuring the wrong thing, so the metric definition and the
decision rule are the contracts.

Set `plan_kind: evaluation`.

## What an evaluation plan adds

### `## Metrics`

**Instruction.** Define each metric with its numerator, denominator, direction, and the
threshold that decides the outcome. A metric without a threshold cannot fail, so it is not an
acceptance criterion. Name the exact field or column the metric reads.

**Example.**

- Primary: F1 for the include class, computed over the frozen holdout, threshold `>= 0.02`
  absolute improvement over the current baseline (`metrics.f1_include`).
- Guardrail: include-rate drift `<= 0.03` absolute; crossing it makes the run inconclusive
  rather than a regression.
- Reported but not deciding: precision at the review cutoff (`metrics.precision_at_50`).

### `## Statistical design`

**Instruction.** State the sample size, the comparison, the test, and the decision rule,
including what happens on an inconclusive result. A plan that cannot say what "no result"
looks like will report noise as a win.

**Example.**

- Sample: 500 reserved rows, fixed before the run; the reserve is never re-drawn mid-run.
- Comparison: paired, same rows, candidate versus baseline; DeLong test for AUC and a
  bootstrap interval for F1 (10,000 resamples, seed 7).
- Decision rule: promote only when the lower bound of the interval clears the threshold;
  otherwise record an inconclusive receipt and keep the baseline.

## Evaluation rules

- Acceptance commands read a receipt or a metrics file, not a log line a human interprets:
  `jq -e '.promoted == true' receipt.json` is acceptance, "looks better" is not (`PL003`).
- The holdout is named in `## Contracts` as a table or registry entry, so two evaluation
  plans cannot silently claim the same reserve (`PL004`).
- A plan whose promotion gate is not yet wired says so in `## Open decisions` and stays
  `status: draft`; `PL011` refuses to gate a draft with an unchecked decision.
- `## Failure modes` names the statistical failure modes explicitly: leaked holdout, multiple
  comparisons, and a re-drawn sample.

## Front matter example

```yaml
---
plan_id: example-eval-s4-power
title: "Evaluation S4: sizing and the promotion decision rule"
task: example-eval-s4-power
project: example-project
repo: projects/example-project
milestone: M1
slice: S4
owner: evaluation
status: draft
plan_kind: evaluation
depends_on: [example-storage-s1]
effort: M
parallel_safe: true
contracts:
  tables: [evaluation_runs, holdout_registry]
  fields: [evaluation_runs.metric_name, evaluation_runs.value]
  flags: []
  commands: [scripts/example/evaluate.py]
finding_ids: ["01M4S89DM4AWTF2HH1SN98M7JA:S1"]
acceptance_commands:
  - id: A1
    command: scripts/example/evaluate.py --dry-run --reserve 500
    expect: exit 0 and prints "mde=0.063"
  - id: A2
    command: scripts/example/evaluate.py --receipt scratch/receipt.json
    expect: exit 0 and writes a receipt with promoted=false
rollback: Delete scratch/receipt.json and leave the frozen reserve untouched; re-run A2 to confirm the same promoted=false receipt is produced from the unchanged reserve.
declared_new_paths:
  - scripts/example/evaluate.py
---
```

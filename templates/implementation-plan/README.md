# Implementation plan templates

Authoring surface for plans that are dispatched to a worker, linted before dispatch, and
updated at every handoff afterwards.

| File | Use it for |
| --- | --- |
| `PLAN_TEMPLATE.md` | the base plan: every required section, with an instruction and a filled example for each |
| `PLAN_SLICE.md` | the default kind, one independently shippable slice |
| `PLAN_SUBTASK.md` | part of a slice that lands with or just after its parent |
| `PLAN_MIGRATION.md` | a schema version, backfill, or long-lived data layout change |
| `PLAN_EVALUATION.md` | a measurement, gate, or statistical claim |
| `PLAN_SCHEMA.yaml` | the front-matter fields, their types, and which rule reads each one |
| `PLAN_CONTRACTS.example.yaml` | the shipped example contract registry; the real one is `data/plan-contracts.yaml` |

```sh
cp templates/implementation-plan/PLAN_TEMPLATE.md data/<task>/PLAN.md
$EDITOR data/<task>/PLAN.md
bin/fm-plan-lint.py data/<task>/PLAN.md     # exits 0 when the plan is dispatchable
bin/fm-plan-lint.py --rules                 # every rule, what it prevents, its evidence
```

`docs/plan-lifecycle.md` owns who updates the plan at each handoff and which artifact they
read. `bin/fm-plan-lint.py` owns the rule ids. The templates here are the only authoring
surface: there is no second framework, generator, or dashboard.

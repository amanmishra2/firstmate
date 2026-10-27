# Plan lifecycle and ownership

How a no-mistakes finding becomes a plan edit, how a plan becomes a dispatch, and how a
landed PR becomes a plan record. One page, one owner per handoff.

The system exists because each of these gaps was observed, not imagined:

1. **Finding → plan.** Nothing said which plan section a review finding must update, so a fix
   landed without the plan changing and the next run raised the same finding again.
2. **Plan → brief.** Briefs referenced plans in prose, so a worker could implement a plan that
   had moved on.
3. **Plan → code.** No shared vocabulary for table, field, flag, and command names, so a plan
   and its implementation could spell one thing two ways.
4. **Plan → acceptance.** Subjective criteria survived because nothing required a runnable
   command.
5. **PR → plan.** No post-merge step, so plans described work that had already landed.
6. **Plan → dispatch.** No definition-of-ready gate, so an incomplete plan could be sent.
7. **Control → metric.** The prevention loop can propose a control, but nothing tied a control
   back to the section it protects or the signal that shows it working.

## The chain

```
no-mistakes finding
  -> classified in data/prevention-ledger/runs.jsonl      (prevention loop)
  -> plan section updated, cited by <run_id>:<finding_id> (plan owner)
  -> bin/fm-plan-lint.py passes                           (author, then CI)
  -> definition-of-ready gate                             (bin/fm-plan-gate.sh at dispatch)
  -> dispatch: brief carries Plan: <path>                 (firstmate)
  -> PR opened, changelog entry records its URL           (worker)
  -> plan status/index updated                            (firstmate, at merge)
  -> control effectiveness measured                       (prevention loop, advisory)
```

## Handoff contract

| # | From | To | Who updates it | When | Artifact they read | Enforced by |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | A merged run's review findings | Plan section | The plan's `owner:` field | Within the next plan edit, before the next dispatch | `data/prevention-ledger/runs.jsonl`, the run's finding list | `PL005` (citation present and resolvable) |
| 2 | Plan | Brief | Firstmate, at intake | At scaffold time, `bin/fm-brief.sh --plan-ref <path>` | The plan's `plan_id` and `status` | `PL011` at dispatch; the brief's `Plan:` line |
| 3 | Brief | Dispatch | Firstmate | At spawn, when `config/plan-gate` is `on` | The brief's `Plan:` line | `bin/fm-plan-gate.sh`, refusing with the linter's rule id, file, and line |
| 4 | Dispatched plan | Task record | Firstmate | At spawn, automatically | The resolved plan path | `fm-spawn` writes `plan_ref=` into `state/<task>.meta`; the prevention ledger reads it back |
| 5 | PR | Plan changelog | The worker that opened the PR | When the PR is ready for review | The PR URL it just reported | `PL012` once the plan moves to `landed` |
| 6 | Merged PR | Plan status and index | Firstmate | Immediately after the merge it performed | The merge result and the plan changelog | `PL012` (a landed plan needs a dated entry with a PR URL) |
| 7 | Prevention control | Plan section and metric | Prevention loop's owner | When the control is proposed | The plan section the control protects | Advisory: the control registry is not owned by this document |

### 1. Finding to plan section

The prevention ledger's taxonomy decides which section a finding must update. A finding is
never "handled" by a code fix alone: the category names the plan text that was missing.

| Ledger category | Plan section it updates | Why that section |
| --- | --- | --- |
| `missing contract` | `## Contracts` | the interface, boundary, or vocabulary was never stated |
| `wrong path/name` | `## Current-state evidence` | the plan cited something that is not there |
| `stale assumption` | `## Current-state evidence` | the plan described a tree that has moved |
| `missing test/fixture` | `## Tests` | the plan never said what proves the behavior |
| `schema/migration drift` | `## Data and migration` | the stored shape and the plan disagree |
| `ambiguous acceptance` | `## Acceptance criteria` (and `acceptance_commands`) | the criterion could not decide the case |
| `unsafe edge/rollback` | `## Failure modes` and `## Rollout and rollback` | the edge or the undo path was missing |
| `environment/tooling` | no plan section | the defect is not in the plan; it belongs in the run's `gaps` and `run:environment-failure` |

Every edit made for a finding adds that finding's `<run_id>:<finding_id>` to the plan's
`finding_ids`, so the plan records its own reasons and `PL005` can check each one against the
ledger. A plan that genuinely answers no prior finding states the check it did in
`evidence_note` instead; that is the only way to have no citation.

Evidence behind this handoff: in the prevention ledger's 78-row baseline, 43 rows record
`plan_ref:unrecorded`, so nothing recorded which plan a run changed and no plan could be
reconciled with the finding that motivated it.

### 2. Plan to brief

`bin/fm-brief.sh --plan-ref <path>` writes one `Plan: <path>` line under `# Setup`. Omitting
the flag writes `Plan: none`, which is explicit rather than silent: an enabled gate refuses
it. The reference is recorded once per brief; a brief that needs two plans needs splitting.

### 3. Brief to dispatch

`bin/fm-spawn.sh` hands that line to `bin/fm-plan-gate.sh` before any endpoint or worktree
exists, so a refused plan costs nothing. The gate is **default off**; a home turns it on with
`config/plan-gate` containing `on`, or for one call with `FM_PLAN_GATE=1`.

When it is on, the gate refuses unless `bin/fm-plan-lint.py --require-ready` accepts the plan,
and relays its findings verbatim - rule id, file, line, and message - so the refusal is the
fix instruction. `--require-ready` additionally refuses `status: draft`, an unresolved
`- [ ]` open decision, and a plan whose acceptance or rollback is missing.

### 4. Dispatch to task record

The same call resolves the plan path and prints it, and `fm-spawn` records it as
`plan_ref=` in `state/<task>.meta`. That field is what the prevention ledger's `plan_ref`
column reads, which is how a later ledger row can be reconciled with the plan a worker
actually implemented instead of `plan_ref:unrecorded`.

### 5. PR to changelog

The worker appends one dated line to the plan's `## Changelog` when it reports the PR ready:

```
- 2026-01-09 Shipped the writer behind config/example-write-scores (pr: https://example.test/pr/42)
```

The worker owns this line because it holds the PR URL at that moment. `PL012` accepts any
dated entry; it requires a `pr: <url>` entry only once the plan says `status: landed`.

### 6. Merge to status and index

Firstmate performs the merge, so firstmate owns the two edits it enables:

- the plan's `status:` becomes `landed`, its `Changelog` gains the merge line, and any name it
  declared `planned` in `data/plan-contracts.yaml` becomes `canonical`;
- the plan set's `INDEX.md` row for that plan moves from planned to landed.

Both edits happen before the task is cleaned up. A plan left at `in-flight` after its merge is
the exact rot this handoff removes.

### 7. Control to protected section and metric

A prevention control names three things: the plan section whose rule it enforces (for example
`## Contracts`, via `PL004`), the rule id that measures it, and the signal that shows the rule
firing (for example the count of `PL004` findings per week in the ledger review). A control
that cannot name a section has nothing to protect, and one that cannot name a metric cannot
be shown to work. This handoff is **advisory**: the control registry belongs to the prevention
loop, and this document only fixes what a control must cite.

## Who owns what

| Artifact | Owner | Notes |
| --- | --- | --- |
| `data/prevention-ledger/runs.jsonl` | prevention loop | append-only; one row per terminal run |
| A plan's sections and `finding_ids` | the plan's `owner:` field | named in the front matter and in `## Identity` |
| A brief's `Plan:` line | firstmate | written by `bin/fm-brief.sh --plan-ref` |
| Task record `plan_ref=` | firstmate | written by `bin/fm-spawn.sh` |
| Plan changelog PR line | the worker | written when the PR is reported ready |
| Plan status, index, contract promotion | firstmate | written at merge |
| `data/plan-contracts.yaml` | the project's name owner | the `owner:` field on each entry |

## Enforced versus advisory

Deterministic, and therefore a gate: `PL001`-`PL012` and the dispatch refusal they produce.
`bin/fm-plan-lint.py` never executes an acceptance command, never touches a project, and
never edits a plan.

Advisory, and labelled as such in the linter's output: finding-id resolution when no
prevention ledger exists, contract-name checks when no registry is reachable, path checks when
a plan's `repo:` does not exist, and the whole control-to-metric handoff.

## Where plans and the registry live

A plan set and its contract registry are home data: `data/<set>/plans/` and
`data/plan-contracts.yaml`. `data/` is captain-private and gitignored in this repository, so
the shipped surface is the templates, the linter, the gate, and
`templates/implementation-plan/PLAN_CONTRACTS.example.yaml`.

`bin/fm-plan-lint.py` prefers `<home>/data/plan-contracts.yaml` and falls back to the shipped
example, so a fresh checkout still lints - with only the example names known, which it reports
as an advisory rather than pretending the registry was complete. Copy the example to
`data/plan-contracts.yaml` and add each project's names to use it for real work.

## Authoring and checking

```sh
cp templates/implementation-plan/PLAN_TEMPLATE.md data/<task>/PLAN.md
bin/fm-plan-lint.py data/<task>/PLAN.md --home "$FM_HOME"                 # author loop
bin/fm-plan-gate.sh --plan data/<task>/PLAN.md                            # the dispatch check, always
bin/fm-plan-lint.py --rules                                              # rule id, failure, evidence
```

`--plan` lints even when this home has the dispatch gate switched off, because an explicit
`--plan` is a request for the check; only the dispatch path is switchable.

`templates/implementation-plan/README.md` indexes the templates and the schema;
`docs/scripts.md` lists both commands; `bin/fm-plan-lint.py`'s RULES table is the single owner
of the rule ids and their evidence.

# Prevention ledger schema

The prevention ledger is one append-only JSONL file, one JSON object per terminal no-mistakes run.
`bin/fm-prevention-ledger.py` is the only writer, and `bin/fm-prevention-ledger.py validate` is the only authority on whether a row conforms.
This file owns the row shape, the finding taxonomy, and the classification rule.
`RUNBOOK.md` owns the review cadence, and `catch-up-2026-10-24.md` owns the first measured baseline.

## Row shape

One row per terminal run, keyed `(project, run_id)`.
Field order is fixed; the validator rejects a row whose keys or order differ.

| # | field | type | meaning |
| --- | --- | --- | --- |
| 1 | `project` | string | Registered project name, taken from the no-mistakes repository row. |
| 2 | `task` | string | Task id: the run branch with a leading `fm/` removed. |
| 3 | `brief_path` | string or null | Brief the worker ran, relative to the firstmate home. |
| 4 | `plan_ref` | string or null | Plan, report, or blueprint the brief cites, with `#slice-<n>` when the task names a slice. |
| 5 | `run_id` | string | No-mistakes run id. |
| 6 | `start_head` | 40-hex string or null | Revision the run started from. |
| 7 | `end_head` | 40-hex string or null | Last head the pipeline pushed or approved. |
| 8 | `findings` | array of objects | Review findings, shape below. |
| 9 | `ask_user_answers` | array of objects | One entry per ask-user finding, shape below. |
| 10 | `fix_commits` | array of strings | `no-mistakes(...)` commits between `start_head` and `end_head`. |
| 11 | `pr_url` | string or null | Pull request the pipeline opened. |
| 12 | `ci_result` | enum | `green`, `failed`, `no-ci`, `not-run`, `pending`, or `unknown`; `green` and `failed` come from the pipeline's recorded CI step, never from the run status alone. |
| 13 | `rounds` | integer | Number of review rounds recorded for the run. |
| 14 | `wall_time_s` | integer | Terminal time minus start time, in seconds. |
| 15 | `observed_at` | integer | The run's own terminal update time; never the export clock. |
| 16 | `source` | string | Which sources contributed, `+`-joined, for example `nm-state+brief+proxy-git`. |
| 17 | `gaps` | array of strings | Sorted, unique tokens naming what could not be recovered. |

Finding objects carry exactly `id`, `severity`, `category`, `file`, `action`.
`severity` is `error`, `warning`, or `info`.
`action` is `auto-fix`, `ask-user`, or `no-op`.
The ledger never stores a finding description, so it holds no review prose.

Answer objects carry exactly `finding_id`, `decision`, `origin`.
`decision` is `selected`, `declined`, `presented`, `escalated-to-captain`, or `unrecorded`.
`origin` is the pipeline's recorded response origin, or `status` when firstmate's status file is the only record.

## Idempotency and determinism

The ledger key is `(project, run_id)`.
`backfill` appends only runs whose key is absent, so replaying it over an unchanged state database leaves the file byte-identical.
`export <task>` uses the same key and the same append path.
No row field comes from the wall clock: `observed_at` is the run's terminal update time, and `--until` bounds the capture window, so the same state database plus the same `--until` reproduces the same bytes.

`--gh` is the only opt-in that breaks reproducibility.
It reads live PR check state through `gh-axi` and rewrites `ci_result`, so the committed ledger is generated without it.

## Taxonomy and classification rule

Every finding gets exactly one category from this closed list.
There is no free-text category and no model call anywhere in the classification path.

| category | what it names |
| --- | --- |
| `missing contract` | The brief or plan never stated a rule, boundary, or interface the change needed, or the code honored a stated rule at one named place and not at every consumer. |
| `wrong path/name` | A path, module, symbol, command, or document pointer is not the real one. |
| `stale assumption` | The change relied on, or left behind, a fact about the tree that is no longer true: counts, versions, layouts, navigation maps, summaries, or exports. |
| `missing test/fixture` | No test or fixture covers a behavior, or the test asserts implementation source instead of behavior. |
| `schema/migration drift` | A schema, migration, stored field, manifest, or data contract no longer matches the code or the data. |
| `ambiguous acceptance` | The acceptance criteria could not decide the case, so the reviewer had to ask, or the change added surface the ask did not authorize. |
| `unsafe edge/rollback` | An edge, error, cleanup, concurrency, partial-write, resume, or rollback path is unsafe, missing, or silently permissive. |
| `environment/tooling` | A harness, quota, network, or CI-infrastructure failure rather than a defect in the change. |

Classification precedence, first match wins:

1. The reviewed mapping in `classifications.tsv`, keyed `project`, `branch`, `finding_id`.
   It holds one row per distinct key: 769 rows cover 866 findings, because re-runs of one task raise the same finding id again and share its row.
2. An ordered path rule from `PATH_RULES` in the exporter: test and fixture paths, migration and `.sql` paths, CI and lockfile paths.
3. `category: null` plus a `classification:unclassified:<id>` gap token.

A null category is a recorded gap, not a guess.
The validator refuses a null category without its matching gap token, and `stats` reports an `unclassified` bucket in the same table as the eight categories, so shares always sum to 100 percent.
The committed baseline has zero nulls: all 866 findings were classified by review and are listed in `classifications.tsv`.

### Why the mapping is a table, not a heuristic

Finding ids and descriptions are pipeline-generated prose, so no deterministic rule over them survives contact with the next task.
The mapping table makes the classification reproducible and auditable: a reviewer can read every assignment, and a wrong one is a one-line correction rather than a classifier change.
Path rules cover only the categories a path can decide on its own, and they classify a new run's obvious cases while the weekly review adds the rest to the table.

To classify new findings, add one line per finding to `classifications.tsv`:

```
project<TAB>branch<TAB>finding_id<TAB>category
```

## Gap token vocabulary

`gaps` earns its place: it is how the ledger says "this field is not missing by accident".
Tokens are sorted and unique, and the prefix names the affected field.

| token | meaning |
| --- | --- |
| `brief:missing` | No brief or launch brief exists for the task under this home. |
| `meta:missing` | `state/<task>.meta` is gone, usually deleted at task cleanup. |
| `plan_ref:unrecorded` | Neither the brief nor the backlog item names a plan or report. |
| `project:unrecorded` | The run's repository row is gone, so the project name is unknown. |
| `start_head:unrecorded` | The pipeline recorded an all-zero base revision. |
| `end_head:not-pushed` | The run never pushed, so no terminal head exists. |
| `end_head:invalid` | The recorded head is not a 40-hex commit id. |
| `fix_commits:unrecorded` | The proxy repository or the commit range was unavailable. |
| `fix_commits:not-requested` | The caller passed `--no-git`. |
| `findings:unparseable` | A recorded findings payload was not valid JSON, so the finding set may be incomplete. |
| `ci_result:unrecorded` | The pipeline completed without recording a CI verdict; the result is `unknown`. |
| `ask_user:no-recorded-decision:<id>` | An ask-user finding has no recorded selection and no status escalation. |
| `classification:unclassified:<id>` | The finding was never reviewed into the taxonomy. |
| `run:environment-failure` | The run ended on a harness, quota, network, or daemon failure, so its finding set is not a measure of authoring quality. |
| `ci_result:gh-unreadable` | `--gh` was requested and the forge could not be read. |

## Reproducing the ledger

```
bin/fm-prevention-ledger.py backfill --ledger data/prevention-ledger/runs.jsonl --until 1792800000
bin/fm-prevention-ledger.py validate --ledger data/prevention-ledger/runs.jsonl
bin/fm-prevention-ledger.py stats --ledger data/prevention-ledger/runs.jsonl
```

`1792800000` is 2026-10-24T00:00Z, the capture cutoff this ledger was generated with.
Replaying the two commands above over the same no-mistakes state database reproduces the committed file byte for byte.
A different host will produce different rows, which is expected: the ledger is evidence about one fleet's runs, not a shared fixture.

## Tracked-copy carve-out

`data/` is captain-private and gitignored, and this directory is the one documented exception.
`.gitignore` negates this directory and then names exactly five tracked files, so nothing else under it can become public.
The task order that created this ledger is the approval: it requires an append-only JSONL ledger under a firstmate data directory, backfilled and committed, so a reviewer can compare it against a fresh export.
The carve-out is safe because the ledger stores run ids, heads, commits, PR URLs, file paths, finding ids, severities, categories, and actions.
It never stores a finding description, prompt, transcript, or credential.
Finding ids are pipeline-generated slugs chosen by the reviewer agent, and they are included; a slug can describe the defect it names, so treat the ids as review metadata rather than as neutral labels.
Every other path under `data/` stays ignored.

## Adoption records

`bin/fm-brief-preflight.py --record <path>` appends one outcome line per invocation with the brief path, the failing check names, the checks that declared `none`, and the observation time.
The runbook points at `state/prevention-preflight.jsonl` as the default record, and the weekly review reads it to measure whether the controls were exercised at all.

## Known evidence limits

These limits are structural, not temporary, and the review cadence must not read past them.

- Escaped defects after merge cannot be computed: nothing links a merged PR to a later defect report.
- Environment failures are recorded per run (`run:environment-failure`), never per finding, because an aborted step produces no finding.
- `state/<task>.meta` survives only for live tasks, so delivery mode and task kind are unavailable for most historical rows.
- The no-mistakes `review_questions` table is empty on this host, so ask-user answers exist only as round selection state or as firstmate status events.

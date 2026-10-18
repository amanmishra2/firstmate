---
name: repo-maintenance
description: >-
  Keep repositories easy for agents to navigate and cheap to read: audit dead code, duplication, complexity, and legacy paths; organize structure with per-folder summaries and file-size discipline; sequence refactors ahead of feature work; and rank files by measured token heat so the worst files get fixed first.
  Use when the weekly fleet review reaches its maintenance boundary, when the captain invokes /repo-maintenance, or when maintenance work arrives in the backlog.
user-invocable: true
metadata:
  internal: true
---

# repo-maintenance

One umbrella system for repository health, navigation, and read cost.
It owns three things: the weekly maintenance sweep, the structure standard repositories are graded against, and the token-efficiency instrument that ranks which files to fix first.
Files under `references/` are resources of this skill, not additional catalogued skills.

## When this runs

- Weekly, at the fleet review's maintenance boundary: run the sweep below alongside the weekly rollup.
  It rides the existing review cadence; there is no daemon, timer, or platform of its own.
- On an explicit captain request (`/repo-maintenance`): run the sweep now, or work from the latest reports.
- On intake of a maintenance item in the backlog: scope it through `references/audit-playbook.md` before dispatch.

## The weekly sweep

1. Mine the week's session logs once, fleet-wide:
   `bin/fm-repo-maintenance.sh mine`
   The instrument is aggregate-only and read-only; its sources, scope, and schema are owned by its own header.
2. Sweep each registered project (`data/projects.md`) and this repository itself:
   `bin/fm-repo-maintenance.sh sweep <project>`
   Each sweep writes `data/repo-maintenance/<project>/<date>/report.md` with the instrument sections complete and the qualitative sections pending.
   Re-running the same date refuses unless `--force` is deliberate.
3. Complete each report's pending sections through `references/audit-playbook.md`, which owns their contract.
4. File the sweep's "fix next" items and any confirmed findings into the backlog; the audit playbook's filing rule owns the limits and the exact command.
   Never dispatch from the sweep itself; implementation ships later through the normal task lifecycle, with the report as its evidence.

## Reference modules

| Reference | Load when |
| --------- | --------- |
| [`references/audit-playbook.md`](references/audit-playbook.md) | auditing a project, completing a report's findings, slice, or verdict sections, or filing maintenance items |
| [`references/token-efficiency.md`](references/token-efficiency.md) | interpreting the heat ranking, changing the instrument's metric definitions, or doing token-efficiency work |
| [`references/structure-standard.md`](references/structure-standard.md) | organizing or scaffolding a repository's layout, writing SUMMARY.md files, or judging file-size exemptions |
| [`references/refactor-sequencing.md`](references/refactor-sequencing.md) | sequencing refactors ahead of feature work or extracting a seam |

## Boundaries

- No standalone daemons, watchers, databases, dashboards, or runtime token-interception proxies.
  The sweep is a bounded, on-demand run on the existing review cadence.
- Instrument outputs hold aggregates only: no prompts, diffs, message text, or tool output, and local paths outside the home and pool roots are counted, never recorded.
- The instrument and the audit never modify a project; they report.
  Every code change ships as its own task through the normal lifecycle with the report as evidence.
- A report is evidence, not authorization: findings enter the backlog, and the backlog's own intake, delivery mode, and merge authority rules apply unchanged.

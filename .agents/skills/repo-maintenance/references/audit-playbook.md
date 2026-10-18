# Audit playbook

This reference owns the qualitative half of a maintenance report: the findings contract, the audit procedure, and the tri-state verdict.
The instrument sections of the report come from `bin/fm-repo-maintenance.sh`; its header owns their mechanics.

## Report contract

A completed report keeps the instrument sections as written and fills the three pending sections:

1. **Evidence-backed findings** - one entry per finding:
   - Category: Dead Symbol, Duplication, Bloat Seam, Monolith, or Disconnected File.
   - Anchor: `<file>:<line-range>` (for example `retrain.py:940-1082`), or `<file>:<line>` for a single symbol.
   - Why it matters: the impact on token cost, maintainability, or runtime failures.
2. **Phased slice plan** - the ordered refactor slices, each with scope, dependencies, and the exact verification command; sequencing rules are owned by [`refactor-sequencing.md`](refactor-sequencing.md).
3. **Summary: DO FIRST / DO LATER / DO NOT DO** - the tri-state verdict over the findings.

## Audit procedure

1. Read the report's instrument sections first: the ranking, the structure findings, and the coverage line.
2. Run the project's own tooling for the mechanical checks - its linter, its type checker, its test suite, and import or export checks - rather than inventing parallel analysis.
3. Search for the finding categories with bounded commands (`git grep`, the project's dead-code tooling, duplicate-math spot checks around the hottest files); never run unbounded repository-wide sweeps.
4. Confirm every finding with a concrete anchor and a one-line reproduction or reasoning; drop anything that cannot be anchored.
5. Write the findings, the slice plan, and the verdict into the report, then file the top items per the filing rule below.

The audit is read-only: it never edits the project, opens a branch, or runs state-changing commands.
Every fix ships later as its own task with the report as its evidence.

## Tri-state rules

- **DO FIRST** - high-frequency read bloat, broken exports, duplicate core math, or a hot file with no navigation.
  These are the files the instrument already ranks highest, and they are prerequisites for feature work landing on the same seams.
- **DO LATER** - low-frequency route splits, deprecation isolation, and structure work in subsystems with no active feature pressure.
- **DO NOT DO** - heavily tested cold-path monoliths, stable legacy schemas, and grandfathered paths whose renaming would break historical links.
  Being large is not by itself a finding; the exemption classes in [`structure-standard.md`](structure-standard.md) name what stays.

Prefer repeated friction across distinct tasks over a single observation; a one-off read spike is not a pattern.

## Filing rule

- File at most three new maintenance items per project per week.
- One item per confirmed finding or slice, with the anchor and the verification command in the body:
  `bin/fm-tasks-axi.sh add --mint "<title>" --kind ship --repo <name> --body "<anchors, scope, verification>"`
- Do not duplicate an item already in the backlog; extend its note instead.
- Never dispatch from the audit; dispatch follows the backlog's normal intake, delivery mode, and merge authority.

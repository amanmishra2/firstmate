# Structure standard

This reference owns the universal repository baseline: layout, folder depth, per-folder navigation, file-size discipline, and entrypoints.
`bin/fm-repo-maintenance.sh structure` audits a repository against this standard; its header owns the exact checks and flags.

## Layout

- Modular `src/`: a domain-driven hierarchy (`src/<package>/<domain>/`) with presentation layers (`cli/`, `web/`) that consume domain packages and never the reverse.
- Folder depth: at most four levels below `src/` (`src/pkg/domain/subdomain/file.py`); deeper nesting costs navigation more than it buys organization.

## Per-folder navigation

- Every subdirectory carries a `SUMMARY.md`, at most 30 lines:
  - A heading with the subsystem name.
  - A `Role:` line with the single-sentence subsystem charter.
- A table of every file in the folder: `` | `file.py` | responsibility | key exported symbols | ``. Related files may share one row when each filename is an exact backticked entry in the File cell.
- A tracked file counts as listed when its basename is an exact File cell entry in its folder's `SUMMARY.md`; substring lookalikes do not count, and the audit reports every file that is not.
- Write summaries from the code, not from guesses: open each file's public surface, name its responsibility in one phrase, and list its exports.
  Update the summary in the same change that adds, removes, or renames a file.

## File-size discipline

- Soft ceiling: 500 lines, binding on active operational logic, CLI dispatchers, routes, and domain modules.
- Exempt classes: pure schema definitions, test data fixtures, and verified cold offline batch paths.
- Exemptions are recorded per project in `data/repo-maintenance/<project>/exemptions.txt`, one `<path> :: <reason>` per line.
  An exemption without a reason is not an exemption; re-verify exemptions when the file's role changes.
- Over-ceiling files that are not exempt are findings, and a hot one is usually `DO FIRST`.

## Entrypoints and discoverability

- Root `README.md`: what the project is, how to set it up, and how to validate it.
- Root `AGENTS.md`: the task routing table mapping task to domain files to tests. `CLAUDE.md` alone does not satisfy this entrypoint.
- Zero orphan files: every tracked file is reachable from its folder's `SUMMARY.md` and the root entrypoints.

## Rollout

1. Pilot one project: add the missing `SUMMARY.md` files for its hottest folders first, fix broken exports and duplicate math, and measure the read-cost drop on subsequent tasks.
2. Phase 2 rolls the standard out to remaining domain packages only after they meet the four-level depth bound, per-folder summary standard, and unexempted 500-line ceiling. The pilot's ranking improvement is necessary evidence, but it is not a universal rollout gate.
3. A new repository is scaffolded to this standard from its first commit: `src/` layout, folder summaries, entrypoints, and the size ceiling.

The current pilot build delivers Phase 1 slices and navigation summaries. It records invalid summary shapes and requires a non-empty root `AGENTS.md` alongside `README.md`.

The audit reports against this standard; it never edits a project.
Structure work ships as ordinary tasks, largest navigation wins first.

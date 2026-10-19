# Structure standard

This reference owns the universal repository baseline: layout, folder depth, per-folder navigation, file-size discipline, and entrypoints.
`bin/fm-repo-maintenance.sh structure` audits a repository against this standard; its header owns the exact checks and flags.

## Layout

- Modular `src/`: a domain-driven hierarchy (`src/<package>/<domain>/`) with presentation layers (`cli/`, `web/`) that consume domain packages and never the reverse.
- Folder depth: at most four levels below `src/` (`src/pkg/domain/subdomain/file.py`); deeper nesting costs navigation more than it buys organization.

## Per-folder navigation

- Every subdirectory carries a `SUMMARY.md`, at most 30 lines:
  - A substantive heading with the subsystem name.
  - A substantive `Role:` line with the single-sentence subsystem charter.
  - A table of every direct file in the folder: `` | `file.py` | responsibility | key exported symbols | ``. File and Responsibility cells are substantive; use `-` in Key Exported Symbols when a file exports none. Related files may share one row when each filename is an exact backticked entry in the File cell.
- A tracked file counts as listed when its basename is an exact File cell entry in its direct folder's `SUMMARY.md`; nested descendants do not satisfy an ancestor summary, substring lookalikes do not count, and the audit reports every file that is not.
- Write summaries from the code, not from guesses: open each file's public surface, name its responsibility in one phrase, and list its exports.
  Update the summary in the same change that adds, removes, or renames a file.

## File-size discipline

- Soft ceiling: 500 lines, binding on active operational logic, CLI dispatchers, routes, and domain modules.
- Exempt classes: pure schema definitions, test data fixtures, and verified cold offline batch paths.
- Exemptions are recorded per project in `data/repo-maintenance/<project>/exemptions.txt`, one `<path> :: <reason>` per line.
  An exemption without a reason is not an exemption; re-verify exemptions when the file's role changes.
- Over-ceiling files that are not exempt are findings, and a hot one is usually `DO FIRST`.

## Entrypoints and discoverability

- Root `README.md`: a heading and substantive body describing what the project is, how to set it up, and how to validate it.
- Root `AGENTS.md`: the task routing table mapping task to domain files to tests, with each Files and Tests cell pointing to a real tracked file. `CLAUDE.md` alone does not satisfy this entrypoint.
- Root-level tracked files other than the root entrypoints are accounted for only when a valid root route reaches them; otherwise the audit reports them as orphan files.
- Zero orphan files: every tracked file is reachable from its direct folder's `SUMMARY.md` or the root entrypoints.

## Rollout

1. This build delivered the pilot's initial Phase 1 slices and missing `SUMMARY.md` scaffolding. Phase 1 completion remains gated on three pending receipts: a green test suite, zero broken imports, and a measured token-consumption drop on subsequent tasks.
2. Phase 2 may begin only after all three pilot receipts are recorded and the remaining domain packages meet the four-level depth bound, per-folder summary standard, and unexempted 500-line ceiling.
3. A new repository is scaffolded to this standard from its first commit: `src/` layout, folder summaries, entrypoints, and the size ceiling.

The audit records invalid summary shapes and requires a non-empty root `AGENTS.md` alongside `README.md`.

The audit reports against this standard; it never edits a project.
Structure work ships as ordinary tasks, largest navigation wins first.

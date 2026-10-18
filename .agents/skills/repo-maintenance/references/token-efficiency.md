# Token efficiency

This reference owns the instrument's metric definitions, the Token Heat Index, the privacy guard, and the reading of the weekly ranking.
The mechanics - flags, environment seams, paths, and output schemas - live in the header of `bin/fm-repo-maintenance.sh` and are never restated here.

## Per-task metrics

`mine` records these aggregates for every task session it can attribute inside the window:

- `files_read` / `unique_files` - total and distinct file-read events (files opened).
- `reread_files` - files inspected three or more times inside one task (the re-read count).
- `tokens_total` / `tokens_exploration` - the session's harness-reported token counters, and the cumulative prompt tokens burned before the first state-changing edit (the token payload of exploration).
- `first_edit_turn` / `turns` - the turn index where the first edit lands, and the task's turn count (time to first edit).
- `dir` - the task's working directory as a sanitized label.

A session counts only when its working directory is under the home, a project clone, or a configured pool root, so personal and foreign sessions never enter the aggregates.
Codex sessions contribute session-level metrics only: codex reads files through the shell, which carries no structured file attribution, and the instrument never guesses paths out of command text.

## Token Heat Index

For each recorded file inside the window:

`THI = unique task reads x total reads x file token size`

- Unique task reads is the number of distinct tasks that opened the file.
- Total reads is every observed read event of that file.
- File token size is the file's working-tree size in bytes divided by four, falling back to the largest observed read payload for files that no longer exist (flagged `stale`).

A ranked file is `prioritized` when it exceeds the 500-line soft ceiling or its folder carries no `SUMMARY.md`.
The top three prioritized files are the sweep's "fix next" set and lead the weekly backlog intake.
The folder table aggregates THI per folder so a hot subsystem is visible even when no single file dominates.

Read the ranking as a work queue, not a verdict: a hot file that is cold, stable, and heavily tested is a `DO NOT DO` under the audit playbook's tri-state rules, while a hot file with no navigation and no summary is usually a `DO FIRST` structure fix.

## Privacy guard

Outputs are aggregates only, and the guard is enforced at extraction time:

- Prompts, diffs, message text, tool output, and file contents are never copied into outputs; only counts, sizes, and sanitized paths are.
- Paths under the home or pool roots are stored as a scope plus repo-relative path, for example `projects/<name>/src/module.py`; the absolute forms never appear.
- Local prefixes are sanitized to `<HOME>` and `<POOL>` labels; every other path is counted in the `external` bucket with no path recorded.
- Coverage records what was scanned, what was skipped, and why, so a partial run is never presented as a complete week.

## Coverage honesty

Every source reports one status (`mined`, `absent`, `sqlite3-missing`, `unreadable`) plus session counts and skip reasons (`skipped_cap`, `skipped_empty`, `skipped_error`).
When a source is absent or unreadable, say so in the report and in any captain-facing summary; never describe a partial dataset as the week's read picture.
A rising `skipped_empty` is normal (sessions updated inside the window whose messages are older), while a rising `skipped_error` means the store shape changed and the adapter needs attention.

## Weekly rhythm

1. Run `mine` once at the weekly boundary, before the per-project sweeps, so every project ranks against the same window.
2. Sweep each project and read its `fix next` list against the tri-state rules.
3. File the week's items per the audit playbook's filing rule, then leave the rest of the ranking as the next week's candidate pool.
4. Compare rankings week over week: a file that stays hot after its fix is evidence the fix missed the real seam.

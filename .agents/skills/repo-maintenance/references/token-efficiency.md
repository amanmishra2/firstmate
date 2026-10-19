# Token efficiency

This reference owns the instrument's metric definitions, the Token Heat Index, the privacy guard, and the reading of the weekly ranking.
The mechanics - flags, environment seams, paths, and output schemas - live in the header of `bin/fm-repo-maintenance.sh` and are never restated here.

## Per-task metrics

`mine` records these aggregates for every completed task span it can attribute inside the window:

- `files_read` / `unique_files` - total and distinct named file-read events (files opened).
- `reread_reads` - repeat read events after the first read of each file in one task; `three_plus_read_files` is a separate count of files read at least three times.
- `tokens_total` / `tokens_exploration` - the session's total usage counter, and prompt/input tokens before the first successful named edit. Output, reasoning, cache, and total usage counters do not enter `tokens_exploration`.
- `first_edit_turn` / `turns` - the turn index where the first named edit succeeds, and the task's turn count (time to first edit).
- `dir` - the task's working directory as a sanitized label.

A session counts only when its working directory is under the home, a project clone, or a configured pool root, so personal and foreign sessions never enter the aggregates.
The weekly window selects completed work by completion time: OpenCode uses `time_idle` with `idle_outcome`, and Codex pairs each `task_started` with its matching `task_complete` and selects spans by that completion timestamp.
Once a task span is selected, its events contribute, including turns before the window; later unfinished or out-of-window tasks in the same rollout cannot alter it.
Codex reads files through the shell, which carries no structured file attribution, and the instrument never guesses paths out of command text.
The OpenCode database and Codex sessions directory must resolve inside the physical `FM_HOME`; an external source override is skipped before enumeration and recorded only as `<EXTERNAL>` with status `outside-home`.

## Token Heat Index

For each recorded file inside the window:

`THI = distinct task reads x repeat read events x file token size`

- Unique task reads is the number of distinct tasks that opened the file.
- Repeat read events are every observed read after the first read by each task. A file read once by each task has zero repeat events and therefore zero THI.
- File token size is the file's working-tree size in bytes divided by four, falling back to the largest observed read payload for files that no longer exist (flagged `stale`).

A ranked file is `prioritized` when it exceeds the 500-line soft ceiling or its folder carries no `SUMMARY.md`.
The top three prioritized files are the sweep's "fix next" set and lead the weekly backlog intake.
The folder table aggregates THI per folder so a hot subsystem is visible even when no single file dominates.

Read the ranking as a work queue, not a verdict: a hot file that is cold, stable, and heavily tested is a `DO NOT DO` under the audit playbook's tri-state rules, while a hot file with no navigation and no summary is usually a `DO FIRST` structure fix.

## Privacy guard

Outputs are aggregates only, and the guard is enforced at extraction time:

- Prompts, diffs, message text, tool output, and file contents are never copied into outputs; only counts, sizes, and sanitized paths are.
- Project paths, code-root paths, and other paths under the approved home are stored relative to their matching scope; the absolute forms never appear.
- Local prefixes are sanitized to `<HOME>`, `<FIRSTMATE>`, and `<POOL>` labels; every other path is counted in the `external` bucket with no path recorded. Physical containment is checked after resolving symlinks, and traversal, exact roots, or unknown absolute paths become `<EXTERNAL>`.
- Coverage records what was scanned, what was skipped, and why, so a partial run is never presented as a complete week.

## Coverage honesty

Every source reports one status (`mined`, `empty`, `absent`, `sqlite3-missing`, `unreadable`, `outside-home`) plus session counts and skip reasons (`skipped_empty`, `skipped_error`, `skipped_scope`). An empty valid store remains distinct from a source that could not be read or a store that is outside `FM_HOME`.
When a source is absent or unreadable, say so in the report and in any captain-facing summary; never describe a partial dataset as the week's read picture.
A rising `skipped_empty` is normal, while a rising `skipped_error` means the store shape changed or candidate metadata was malformed and the adapter needs attention.

File coverage is intentionally narrow: only successful tool-attributed named `read` events are counted. Codex shell reads and shell-mediated edits are excluded, so an absent or zero row is not evidence that a path was inactive. First edit timing recognizes named edit tools only after a positive outcome (OpenCode edit/write/patch/apply_patch; Codex `FileChange` status `completed` or a `DynamicToolCall` completion with `success: true`). Codex `FunctionCallOutput` bodies and their completed items carry no success signal, so they remain unknown and do not stop exploration-token accumulation.

## Weekly rhythm

1. Run `mine` once at the weekly boundary, before the per-project sweeps, so every project ranks against the same window.
2. Sweep each project and read its `fix next` list against the tri-state rules.
3. File every confirmed finding and slice per the audit playbook's filing rule; use the top-three ranking to order the backlog, not to cap filing.
4. Compare rankings week over week: a file that stays hot after its fix is evidence the fix missed the real seam.

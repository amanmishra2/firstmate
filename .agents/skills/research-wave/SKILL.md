---
name: research-wave
description: Load on a `check: research wave request` wake, when a request exists under data/research-wave/ (request-<date>.*), or when running, continuing, or reviewing a research wave.
user-invocable: false
metadata:
  internal: true
---

# Research wave

A wave implements the research loop's ready sections as parallel ship workers and lands their PRs through the loop's own record-keeping.
The captain sees only escalations; everything else runs silently under ordinary supervision.
`bin/fm-wave-request.sh` writes the weekly request, `docs/research-wave.md` is the operator reference for the schedule and switches, and `bin/fm-notify.sh` is the escalation channel.

## Reading the request

- A request is one file `data/research-wave/request-<date>.md` carrying `period=`, `date=`, `at=`, `project=`, and `loop=` lines; `project` names the registered clone and `loop` is the dispatcher path inside it.
- Treat the request as read-only: it is the trigger record, and the scorecard below is the wave's record.
- A request with no scorecard is still owed a wave: run it once even when the wake was missed, and never re-run a request that already has a scorecard.
- If the loop refuses its handoff verb (for example the external-handoff half is not shipped yet), do not fall back to `--implement`: a local implement session would break the workers-outside-the-dispatcher boundary, so escalate through `bin/fm-notify.sh` and stop the wave for that period.

## Selecting sections

- Firstmate is the loop's single writer: run the loop only from the project's registered clone, and keep workers out of the dispatcher and out of `research/state.json` entirely.
- Resolve capacity first: the project's declaration in `config/project-capacity` (`bin/fm-project-capacity-lib.sh`) bounds how many wave sections are in flight at once, counting sections already adopted; with no declaration, use a conservative top three and say so in the scorecard.
- Run the loop's `--discover` (read-only candidate harvest into `research/backlog.json` in the clone) and read the candidates from that file.
- With `config/research-wave-auto-adopt` present the adoption gate is removed: adopt the top candidates by priority with `--adopt <id>` up to the capacity bound.
- Without that switch the gate is on: file the candidate question with `bin/fm-tasks-axi.sh add`, hold it through `bin/fm-captain-hold.sh hold <id> --reason "<question>"`, escalate it with `bin/fm-notify.sh`, and adopt nothing until the captain names the sections.
- Never adopt more sections than capacity allows, and never adopt one the loop already holds.

## Per section: handoff, brief, spawn

For each adopted slug, one section at a time:

1. Run the loop's handoff verb `--handoff-external <slug>`; its durable handoff record (slug, branch, base sha, report path, section identity) is the contract, and the loop owns its format.
2. Scaffold the brief: `bin/fm-brief.sh <slug>-<stamp> <project> --mode direct-PR --branch-prefix opt/`, where `<stamp>` is a UTC timestamp and the task id is `<slug>-<stamp>`.
3. Fill `## Captain's intent` from the section report and `## Firstmate spec` from the handoff record's branch, base sha, report path, and expected gates; never widen the section's scope.
4. Resolve dispatch with `bin/fm-dispatch-resolve.sh <brief>`; on `clear` pass its `profile:` line to the spawn unless you can state a reason to override, and on `ambiguous`, `escalate`, or `error` apply the ordinary intake rules rather than guessing.
5. Spawn: `bin/fm-spawn.sh <slug>-<stamp> <project-clone-dir> --mode direct-PR --yolo <on|off> --branch-prefix opt/`, where yolo comes from `bin/fm-project-mode.sh <project>` (on only when the registry line carries `+yolo`).
6. A spawn that exits 75 (deferred beyond capacity) stays queued for a later wave turn; never drop the cap to force it.
7. Confirm the worker is processing the brief and handle any trust dialog through `harness-adapters`.

## PR to green

- Supervise each ship to its PR through the ordinary lifecycle (`ship-landing`); when the worker reports done, record the PR with `bin/fm-pr-check.sh <task-id> <pr-url>`, which also arms the merge poll for a merge by any hand.
- On every heartbeat wake and at each wave review, reconcile each unmerged wave PR with `bin/fm-pr-state.sh <pr-url>` (or `gh pr checks`) before deciding anything.
- Green: with yolo on, merge with `bin/fm-pr-merge.sh <task-id> <pr-url>`; with yolo off, escalate the ready PR and wait for the captain.
- Red: at most two bounded fix rounds per PR. Steer the live worker with `bin/fm-send.sh <task-id>` naming the failing check and its logs; only a worker that is gone gets a replacement fix task (same mode, same branch).
- After two rounds without green, escalate with the failing check named and stop fixing that section; leave the PR open for the loop and the captain.
- Never merge a red PR, and never merge a destructive or security-sensitive change (credential handling, deletion, auth surfaces, or anything the section report flags); escalate it instead.

## Loop attach and the scorecard

- After a section merges, relay it to the loop with its attach verb (shipped as `--attach-external <slug> --pr-url <url> --worktree <path>`; confirm the exact name from the loop's help), which runs the loop's gates and live evidence and records the PR.
- Run at most one attach at a time: the live passes share PG/Redis across sections, and concurrent passes corrupt each other's evidence.
- Keep the task's worktree until attach has recorded the section, then land and clean up the task through the ordinary lifecycle.
- When every adopted section is merged and attached, or escalated and parked, write `data/research-wave/<date>-scorecard.md` for the request's date with one row per section recording: spawn success, supervision interventions, CI fix rounds, manual interventions, teardown cleanliness, time-to-green, lost work, and wrong status or double action, plus a short notes section for anything a row cannot say.
- Keep the scorecard honest: lost work, a wrong status, or a double action is recorded even when it was fixed later.

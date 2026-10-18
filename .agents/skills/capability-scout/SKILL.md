---
name: capability-scout
description: Load on the first weekly review of each month or a CAPABILITY_SCOUT_DUE line when the monthly capability scout is due. Runs the light monthly cadence that brings validated outside capabilities into fleet stores.
---

# Capability scout

The fleet's light monthly path for learning from the AI software engineering ecosystem without a platform project, daemon, subscription, or bulk import.
This skill owns the procedure; `bin/fm-capability-scout.sh` owns the cadence date arithmetic, and the foundation report at `data/firstmate-capability-scout/report.md` stays the evidence archive for the first sweep.

## Cadence

The scout rides the first weekly review of each month as one bounded session; there is no separate scheduler.
At the first weekly review, consult the script's documented due check and follow its documented reservation, start, recording, or release workflow.
If a sweep is due, hand off exactly one scout session on the configured `agy` scout profile and keep it bounded to about 15-20 minutes.
The script header owns command syntax, return values, claim recovery, and anchor semantics.
Never open a second session for the same month, and do not add a scheduler or standing service around this cadence.

The session scans, read-only: newly starred upstreams, watched tool releases, and the local plugin and skill caches.
It writes its findings as a dated report in the capability-scout data directory described in [the operational-home layout](../../../docs/configuration.md), and the weekly review consumes that report and may carry at most one selected candidate into the coming week's action drafts.
When nothing passes the gates, the report says `NO_CANDIDATE_PASSED` with its rejection notes; that is a complete session, not a failure.

## Bounded trial wave

A wave holds 1-3 skills, and bulk imports are prohibited.
Trial evidence requires a recorded operational friction (a report, a learnings entry, or a task record), a counterfactual comparison against the current way of working, and artifact receipts: exact commands, diffs, output paths, and measured time or token deltas.
Claims without verifiable receipts stay unverified and are discarded.

For every future wave, the security gate must return a verdict before any candidate evaluation or execution; before that verdict, only static documentation inspection is allowed, and candidate code is never run.
Every candidate then passes the security gate first, using SkillSpector (`~/.local/bin/skillspector`) with static analysis (`--no-llm`) and the report archived under the task's data directory.
Apply the scanner's own recommendation: SAFE proceeds to trial; CAUTION (score 0-45) needs manual clearance confirming `metadata.has_executable_scripts: false` and that every hit is documentation, a regex pattern, or a benign instruction, plus a filed baseline; DO_NOT_INSTALL (above 45, critical severity, YARA hits, prompt injection, or force-push and remote-execution instructions) is blocked wholesale as files.
A `DO_NOT_INSTALL` candidate is never executed as fleet tooling.
When the blocked files carry a valuable idea, re-implement only the idea in our own words and discard the files.

A trialed candidate then faces the durable-learning bar:
Counterfactual necessity - if this disappeared, would a future agent fail, repeat a known mistake, or waste significant tokens?
Non-duplication - an existing instruction, skill, or owner already covering the behavior means merging the improvement into that owner, never a competing skill.
Maintenance versus yield - external binaries, packages, tokens, daemons, or ongoing synchronization that outweigh the yield mean rejection or a static markdown form instead.

## Disposition and stores

- Adopt an agent procedure as a skill under this repo's `.agents/skills/` with a load trigger in its description, and register the surface in `docs/documentation-audiences.json`.
- Adopt a worker-facing rule by distilling it into the existing owner (`bin/fm-brief.sh`, `bin/fm-dod-lib.sh`, or the relevant skill), never as a second full copy.
- Adopt an operator fact into the classified prose owner for its audience.
- Reject with a permanent note in the committed repo record `.agents/skills/capability-scout/references/rejections.md` and mirror it to the private home record `data/capability-scout/rejections.md`; each note has the candidate name, version or revision, exact finding and scores, date, and reason, so later sweeps do not re-evaluate it.

## Boundaries

Never install a trial candidate into another project, a global config, or a shared store during the trial; trials run in a disposable copy and the adopting change lands through the normal firstmate delivery path.
Never touch the job-search Gemini API rotation pool.

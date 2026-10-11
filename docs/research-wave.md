# Research waves

A research wave implements the research loop's ready sections as parallel ship workers once a week: each section is handed off to a worker, implemented, watched to green CI, merged under the project's standing merge authority, and attached back to the loop.
Waves run silently; the captain sees only escalations.

The agent-side procedure lives in [the research-wave skill](../.agents/skills/research-wave/SKILL.md); this page is the operator reference for the weekly trigger, the switches, and the rollback.

## The weekly trigger

[`bin/fm-wave-request.sh`](../bin/fm-wave-request.sh) writes one durable request per ISO week at `data/research-wave/request-<date>.md` and wakes firstmate with a `check: research wave request <date>` line.
The request is idempotent per week: a second run in the same week reports the existing request and writes nothing.
When no live firstmate session holds the home's lock, the script writes no request at all: it appends an escalation through [`bin/fm-notify.sh`](../bin/fm-notify.sh) to `data/escalations.log` (and shows a macOS notification, best-effort), so a request can never sit unread in an empty home.

## Install the weekly schedule

Installing the schedule is a deliberate operator step; nothing in the wave installs it.

1. Save the plist below as `~/Library/LaunchAgents/com.firstmate.research-wave.plist`, substituting this home's absolute path for the placeholder, and make sure `data/research-wave/` exists under the home.
2. Load it: `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.firstmate.research-wave.plist`.
3. Confirm it is loaded: `launchctl print gui/$(id -u)/com.firstmate.research-wave | head -5`.
4. Prove the wiring by hand once: `bin/fm-wave-request.sh`.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.firstmate.research-wave</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>/absolute/path/to/firstmate/bin/fm-wave-request.sh</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Weekday</key>
    <integer>1</integer>
    <key>Hour</key>
    <integer>9</integer>
    <key>Minute</key>
    <integer>0</integer>
  </dict>
  <key>StandardOutPath</key>
  <string>/absolute/path/to/firstmate/data/research-wave/launchd.out.log</string>
  <key>StandardErrorPath</key>
  <string>/absolute/path/to/firstmate/data/research-wave/launchd.err.log</string>
</dict>
</plist>
```

`Weekday 1` is Monday, so launchd runs the request at 09:00 local time each week.
The script resolves this home from its own location, so the plist needs no environment.

## Switches

- **Capacity** - `config/project-capacity` in this home bounds how many wave sections are in flight at once; [`bin/fm-project-capacity-lib.sh`](../bin/fm-project-capacity-lib.sh) owns the declaration and [configuration.md](configuration.md#project-capacity-configproject-capacity) documents it. A spawn beyond the declaration defers (exit 75) and stays queued for a later wave turn. With no declaration the wave adopts a conservative top three.
- **Merge autonomy** - the `+yolo` token on the project's `data/projects.md` line is the standing authority for the wave's green merges; [`bin/fm-project-mode.sh`](../bin/fm-project-mode.sh) resolves it, and without the token every wave PR waits for the captain's word.
- **Adoption gate** - `config/research-wave-auto-adopt` present removes the captain's per-candidate adoption gate: the wave adopts the top candidates by priority up to capacity by itself. The file's contents are ignored; its presence is the switch. Absent (the default), the wave asks the captain which candidates to adopt and adopts nothing until told.

## Rollback per stage

Roll back innermost first; each stage stops cleanly and leaves landed work in place.

- Stop new sections: remove `config/research-wave-auto-adopt`. The adoption gate returns and the wave waits for the captain before adopting anything.
- Stop automatic merges: drop `+yolo` from the project's registry line. Every open wave PR then waits for the captain's merge word.
- Throttle the wave: lower the project's capacity in `config/project-capacity`. Capacity is a positive integer; `0` is not a valid declaration - it makes the whole declaration unreadable and refuses every spawn from this machine - so stop the wave with the switches above rather than with a zero.
- Stop the weekly trigger entirely: `launchctl bootout gui/$(id -u)/com.firstmate.research-wave`, then remove the plist. Sections already under way finish under ordinary supervision.

## Where to look

- Requests: `data/research-wave/request-<date>.md`.
- Scorecards: `data/research-wave/<date>-scorecard.md`, one row per section (spawn success, interventions, CI fix rounds, teardown cleanliness, time-to-green, lost work, wrong status or double action).
- Escalations: `data/escalations.log`, appended by [`bin/fm-notify.sh`](../bin/fm-notify.sh).

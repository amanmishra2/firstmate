Mode: OpenCode TUI plugin background wake.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. First cycle: let `.opencode/plugins/fm-primary-watch-arm.js` arm supervision after the OpenCode session's execution ends.
   Every execution end is a fresh first-cycle opportunity, so a restarted server, a reloaded plugin, or a plugin instance that never armed is repaired on the next idle instead of waiting for a previous cycle to close.
3. The plugin listens for the execution-terminal events (`session.execution.succeeded`/`failed`/`interrupted`; OpenCode 2 never emits the V1 `session.idle`), spawns `bin/fm-watch-arm.sh --arm` without awaiting it in the handler, and owns every later successor launch.
   `--arm` is attach-or-start: a duplicate that lands while a healthy watcher already holds this home's singleton follows that cycle instead of stopping it.
4. After an actionable child close, the plugin verifies one singleton successor before it calls `ctx.session.prompt`; its bounded fallback is defined in `docs/watcher-continuity.md`.
5. Ordinary wake: do not ask the model to re-arm because continuity is plugin-owned.
6. An unexpected child close enters bounded exponential retry, and an exhausted retry or a provably live foreign session lock is surfaced as a watcher failure instead of disappearing.
7. Failure or missing cycle only: if the plugin reports a watcher failure, drain queued wakes, inspect the failure text, and use `bin/fm-watch-arm.sh` manually only as a short recovery probe.
8. Never use shell `&` for watcher supervision.
   The arm mechanism above is plugin-owned, not a model tool call, but a manual recovery probe that backgrounds, pipes, or bundles the arm is denied automatically by the PreToolUse seatbelt (`.opencode/plugins/fm-primary-pretool-check.js`, `bin/fm-arm-pretool-check.sh`).
9. Do not rely on this plugin in headless `opencode run`; firstmate primary supervision targets persistent OpenCode TUI sessions.

OpenCode's persistent TUI plugin runtime is the wake mechanism.
The plugin applies in the main primary checkout and a secondmate's own home.
An instance loaded from any other root - a crewmate or scout worktree, or a copy whose inherited `FM_ROOT_OVERRIDE` names a checkout other than the one the plugin file lives in - is inert: it performs no session-lock read, no watcher check, and no arm against that home.
`FM_HOME` naming a state directory outside the checkout stays supported and is not what makes a copy foreign.
Every declined arm or skip appends one typed line to the home's `state/.watch-arm-plugin.log` naming its reason (`foreign-root`, `not-primary-root`, `lock-owned`, `lock-unknown`, `supervision-not-needed`, `arm-slot-live`, `arm-running`, `retry-scheduled`) and the watcher and session-lock facts it decided on.
A home that cannot write that log falls back to the server's console, so the trace is never lost entirely.

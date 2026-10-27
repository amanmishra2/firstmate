#!/usr/bin/env bash
# tests/fm-opencode-watch-arm-succession.test.sh - the OpenCode watch-arm
# plugin's succession contract after an actionable close.
#
# The plugin owns watcher re-arm on OpenCode (docs/watcher-continuity.md
# "Ownership"), so every successor it starts must join or start this home's ONE
# watcher cycle. This pins the behaviours whose absence produced the continuity
# storm: successors are started in attach-or-start mode (never a bare
# `--restart`, which force-stops a healthy live watcher), only one succession
# runs at a time even when another instance already claimed it, a different
# instance can never release that claim, an actionable close that overlaps a
# restoration or an in-flight prompt is still delivered, a typed stalled-holder
# close is the one escalation that force-restarts, the location gate admits this
# home's subdirectories but not a project clone, and the readiness budget
# follows the arm's own confirmation budget instead of undercutting it.
#
# The plugin is driven with fake plugin events, a fake arm, a real state
# directory, and a real session lock, so every case is a deterministic
# simulation rather than a real-time wait for a real watcher.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
TMP_ROOT=$(fm_test_tmproot fm-opencode-watch-arm-succession)

# Shared driver harness: import the real plugin, build a client whose session
# location the test can move, and capture every follow-up prompt the plugin
# would send. `promptRef.delayMs` makes the prompt slow enough for a second
# close to overlap it.
cat > "$TMP_ROOT/harness.mjs" <<'JS'
import { pathToFileURL } from "node:url";

const lab = process.env.LAB;
const promptRef = { text: "", texts: [], delayMs: 0 };
const session = { directory: lab };
// The client shape the plugin's exported hook body consumes: `session.get`
// resolves the idle event's session location so the plugin can apply its
// home/root/descendant gate, and `session.prompt` is the V2 delivery call
// (`{ sessionID, text }`) the plugin's follow-up sends.
const client = {
  session: {
    get: async ({ sessionID }) => ({ data: { location: { directory: session.directory }, id: sessionID } }),
    prompt: async ({ sessionID, text }) => {
      void sessionID;
      promptRef.text = text;
      promptRef.texts.push(text);
      if (promptRef.delayMs > 0) {
        await new Promise((resolve) => setTimeout(resolve, promptRef.delayMs));
      }
    },
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const hooks = await mod.FmPrimaryWatchArm({ client, worktree: lab });

// A second, cache-busted import is what a plugin reload actually produces: a
// fresh module instance whose module-level `child` and claim owner are not the
// ones the first instance wrote. The location is unchanged.
const instances = [{ mod, hooks }];
async function reloadHooks() {
  const suffix = `?reload=${instances.length}`;
  const next = await import(pathToFileURL(process.env.PLUGIN).href + suffix);
  const nextHooks = await next.FmPrimaryWatchArm({ client, worktree: lab });
  instances.push({ mod: next, hooks: nextHooks });
  return { mod: next, hooks: nextHooks };
}

async function waitFor(predicate, ms = 8000) {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    if (await predicate()) return true;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  return false;
}

export { client, hooks, mod, promptRef, reloadHooks, session, waitFor };
JS

# Sets HOLDER_PID to a live process. A command substitution here would make the
# holder a child of that subshell (and block on its inherited stdout), leaving a
# dead pid in the fixture.
HOLDER_PID=
sleep_holder() {
  sleep 60 &
  HOLDER_PID=$!
}

make_lab() { # <name> -> lab root with a primary-shaped checkout and a fake arm
  local name=$1 lab
  lab="$TMP_ROOT/$name"
  mkdir -p "$lab/bin" "$lab/state" "$lab/config" "$lab/projects"
  git init -q "$lab"
  git -C "$lab" commit -q --allow-empty -m init
  : > "$lab/AGENTS.md"
  : > "$lab/state/task1.meta"
  printf '%s\n' "$$" > "$lab/state/.lock"
  : > "$lab/config/supervision-host-off"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$lab/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-operational-input.sh" "$lab/bin/fm-operational-input.sh"
  cp "$ROOT/bin/fm-supervision-engine-lib.sh" "$lab/bin/fm-supervision-engine-lib.sh"
  cp "$ROOT/bin/fm-afk-contract.sh" "$lab/bin/fm-afk-contract.sh"
  # The plugin asks the shared libraries whether a live watcher already holds
  # this home and whether another live session owns its lock; a home-shaped lab
  # carries the same owners rather than a test-local reimplementation of them.
  cp "$ROOT/bin/fm-wake-lib.sh" "$lab/bin/fm-wake-lib.sh"
  cp "$ROOT/bin/fm-path-lib.sh" "$lab/bin/fm-path-lib.sh"
  cp "$ROOT/bin/fm-session-lock-lib.sh" "$lab/bin/fm-session-lock-lib.sh"
  cp "$ROOT/bin/fm-cursor-lib.sh" "$lab/bin/fm-cursor-lib.sh"
  # One behaviour per invocation, so a test can make the first arm close with a
  # wake and every successor settle as a live watcher.
  : > "$lab/modes"
  : > "$lab/arm-pids"
  cat > "$lab/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$$" >> "$LAB/arm-pids"
printf '%s\n' "$*" >> "$LAB/arm-calls"
n=$(cat "$LAB/arm-count" 2>/dev/null || printf 0)
n=$((n + 1))
printf '%s\n' "$n" > "$LAB/arm-count"
printf 'confirm=%s\n' "${FM_ARM_CONFIRM_TIMEOUT:-unset}" >> "$LAB/arm-env"
mode=$(sed -n "${n}p" "$LAB/modes")
[ -n "$mode" ] || mode=started
case "$mode" in
  wake)
    printf 'check: heartbeat\n'
    exit 0
    ;;
  attached)
    printf 'watcher: attached pid=%s (beacon 2s)\n' "${LAB_WATCHER_PID:-4242}"
    sleep 30
    ;;
  stalled)
    printf 'watcher: FAILED - attached watcher pid=424242 stalled (beacon 9000s at or past hard bound 900s)\n'
    exit 1
    ;;
  slow-started)
    sleep 2
    printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
    sleep 30
    ;;
  *)
    printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
    sleep 30
    ;;
esac
SH
  chmod +x "$lab/bin/fm-watch-arm.sh"
  printf '%s\n' "$lab"
}

kill_recorded_arms() { # <lab>
  local pid
  [ -f "$1/arm-pids" ] || return 0
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null || true
  done < "$1/arm-pids"
}

run_driver() { # <lab> <driver-file> [extra env assignment...] -> stdout; returns the driver's status
  local lab=$1 driver=$2 out status
  shift 2
  # Clear the ambient home overrides: the plugin under test must resolve this
  # lab, never whichever home happened to start the suite.
  out=$(cd "$TMP_ROOT" && env -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_CONFIG_OVERRIDE LAB="$lab" PLUGIN="$PLUGIN" \
    FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    FM_WATCH_REARM_RETRY_LIMIT=2 "$@" node "$driver" 2>&1)
  status=$?
  printf '%s' "$out"
  return "$status"
}

arm_call_count() { # <lab>
  if [ -f "$1/arm-calls" ]; then wc -l < "$1/arm-calls" | tr -d ' '; else printf 0; fi
}

recorded_arm_pid() { # <lab> <1-based index>
  sed -n "${2}p" "$1/arm-pids" 2>/dev/null
}

plugin_log() { # <lab>
  cat "$1/state/.watch-arm-plugin.log" 2>/dev/null || true
}

test_successor_does_not_restart_a_live_watcher() {
  local lab out driver
  lab=$(make_lab successor-mode)
  printf 'wake\nstarted\n' > "$lab/modes"
  driver="$TMP_ROOT/successor.mjs"
  cat > "$driver" <<'JS'
import { hooks, promptRef, waitFor } from "./harness.mjs";

await hooks.event({ event: { type: "session.idle", properties: { sessionID: "ses_test" } } });
if (!(await waitFor(async () => promptRef.texts.length > 0))) {
  console.error("the actionable close delivered no wake prompt");
  process.exit(1);
}
if (!promptRef.text.includes("WATCHER FIRED")) {
  console.error("unexpected wake prompt: " + promptRef.text);
  process.exit(1);
}
JS
  out=$(run_driver "$lab" "$driver") || { kill_recorded_arms "$lab"; fail "succession driver failed: $out"; }
  kill_recorded_arms "$lab"
  [ -s "$lab/arm-calls" ] || fail 'no arm was started at all'
  [ "$(grep -c -- '--arm$' "$lab/arm-calls")" -ge 2 ] \
    || fail "the actionable close did not start a successor: $(cat "$lab/arm-calls")"
  if grep -q -- '--restart' "$lab/arm-calls"; then
    fail "an ordinary successor force-restarted instead of joining the cycle: $(cat "$lab/arm-calls")"
  fi
  pass 'an actionable close starts exactly one attach-or-start successor and never force-restarts a live watcher'
}

test_live_succession_claim_blocks_a_second_successor() {
  local lab out driver holder
  lab=$(make_lab claim-in-flight)
  printf 'wake\nstarted\n' > "$lab/modes"
  sleep_holder
  holder=$HOLDER_PID
  printf 'owner=foreign-instance\npid=%s\nat=%s\npredecessor=1\n' "$holder" "$(( $(date +%s) * 1000 ))" \
    > "$lab/state/.watch-succession"
  driver="$TMP_ROOT/claim.mjs"
  cat > "$driver" <<'JS'
import { hooks, promptRef } from "./harness.mjs";

await hooks.event({ event: { type: "session.idle", properties: { sessionID: "ses_test" } } });
await new Promise((resolve) => setTimeout(resolve, 1500));
if (promptRef.texts.length > 0) {
  console.error("a live succession claim still produced a continuity failure prompt: " + promptRef.text);
  process.exit(1);
}
JS
  out=$(run_driver "$lab" "$driver")
  local status=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  kill_recorded_arms "$lab"
  [ "$status" -eq 0 ] || fail "claim driver failed: $out"
  [ ! -s "$lab/arm-calls" ] \
    || fail "a second successor was spawned while one succession was already claimed: $(cat "$lab/arm-calls")"
  pass 'a live home-scoped succession claim suppresses a duplicate successor without a false failure'
}

test_foreign_instance_cannot_release_a_live_claim() {
  local lab out driver holder
  lab=$(make_lab foreign-release)
  sleep_holder
  holder=$HOLDER_PID
  printf 'owner=another-plugin-instance\npid=%s\nat=%s\n' "$holder" "$(( $(date +%s) * 1000 ))" \
    > "$lab/state/.watch-succession"
  driver="$TMP_ROOT/foreign-release.mjs"
  # A second plugin instance in the SAME process shares our pid; keying release
  # on the pid let it unlink this live claim mid-succession. The owner token is
  # the only thing that may release it.
  cat > "$driver" <<'JS'
import { mod } from "./harness.mjs";

const paths = { state: process.env.LAB + "/state" };
mod.releaseSuccession(paths);
JS
  out=$(run_driver "$lab" "$driver") || { kill "$holder" 2>/dev/null || true; fail "release driver failed: $out"; }
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ -f "$lab/state/.watch-succession" ] \
    || fail 'a different instance released a live succession claim it did not own'
  grep -qx 'owner=another-plugin-instance' "$lab/state/.watch-succession" \
    || fail "the live claim changed shape: $(cat "$lab/state/.watch-succession")"
  pass 'a different instance in the same process cannot release a live succession claim'
}

test_close_during_in_flight_prompt_is_still_delivered() {
  local lab out driver
  lab=$(make_lab prompt-overlap)
  # The first arm closes actionable; the successor closes actionable again while
  # the first prompt is still in flight.
  printf 'wake\nwake\nstarted\n' > "$lab/modes"
  driver="$TMP_ROOT/prompt-overlap.mjs"
  cat > "$driver" <<'JS'
import { hooks, promptRef, waitFor } from "./harness.mjs";

promptRef.delayMs = 300;
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "ses_test" } } });
if (!(await waitFor(async () => promptRef.texts.length >= 2, 6000))) {
  console.error(
    "a wake that closed during an in-flight prompt was dropped; prompts=" + promptRef.texts.length,
  );
  process.exit(1);
}
if (!promptRef.texts[promptRef.texts.length - 1].includes("WATCHER FIRED")) {
  console.error("the overlapping wake did not arrive as a wake: " + promptRef.text);
  process.exit(1);
}
JS
  out=$(run_driver "$lab" "$driver") || { kill_recorded_arms "$lab"; fail "overlap driver failed: $out"; }
  kill_recorded_arms "$lab"
  pass 'a wake that closes during an in-flight prompt is delivered instead of dropped'
}

test_stalled_close_escalates_to_one_force_restart() {
  local lab out driver
  lab=$(make_lab stalled-escalation)
  # First close is actionable; its successor reports the typed stalled-holder
  # line while that restoration is running; the next attempt must escalate.
  printf 'wake\nstalled\nstarted\n' > "$lab/modes"
  driver="$TMP_ROOT/stalled.mjs"
  cat > "$driver" <<'JS'
import { hooks, promptRef, waitFor } from "./harness.mjs";

await hooks.event({ event: { type: "session.idle", properties: { sessionID: "ses_test" } } });
if (!(await waitFor(async () => promptRef.texts.length > 0, 6000))) {
  console.error("the stalled escalation never delivered the wake");
  process.exit(1);
}
JS
  out=$(run_driver "$lab" "$driver") || { kill_recorded_arms "$lab"; fail "stalled driver failed: $out"; }
  kill_recorded_arms "$lab"
  [ "$(grep -c -- '--restart$' "$lab/arm-calls")" -eq 1 ] \
    || fail "a stalled holder must escalate to exactly one force-restart: $(cat "$lab/arm-calls")"
  [ "$(sed -n '1p' "$lab/arm-calls")" = '--arm' ] \
    || fail "the first successor was not attach-or-start: $(cat "$lab/arm-calls")"
  [ "$(sed -n '2p' "$lab/arm-calls")" = '--arm' ] \
    || fail "the attempt that followed the stall was not the escalation: $(cat "$lab/arm-calls")"
  pass 'a typed stalled-holder close escalates to exactly one home-scoped force-restart'
}

test_location_gate_admits_subdirectories_but_not_project_clones() {
  local lab out driver
  lab=$(make_lab location-gate)
  printf 'started\n' > "$lab/modes"
  mkdir -p "$lab/sub/deeper" "$lab/projects/clone" "$lab/nested"
  git init -q "$lab/nested"
  driver="$TMP_ROOT/location.mjs"
  cat > "$driver" <<'JS'
import { hooks, promptRef, session, waitFor } from "./harness.mjs";

async function armsFor(directory, ms = 2500) {
  session.directory = directory;
  const before = promptRef.texts.length;
  await hooks.event({ event: { type: "session.idle", properties: { sessionID: "ses_test" } } });
  await new Promise((resolve) => setTimeout(resolve, ms));
  return promptRef.texts.length - before;
}

const lab = process.env.LAB;
// A project clone below the home is another repository served by the same
// server: arming there delivers firstmate's notifications into that window.
session.directory = lab + "/projects/clone";
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "ses_test" } } });
await new Promise((resolve) => setTimeout(resolve, 1500));
if (promptRef.texts.length > 0) {
  console.error("a project-clone session was treated as this home's session");
  process.exit(1);
}
// A nested repository outside the projects directory is foreign for the same
// reason.
session.directory = lab + "/nested";
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "ses_test" } } });
await new Promise((resolve) => setTimeout(resolve, 1500));
if (promptRef.texts.length > 0) {
  console.error("a nested repository was treated as this home's session");
  process.exit(1);
}
// A subdirectory of this home is this home's session and must arm.
await armsFor(lab + "/sub/deeper", 500);
JS
  out=$(run_driver "$lab" "$driver") || { kill_recorded_arms "$lab"; fail "location driver failed: $out"; }
  kill_recorded_arms "$lab"
  [ -s "$lab/arm-calls" ] \
    || fail 'a subdirectory session never armed supervision'
  pass "a subdirectory session arms, while a project clone or nested repository does not"
}

test_containment_uses_host_path_semantics() {
  local lab out driver
  lab=$(make_lab containment)
  driver="$TMP_ROOT/containment.mjs"
  cat > "$driver" <<'JS'
import { win32 } from "node:path";
import { mod } from "./harness.mjs";

const posix = (directory, base) => mod.directoryWithin(directory, base);
if (!posix(process.env.LAB + "/sub", process.env.LAB)) {
  console.error("a POSIX subdirectory was not contained");
  process.exit(1);
}
if (posix(process.env.LAB + "2", process.env.LAB)) {
  console.error("a sibling that shares a prefix was treated as contained");
  process.exit(1);
}
const windows = (directory, base) =>
  mod.directoryWithin(directory, base, win32.relative, win32.isAbsolute);
if (!windows("C:\\lab\\sub", "C:\\lab")) {
  console.error("a win32 subdirectory was not contained");
  process.exit(1);
}
if (windows("C:\\lab2", "C:\\lab")) {
  console.error("a win32 sibling that shares a prefix was treated as contained");
  process.exit(1);
}
if (windows("D:\\lab", "C:\\lab")) {
  console.error("a path on another win32 volume was treated as contained");
  process.exit(1);
}
JS
  out=$(run_driver "$lab" "$driver") || fail "containment driver failed: $out"
  kill_recorded_arms "$lab"
  pass 'containment uses host path semantics, including win32 separators and volumes'
}

test_readiness_budget_follows_the_arm_confirmation_budget() {
  local lab out driver
  lab=$(make_lab readiness-budget)
  printf 'slow-started\n' > "$lab/modes"
  driver="$TMP_ROOT/readiness.mjs"
  cat > "$driver" <<'JS'
import { hooks, promptRef, waitFor } from "./harness.mjs";

await hooks.event({ event: { type: "session.idle", properties: { sessionID: "ses_test" } } });
if (await waitFor(async () => promptRef.texts.length > 0, 4000)) {
  console.error("a slow-but-successful starter was reported as a continuity failure: " + promptRef.text);
  process.exit(1);
}
JS
  # A tiny explicit ready override plus a starter slower than that override:
  # pre-fix the plugin used the override verbatim, declared the still-starting
  # arm a timeout, and reported a continuity failure. Post-fix its budget is
  # floored by the arm's own confirmation window, so the same starter is armed.
  out=$(run_driver "$lab" "$driver" FM_ARM_CONFIRM_TIMEOUT=1 FM_OPENCODE_ARM_READY_TIMEOUT_MS=1500) \
    || { kill_recorded_arms "$lab"; fail "readiness driver failed: $out"; }
  kill_recorded_arms "$lab"
  grep -qx 'confirm=1' "$lab/arm-env" \
    || fail "the plugin did not pass its confirmation budget to the arm: $(cat "$lab/arm-env")"
  [ "$(cat "$lab/arm-count" 2>/dev/null || printf 0)" = 1 ] \
    || fail "a starter inside its own budget was replaced: $(cat "$lab/arm-calls")"
  [ "$(cat "$lab/arm-calls")" = '--arm' ] \
    || fail "an arm that confirmed inside its own budget was retired or restarted: $(cat "$lab/arm-calls")"
  pass 'an arm that confirms inside its own budget is never reported as a failed starter'
}

# --- restart / reload / cross-root contract -------------------------------
#
# The live failure these cases pin: after the OpenCode server reloaded its
# plugins the home's session lock still named the pid of the session that had
# died, the plugin read "the recorded pid is not in my ancestry" as "another
# session owns this home", and every turn end declined to arm with nothing
# written anywhere. Supervision stayed down for nine hours until a manual probe
# and the turn-end guard finally saw it.

test_idle_without_watcher_starts_exactly_one_arm() {
  local lab out driver
  lab=$(make_lab idle-first-cycle)
  # The state a restarted server actually leaves: the home's session lock still
  # names the session that died. This pid can never exist, so the lock reads
  # stale and no live session owns this home.
  printf '%s\n' 2147483647 > "$lab/state/.lock"
  printf 'started\n' > "$lab/modes"
  driver="$TMP_ROOT/idle-first-cycle.mjs"
  # No prior arm, no prior actionable close, no plugin instance that ever
  # armed: this is the state a restarted server leaves behind.
  cat > "$driver" <<'JS'
import { readFileSync } from "node:fs";
import { hooks } from "./harness.mjs";

await hooks.event({ event: { type: "session.idle", properties: { sessionID: "ses_test" } } });
await new Promise((resolve) => setTimeout(resolve, 500));
// Assert from inside the running server: once this process exits, the arm it
// started is an orphan the test shell can no longer reason about.
const pids = readFileSync(process.env.LAB + "/arm-pids", "utf8").trim().split("\n");
const armPid = Number(pids[pids.length - 1]);
try {
  process.kill(armPid, 0);
} catch {
  console.error("the recorded successor is not live: " + armPid);
  process.exit(1);
}
const slot = readFileSync(process.env.LAB + "/state/.opencode-arm", "utf8");
if (!slot.includes(`pid=${armPid}\n`)) {
  console.error("the live successor was not recorded in the arm channel: " + slot);
  process.exit(1);
}
process.exit(0);
JS
  out=$(run_driver "$lab" "$driver") || { kill_recorded_arms "$lab"; fail "first-cycle driver failed: $out"; }
  arm_pid=$(recorded_arm_pid "$lab" 1)
  [ "$(arm_call_count "$lab")" = 1 ] || { kill_recorded_arms "$lab"; fail "a first idle started $(arm_call_count "$lab") arms instead of one: $(cat "$lab/arm-calls" 2>/dev/null)"; }
  grep -qx -- '--arm' "$lab/arm-calls" || { kill_recorded_arms "$lab"; fail "the first cycle did not use attach-or-start: $(cat "$lab/arm-calls")"; }
  [ -n "$arm_pid" ] || fail 'the first cycle recorded no arm pid'
  grep -q 'decision=arm reason=no-watcher' "$lab/state/.watch-arm-plugin.log" \
    || { kill_recorded_arms "$lab"; fail "the first arm recorded no reason: $(plugin_log "$lab")"; }
  grep -q 'lock=stale' "$lab/state/.watch-arm-plugin.log" \
    || { kill_recorded_arms "$lab"; fail "the arm did not record the stale lock it recovered from: $(plugin_log "$lab")"; }
  kill_recorded_arms "$lab"
  pass 'a stale lock after a restart still starts exactly one attach-or-start successor and records it live'
}

test_reload_reuses_the_live_arm_channel() {
  local lab out driver count
  lab=$(make_lab reload-attach)
  # The arm reports that it ATTACHED to a watcher that was already live; the
  # reloaded instance must not open a second wake channel to that same cycle.
  printf 'attached\nattached\n' > "$lab/modes"
  printf '%s\n' 424242 > "$lab/state/.watch.lock-pid" # only documentation; the fake arm renders its own line
  driver="$TMP_ROOT/reload-attach.mjs"
  cat > "$driver" <<'JS'
import { client, hooks, reloadHooks, waitFor } from "./harness.mjs";

const first = await hooks.coordinator.ensureArmed("ses_test", client);
if (first !== "armed") {
  console.error("the first instance did not confirm an attached arm: " + first);
  process.exit(1);
}
const reloaded = await reloadHooks();
const second = await reloaded.hooks.coordinator.ensureArmed("ses_test", client);
if (second !== "existing") {
  console.error("a reloaded instance did not join the live arm channel: " + second);
  process.exit(1);
}
// Also drive the reloaded instance's event path: it must stay a no-op.
await reloaded.hooks.event({ event: { type: "session.idle", properties: { sessionID: "ses_test" } } });
await waitFor(async () => false, 300);
process.exit(0);
JS
  out=$(run_driver "$lab" "$driver") || { kill_recorded_arms "$lab"; fail "reload driver failed: $out"; }
  count=$(arm_call_count "$lab")
  kill_recorded_arms "$lab"
  [ "$count" = 1 ] || fail "a plugin reload opened $count wake channels instead of attaching to the live one: $(cat "$lab/arm-calls")"
  pass 'a plugin reload attaches to the live watcher cycle instead of duplicating the arm channel'
}

test_foreign_root_instance_is_inert() {
  local lab foreign primary_lab
  lab=$(make_lab foreign-root-primary)
  primary_lab=$lab
  foreign="$TMP_ROOT/foreign-root-worktree"
  mkdir -p "$foreign/bin" "$foreign/state"
  git init -q "$foreign"
  git -C "$foreign" commit -q --allow-empty -m init
  : > "$foreign/AGENTS.md"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$foreign/bin/fm-supervision-lib.sh"
  cat > "$TMP_ROOT/foreign-root.mjs" <<'JS'
import { pathToFileURL } from "node:url";

const foreign = process.env.FOREIGN;
const primary = process.env.PRIMARY;
const client = {
  // The strongest adversarial input: the event even names a session inside the
  // primary home, so every gate but the foreign-root one would admit it.
  session: {
    get: async ({ sessionID }) => ({ data: { location: { directory: primary }, id: sessionID } }),
    prompt: async () => {},
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
// This copy resolves its OWN root to the worker worktree, while the inherited
// environment names the primary home: exactly the copy the OpenCode log showed
// loading from a task worktree into the primary's server.
const hooks = await mod.FmPrimaryWatchArm({ client, worktree: foreign });
const status = await hooks.coordinator.ensureArmed("ses_test", client);
if (status !== "not-primary") {
  console.error("a foreign-root copy did not decline: " + status);
  process.exit(1);
}
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "ses_test" } } });
process.exit(0);
JS
  out=$(run_driver "$primary_lab" "$TMP_ROOT/foreign-root.mjs" \
    FOREIGN="$foreign" PRIMARY="$primary_lab" \
    FM_ROOT_OVERRIDE="$primary_lab" FM_HOME="$primary_lab" FM_CONFIG_OVERRIDE="$primary_lab/config") \
    || fail "foreign-root driver failed: $out"
  [ ! -s "$primary_lab/arm-calls" ] \
    || fail "a foreign-root copy armed against the primary home: $(cat "$primary_lab/arm-calls")"
  [ ! -e "$primary_lab/state/.watch-succession" ] \
    || fail 'a foreign-root copy claimed the primary home succession'
  [ ! -e "$primary_lab/state/.opencode-arm" ] \
    || fail 'a foreign-root copy claimed the primary home arm channel'
  [ ! -e "$primary_lab/state/.watch-arm-plugin.log" ] \
    || fail "a foreign-root copy wrote into the primary home's state: $(plugin_log "$primary_lab")"
  grep -q 'reason=foreign-root' "$foreign/state/.watch-arm-plugin.log" \
    || fail "a foreign-root decline left no typed reason in its own checkout: $(plugin_log "$foreign")"
  pass 'a plugin copy loaded from a foreign root performs no lock, watcher, or arm operation against the primary home'
}

test_killed_arm_is_replaced_on_the_next_idle() {
  local lab out driver count
  lab=$(make_lab killed-arm)
  printf 'started\nstarted\n' > "$lab/modes"
  driver="$TMP_ROOT/killed-arm.mjs"
  cat > "$driver" <<'JS'
import { client, hooks, reloadHooks, waitFor } from "./harness.mjs";

const first = await hooks.coordinator.ensureArmed("ses_test", client);
if (first !== "armed") {
  console.error("the first arm never became ready: " + first);
  process.exit(1);
}
// Simulate the watcher cycle dying: its arm child is gone while the plugin
// instance that started it is no longer the one handling the next idle.
const pids = await import("node:fs").then((fs) =>
  fs.readFileSync(process.env.LAB + "/arm-pids", "utf8").trim().split("\n"),
);
const victim = Number(pids[pids.length - 1]);
process.kill(victim, "SIGTERM");
if (!(await waitFor(async () => {
  try {
    process.kill(victim, 0);
    return false;
  } catch {
    return true;
  }
}))) {
  console.error("the killed arm did not exit");
  process.exit(1);
}
const reloaded = await reloadHooks();
const second = await reloaded.hooks.coordinator.ensureArmed("ses_test", client);
if (second !== "armed") {
  console.error("the next idle did not replace the dead arm: " + second);
  process.exit(1);
}
process.exit(0);
JS
  # Long retry delays keep the dead instance's own retry out of this window, so
  # the replacement under test is the one the next idle starts.
  out=$(run_driver "$lab" "$driver" FM_WATCH_REARM_RETRY_BASE_MS=60000 FM_WATCH_REARM_RETRY_MAX_MS=60000) \
    || { kill_recorded_arms "$lab"; fail "killed-arm driver failed: $out"; }
  count=$(arm_call_count "$lab")
  kill_recorded_arms "$lab"
  [ "$count" = 2 ] || fail "a killed arm was replaced $count times instead of once: $(cat "$lab/arm-calls")"
  pass 'a killed watcher is replaced by exactly one successor on the next idle'
}

test_declined_arm_emits_its_typed_reason() {
  local lab out driver harness_pid fakebin
  lab=$(make_lab declined-reason)
  fakebin="$TMP_ROOT/declined-bin"
  mkdir -p "$fakebin"
  # A live verified harness in this home's lock, outside the server's own
  # ancestry: another session really does own this home, so arming here would
  # bind supervision to the wrong session.
  ln -sf /bin/sleep "$fakebin/opencode"
  "$fakebin/opencode" 60 &
  harness_pid=$!
  printf '%s\n' "$harness_pid" > "$lab/state/.lock"
  # Run the driver itself under a harness-shaped name so the shared ownership
  # query can tell "foreign" from "unknowable" for an ancestry that does contain
  # a harness, which is what the real OpenCode server always has.
  ln -sf "$(command -v node)" "$TMP_ROOT/harness-node/opencode" 2>/dev/null \
    || { mkdir -p "$TMP_ROOT/harness-node"; ln -sf "$(command -v node)" "$TMP_ROOT/harness-node/opencode"; }
  cat > "$TMP_ROOT/declined.mjs" <<'JS'
import { client, hooks } from "./harness.mjs";

const status = await hooks.coordinator.ensureArmed("ses_test", client);
if (status !== "read-only") {
  console.error("a live foreign lock did not decline the arm: " + status);
  process.exit(1);
}
process.exit(0);
JS
  out=$(cd "$TMP_ROOT" && env -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE \
    LAB="$lab" PLUGIN="$PLUGIN" "$TMP_ROOT/harness-node/opencode" "$TMP_ROOT/declined.mjs" 2>&1)
  local status=$?
  kill "$harness_pid" 2>/dev/null || true
  wait "$harness_pid" 2>/dev/null || true
  [ "$status" -eq 0 ] || fail "declined-arm driver failed: $out"
  [ "$(arm_call_count "$lab")" = 0 ] || fail "an arm ran despite a live foreign lock: $(cat "$lab/arm-calls")"
  grep -q 'decision=skip reason=lock-owned' "$lab/state/.watch-arm-plugin.log" \
    || fail "a declined arm emitted no typed reason: $(plugin_log "$lab")"
  pass 'a declined arm emits its typed reason instead of declining silently'
}

test_successor_does_not_restart_a_live_watcher
test_live_succession_claim_blocks_a_second_successor
test_foreign_instance_cannot_release_a_live_claim
test_close_during_in_flight_prompt_is_still_delivered
test_stalled_close_escalates_to_one_force_restart
test_location_gate_admits_subdirectories_but_not_project_clones
test_containment_uses_host_path_semantics
test_readiness_budget_follows_the_arm_confirmation_budget

test_idle_without_watcher_starts_exactly_one_arm
test_reload_reuses_the_live_arm_channel
test_foreign_root_instance_is_inert
test_killed_arm_is_replaced_on_the_next_idle
test_declined_arm_emits_its_typed_reason

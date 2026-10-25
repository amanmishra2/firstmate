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

async function waitFor(predicate, ms = 8000) {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    if (await predicate()) return true;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  return false;
}

export { client, hooks, mod, promptRef, session, waitFor };
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

test_successor_does_not_restart_a_live_watcher
test_live_succession_claim_blocks_a_second_successor
test_foreign_instance_cannot_release_a_live_claim
test_close_during_in_flight_prompt_is_still_delivered
test_stalled_close_escalates_to_one_force_restart
test_location_gate_admits_subdirectories_but_not_project_clones
test_containment_uses_host_path_semantics
test_readiness_budget_follows_the_arm_confirmation_budget

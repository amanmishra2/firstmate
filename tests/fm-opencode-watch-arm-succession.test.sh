#!/usr/bin/env bash
# tests/fm-opencode-watch-arm-succession.test.sh - the OpenCode watch-arm
# plugin's succession contract after an actionable close.
#
# The plugin owns watcher re-arm on OpenCode (docs/watcher-continuity.md
# "Ownership"), so every successor it starts must join or start this home's ONE
# watcher cycle. This pins the four behaviours whose absence produced the
# continuity storm: successors are started in attach-or-start mode (never
# `--restart`, which force-stops a healthy live watcher), only one succession
# runs at a time even when another caller already claimed it, a transient
# status is never reported as a continuity failure, and the readiness budget
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
# belongs to this lab, and capture the follow-up prompt the plugin would send.
cat > "$TMP_ROOT/harness.mjs" <<'JS'
import { pathToFileURL } from "node:url";

const lab = process.env.LAB;
const promptRef = { text: "" };
const client = {
  session: {
    get: async () => ({ data: { directory: lab } }),
    prompt: async ({ text }) => {
      promptRef.text = text;
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

export { hooks, promptRef, waitFor };
JS

make_lab() { # <name> -> lab root with a primary-shaped checkout and a fake arm
  local name=$1 lab
  lab="$TMP_ROOT/$name"
  mkdir -p "$lab/bin" "$lab/state" "$lab/config"
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
  cat > "$lab/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
set -u
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

run_driver() { # <lab> <driver-file>
  local lab=$1 driver=$2 out
  out=$(cd "$TMP_ROOT" && LAB="$lab" PLUGIN="$PLUGIN" \
    FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    FM_WATCH_REARM_RETRY_LIMIT=2 node "$driver" 2>&1)
  printf '%s' "$out"
}

test_successor_never_restarts_a_live_watcher() {
  local lab out driver
  lab=$(make_lab successor-mode)
  printf 'wake\nstarted\n' > "$lab/modes"
  driver="$TMP_ROOT/successor.mjs"
  cat > "$driver" <<'JS'
import { hooks, promptRef, waitFor } from "./harness.mjs";

await hooks.event({ event: { type: "session.idle", properties: { sessionID: "ses_test" } } });
if (!(await waitFor(async () => promptRef.text.length > 0))) {
  console.error("the actionable close delivered no wake prompt");
  process.exit(1);
}
if (!promptRef.text.includes("WATCHER FIRED")) {
  console.error("unexpected wake prompt: " + promptRef.text);
  process.exit(1);
}
JS
  out=$(run_driver "$lab" "$driver") || fail "succession driver failed: $out"
  [ -s "$lab/arm-calls" ] || fail 'no arm was started at all'
  if grep -qv -- '--arm$' "$lab/arm-calls"; then
    fail "a successor was started with a force-restart mode instead of attach-or-start: $(cat "$lab/arm-calls")"
  fi
  [ "$(grep -c -- '--arm$' "$lab/arm-calls")" -ge 2 ] \
    || fail "the actionable close did not start a successor: $(cat "$lab/arm-calls")"
  pass 'an actionable close starts exactly one attach-or-start successor and never force-restarts a live watcher'
}

test_live_succession_claim_blocks_a_second_successor() {
  local lab out driver holder
  lab=$(make_lab claim-in-flight)
  printf 'wake\nstarted\n' > "$lab/modes"
  sleep 60 &
  holder=$!
  printf 'pid=%s\nat=%s\npredecessor=1\n' "$holder" "$(( $(date +%s) * 1000 ))" > "$lab/state/.watch-succession"
  driver="$TMP_ROOT/claim.mjs"
  cat > "$driver" <<'JS'
import { hooks, promptRef } from "./harness.mjs";

await hooks.event({ event: { type: "session.idle", properties: { sessionID: "ses_test" } } });
await new Promise((resolve) => setTimeout(resolve, 1500));
if (promptRef.text.length > 0) {
  console.error("a live succession claim still produced a continuity failure prompt: " + promptRef.text);
  process.exit(1);
}
JS
  out=$(run_driver "$lab" "$driver")
  local status=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ "$status" -eq 0 ] || fail "claim driver failed: $out"
  [ ! -s "$lab/arm-calls" ] \
    || fail "a second successor was spawned while one succession was already claimed: $(cat "$lab/arm-calls")"
  pass 'a live home-scoped succession claim suppresses a duplicate successor without a false failure'
}

test_readiness_budget_follows_the_arm_confirmation_budget() {
  local lab out driver
  lab=$(make_lab readiness-budget)
  printf 'slow-started\n' > "$lab/modes"
  driver="$TMP_ROOT/readiness.mjs"
  cat > "$driver" <<'JS'
import { hooks, promptRef, waitFor } from "./harness.mjs";

await hooks.event({ event: { type: "session.idle", properties: { sessionID: "ses_test" } } });
if (await waitFor(async () => promptRef.text.length > 0, 3000)) {
  console.error("a slow-but-successful starter was reported as a continuity failure: " + promptRef.text);
  process.exit(1);
}
JS
  out=$(FM_ARM_CONFIRM_TIMEOUT=1 run_driver "$lab" "$driver") || fail "readiness driver failed: $out"
  grep -qx 'confirm=1' "$lab/arm-env" \
    || fail "the plugin did not pass its confirmation budget to the arm: $(cat "$lab/arm-env")"
  if grep -q 'FAILED' "$lab/arm-calls"; then
    fail 'the plugin retired or replaced an arm that confirmed inside its own budget'
  fi
  pass 'an arm that confirms inside its own budget is never reported as a failed starter'
}

test_successor_never_restarts_a_live_watcher
test_live_succession_claim_blocks_a_second_successor
test_readiness_budget_follows_the_arm_confirmation_budget

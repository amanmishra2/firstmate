import { spawn, spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import {
  appendFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  renameSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { isAbsolute, relative, resolve } from "node:path";
import { encodeFirstmateOperationalInput } from "./lib/fm-operational-input.js";

// Supervision host: a home opted in with config/supervision-host
// (docs/configuration.md "Supervision host" owns the gate, which
// bin/fm-supervision-engine-lib.sh enabled answers; config/supervision-host-off opts out) spawns
// bin/fm-supervision-host.sh park --restart in the arm's place, which takes
// away-posture wakes itself and closes only when main is needed; its header
// owns the output read here. A "supervision-host:" line is actionable like a
// wake line, and the delivered message carries every such line in order while
// wake lines keep an eight-line cap. The host prints the first cycle's status
// line as soon as it is verified, so readiness and the handling handoff work
// as they do for the arm, with a longer readiness budget for the host's own
// startup. On a home that does not run the host nothing below changes.
const COORDINATOR_KEY = "__firstmateOpenCodeWatchArm";
// The arm's own startup confirmation budget. It is passed to every arm child
// explicitly so the plugin's readiness budget is derived from the SAME number
// the arm uses: a plugin budget below the arm's confirmation window reports a
// healthy starter as a timeout, retires it, and starts the churn this file
// exists to prevent.
// Git Bash/MSYS pays a much higher fork cost, and bin/fm-watch-arm.sh's own
// default there is 30s; the plugin must never derive a smaller budget than the
// platform default it is reasoning about.
const ARM_CONFIRM_SECONDS = positiveInteger(
  "FM_ARM_CONFIRM_TIMEOUT",
  process.platform === "win32" ? 30 : 10,
);
// Time allowed for a forked arm to report `watcher: started|attached` after its
// own confirmation budget. Conditioned on win32 so a slow Git Bash cold start
// keeps its historical headroom.
const ARM_READY_MARGIN_MS = process.platform === "win32" ? 25000 : 5000;
const ARM_READY_TIMEOUT_DEFAULT_MS =
  process.platform === "win32" ? 35000 : 12000;
const ARM_READY_TIMEOUT_MS = Math.max(
  positiveInteger("FM_OPENCODE_ARM_READY_TIMEOUT_MS", ARM_READY_TIMEOUT_DEFAULT_MS),
  ARM_CONFIRM_SECONDS * 1000 + ARM_READY_MARGIN_MS,
);
const HOST_READY_TIMEOUT_MS = Math.max(ARM_READY_TIMEOUT_MS, 30000);
const WAKE_LINE = /^(signal:|stale:|check:|heartbeat($|:))/;
const HOST_LINE = /^supervision-host:/;
// The V2 turn-end set: OpenCode 2 never emits the V1 session.idle event
// (verified live on 2.0.26), so each way an execution can stop triggers the
// same idle handling the V1 event carried. A shutdown interrupt is the app
// closing, not a turn end, and is skipped.
const TURN_END_TYPES = new Set([
  "session.execution.succeeded",
  "session.execution.failed",
  "session.execution.interrupted",
]);
const ARM_RETIRE_TIMEOUT_MS = positiveInteger("FM_WATCH_ARM_RETIRE_TIMEOUT_MS", 1000);
const REARM_RETRY_BASE_MS = positiveInteger("FM_WATCH_REARM_RETRY_BASE_MS", 250);
const REARM_RETRY_MAX_MS = positiveInteger("FM_WATCH_REARM_RETRY_MAX_MS", 4000);
const REARM_RETRY_LIMIT = positiveInteger("FM_WATCH_REARM_RETRY_LIMIT", 5);
// One succession at a time across every plugin instance and every coordinator
// caller. The claim is durable (a file under this home's state directory)
// because the duplicate-succession bug is exactly the case where two JS module
// instances cannot see each other's `child` handle.
const SUCCESSION_CLAIM = ".watch-succession";
const SUCCESSION_CLAIM_TTL_MS = Math.max(60000, ARM_READY_TIMEOUT_MS * 2);
// This plugin instance's claim identity. Keying the claim on process.pid alone
// let a second instance in the SAME process (two loader passes, or the
// turn-end guard's coordinator from another module copy) treat another
// instance's live claim as its own and release it mid-succession.
const SUCCESSION_OWNER = randomUUID();
// The durable arm channel for this home. `child` only exists in one JS module
// instance, so a reloaded module (a second loader pass, a cache-busted import,
// or the turn-end guard's coordinator reaching another copy) could not tell
// that this home already has a live arm attached to its watcher. Starting a
// second one does not start a second watcher - `--arm` attaches - but it does
// open a second wake-delivery channel, so one wake would be delivered twice.
// The slot records the arm child this server started; an arm left by an earlier
// server is deliberately not live, because its wake pipe died with that server.
const ARM_SLOT = ".opencode-arm";
// Every declined arm or skip writes one line here, because the failure this
// file just fixed was a SILENT one: a stale session lock read as "another
// session owns this home" and supervision stayed down for nine hours with no
// trace anywhere in the home. A bounded file keeps that trace without growing
// without limit across a long-lived home.
const DIAGNOSTIC_LOG = ".watch-arm-plugin.log";
const DIAGNOSTIC_LOG_MAX_BYTES = 256 * 1024;
const DIAGNOSTIC_LOG_KEEP_LINES = 400;

let child = null;
let armStatus = "idle";
let retryTimer = null;
let retryFailures = 0;
let launchInFlight = null;
let restorationInFlight = null;
let pendingWakeMessages = [];
// A stalled-holder close that arrives while a restoration is already running.
// The restoration loop reads this on its next attempt and escalates that
// attempt to the home-scoped force-restart, so the typed escalation is not
// lost just because it overlapped an earlier recovery.
let stalledEscalationPending = false;
let armClose = new WeakMap();
let armReadiness = new WeakMap();
let armRecovery = new WeakMap();
let armHostMode = new WeakMap();
// Last emitted decision, so a state that persists across many turn ends writes
// one line instead of one per turn while still logging every change.
let lastDecisionKey = "";

function positiveInteger(name, fallback) {
  const value = Number(process.env[name]);
  if (!Number.isFinite(value) || value <= 0) return fallback;
  return Math.floor(value);
}

function setArmStatus(status) {
  armStatus = status;
}

function waitForArmReady(armChild) {
  const readiness = armReadiness.get(armChild);
  if (!readiness) return Promise.resolve("failed");
  const timeout = armHostMode.get(armChild) ? HOST_READY_TIMEOUT_MS : ARM_READY_TIMEOUT_MS;
  return new Promise((resolve) => {
    const timer = setTimeout(() => resolve("timeout"), timeout);
    timer.unref();
    void readiness.then((status) => {
      clearTimeout(timer);
      resolve(status);
    });
  });
}

function runProcess(command, args, options = {}) {
  return new Promise((resolve) => {
    const proc = spawn(command, args, {
      stdio: ["ignore", "pipe", "pipe"],
      ...options,
    });
    let stdout = "";
    let stderr = "";
    proc.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    proc.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    proc.on("error", (error) => resolve({ code: 127, stdout, stderr: String(error?.message ?? error) }));
    proc.on("close", (code) => resolve({ code: code ?? 0, stdout, stderr }));
  });
}

async function resolveRoot(anchor) {
  if (!anchor) return "";
  const result = await runProcess("git", ["-C", anchor, "rev-parse", "--show-toplevel"]);
  const root = result.stdout.trim();
  if (result.code === 0 && root) return root;
  return resolvePath(anchor);
}

function resolvePath(anchor) {
  try {
    return realpathSync(anchor);
  } catch {
    return resolve(anchor);
  }
}

// `own` is the root this plugin COPY was loaded for, before any environment
// override. It is what makes a copy loaded from a worker worktree provably
// foreign: its own root can never be the home it would otherwise inherit from
// FM_HOME/FM_ROOT_OVERRIDE, so it can never arm against that home's state.
function effectivePaths(root) {
  const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
  const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || fmRoot;
  const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
  const config = process.env.FM_CONFIG_OVERRIDE || `${fmHome}/config`;
  return { root: fmRoot, home: fmHome, state, config, own: root };
}

// True only when this copy's own checkout IS the code root it is about to
// supervise. `FM_HOME` naming a different root stays supported and is checked
// separately: a home whose state lives outside the checkout is a documented
// layout, and the plugin still passes its own root to the arm. What is refused
// is an inherited `FM_ROOT_OVERRIDE`/`FM_HOME` that names a DIFFERENT checkout
// than the one this file was loaded from, which is exactly the worker-worktree
// copy the OpenCode log showed loading into the primary home's server. Both
// sides are resolved because git reports physical paths while a session may
// report a symlinked one (macOS /var versus /private/var).
function ownsLoadedRoot(paths) {
  if (!paths.own) return false;
  return resolvePath(paths.root) === resolvePath(paths.own);
}

// The state directory this copy may write a diagnostic into. A foreign copy
// never writes into the home it merely inherited from the environment; it only
// uses its own checkout's existing state directory, and otherwise falls back to
// the server log.
function diagnosticStateDir(paths) {
  if (!ownsLoadedRoot(paths)) {
    const ownState = `${resolvePath(paths.own || paths.root)}/state`;
    return existsSync(ownState) ? ownState : "";
  }
  return paths.state;
}

function noteDecision(paths, decision, reason, detail = "") {
  const key = `${decision}|${reason}|${detail}`;
  if (key === lastDecisionKey) return;
  lastDecisionKey = key;
  const line = `${new Date().toISOString()} decision=${decision} reason=${reason}${detail ? ` ${detail}` : ""} own=${paths.own || ""} root=${paths.root} home=${paths.home}`;
  const dir = diagnosticStateDir(paths);
  const file = dir ? `${dir}/${DIAGNOSTIC_LOG}` : "";
  if (!file || !existsSync(dir)) {
    console.warn(`firstmate watch-arm: ${line}`);
    return;
  }
  try {
    appendFileSync(file, `${line}\n`);
    if (statSync(file).size > DIAGNOSTIC_LOG_MAX_BYTES) {
      const lines = readFileSync(file, "utf8").split("\n").filter(Boolean);
      writeFileSync(file, `${lines.slice(-DIAGNOSTIC_LOG_KEEP_LINES).join("\n")}\n`);
    }
  } catch {
    console.warn(`firstmate watch-arm: ${line}`);
  }
}

// Every decision lands in the home's own bounded log. This is deliberately the
// only channel for routine skips and declines: the OpenCode plugin streams stay
// quiet, and a home that genuinely cannot write its log falls back to the
// server's console so the trace is never lost entirely.
function declineArm(paths, status, reason, detail = "") {
  noteDecision(paths, "skip", reason, `status=${status}${detail ? ` ${detail}` : ""}`);
  return { status, armChild: null };
}

async function isPrimaryRoot(root, home) {
  if (!root) return false;
  if (!existsSync(`${root}/AGENTS.md`) || !existsSync(`${root}/bin`)) return false;
  if (existsSync(`${root}/.fm-secondmate-home`)) return false;
  if (home && home !== root && existsSync(`${home}/.fm-secondmate-home`)) return false;
  const gitDir = await runProcess("git", ["-C", root, "rev-parse", "--git-dir"]);
  const commonDir = await runProcess("git", ["-C", root, "rev-parse", "--git-common-dir"]);
  if (gitDir.code !== 0 || commonDir.code !== 0) return false;
  return gitDir.stdout.trim() === commonDir.stdout.trim();
}

// bin/fm-supervision-lib.sh's fm_supervision_needed is the single owner of the
// arm condition set (the turn-end guard decides with the same shared
// predicate), so this plugin can never disagree with the guard again. Away
// mode stays a local decline: its daemon owns supervision. X-mode homes arm
// before their relay poll is registered in the state directory.
function shouldArm(paths) {
  if (existsSync(`${paths.state}/.afk`)) return false;
  if (existsSync(`${paths.config}/x-mode.env`)) return true;
  return supervisionNeeded(paths);
}

// fm_supervision_needed <state-dir> exits 0 exactly when the shared predicate
// says the home needs supervision; exit 0 means arm here.
function supervisionNeeded(paths) {
  const result = spawnSync(
    "bash",
    [
      "-c",
      '. "$1/bin/fm-supervision-lib.sh" && fm_supervision_needed "$2"',
      "fm-primary-watch-arm",
      paths.root,
      paths.state,
    ],
    { stdio: "ignore" },
  );
  return result.status === 0;
}

// What this home looks like right before an arm is allowed:
//   watcher  live|none|unknown  a live, identity-matched watcher process holds
//                               this home's singleton with a fresh beacon
//   lock     free|stale|held|unreadable|unknown|absent  the session-lock state
//   foreign  true when a LIVE verified harness session outside this server's
//            ancestry owns the lock
//
// Both answers come from the shared libraries that own them
// (fm_watcher_healthy and fm_session_lock_foreign_owner_live), never from a
// local reimplementation. The previous version answered the ownership question
// with a bare pid-ancestry walk and treated "I cannot find the recorded pid in
// my ancestry" as "another session owns this home". After a restart the old
// session's pid is simply DEAD, so that answer was permanently false and the
// plugin declined every arm as read-only with nothing written anywhere - the
// nine-hour blind window. Only a positively proven live foreign owner may
// refuse now; a stale, missing, or unreadable lock does not. A checkout without
// the shared libraries reads both answers as unknown and still arms, because a
// degraded query must not be the reason supervision stays dark.
function supervisionFacts(paths) {
  const script = [
    'wake=0; lock=0',
    'if [ -f "$1/bin/fm-wake-lib.sh" ]; then . "$1/bin/fm-wake-lib.sh" && wake=1; fi',
    'if [ -f "$1/bin/fm-session-lock-lib.sh" ]; then . "$1/bin/fm-session-lock-lib.sh" && lock=1; fi',
    'grace=${FM_GUARD_GRACE:-300}',
    'if [ "$wake" = 1 ]; then',
    '  if fm_watcher_healthy "$2" "$1/bin/fm-watch.sh" "$grace" "$3" >/dev/null 2>&1; then',
    '    printf "watcher=live:%s\\n" "$FM_WATCHER_HEALTHY_PID"',
    '  else',
    '    echo "watcher=none"',
    '  fi',
    'else',
    '  echo "watcher=unknown"',
    'fi',
    'if [ "$lock" = 1 ]; then',
    '  fm_session_lock_inspect "$2"',
    '  printf "lock=%s:%s\\n" "$FM_LOCK_INSPECT_STATE" "$FM_LOCK_INSPECT_PID"',
    // Two signals, either one sufficient. foreign_owner_live is the shared
    // owner of the ancestry-aware verdict. A live verified harness holding the
    // lock that this session does not own is the same refusal even when the
    // ancestry cannot be resolved at all, which is the one case that library
    // returns "not foreign" for; a shared OpenCode server whose spawner is not
    // the harness process is exactly such a server.
    '  if fm_session_lock_owned_by_self "$2"; then',
    '    echo "foreign=no"',
    '  elif fm_session_lock_foreign_owner_live "$2"; then',
    '    printf "foreign=yes:%s\\n" "$FM_SESSION_LOCK_FOREIGN_OWNER_PID"',
    '  elif fm_harness_pid_alive "$FM_LOCK_INSPECT_PID"; then',
    '    printf "foreign=yes:%s\\n" "$FM_LOCK_INSPECT_PID"',
    '  else',
    '    echo "foreign=no"',
    '  fi',
    'else',
    '  echo "lock=unknown:"',
    '  echo "foreign=no"',
    'fi',
  ].join("\n");
  const result = spawnSync("bash", ["-c", script, "fm-primary-watch-arm", paths.root, paths.state, paths.home], {
    encoding: "utf8",
    env: {
      ...process.env,
      FM_ROOT_OVERRIDE: paths.root,
      FM_HOME: paths.home,
      FM_STATE_OVERRIDE: paths.state,
    },
  });
  if (result.status !== 0) {
    return { ok: false, watcher: "unknown", watcherPid: "", lock: "unknown", lockPid: "", foreign: false, foreignPid: "" };
  }
  const fields = new Map();
  for (const line of String(result.stdout || "").split(/\r?\n/)) {
    const index = line.indexOf("=");
    if (index > 0) fields.set(line.slice(0, index), line.slice(index + 1));
  }
  const [watcher = "unknown", watcherPid = ""] = String(fields.get("watcher") ?? "unknown").split(":");
  const [lock = "unknown", lockPid = ""] = String(fields.get("lock") ?? "unknown").split(":");
  const [foreign = "no", foreignPid = ""] = String(fields.get("foreign") ?? "no").split(":");
  return { ok: true, watcher, watcherPid, lock, lockPid, foreign: foreign === "yes", foreignPid };
}

// An away record, never quiet mode's (bin/fm-afk-contract.sh mode owns that
// reading): a record whose mode cannot be read as quiet reads as away.
function awayRecordPresent(paths) {
  if (!existsSync(`${paths.state}/.afk-contract`)) return false;
  const result = spawnSync("bash", [`${paths.root}/bin/fm-afk-contract.sh`, "mode"], {
    encoding: "utf8",
    env: { ...process.env, FM_STATE_OVERRIDE: paths.state },
  });
  return String(result.stdout || "").trim() !== "quiet";
}

// Whether this home runs the supervision host for an OpenCode primary; the
// gate's owner answers, and a query that cannot run reads as no host.
function hostModeEnabled(paths) {
  const result = spawnSync("bash", [`${paths.root}/bin/fm-supervision-engine-lib.sh`, "enabled", paths.config, "opencode"], {
    stdio: "ignore",
  });
  return result.status === 0;
}

// The host-mode wake message: every "supervision-host:" line in order, wake
// lines capped at eight, and the away note while an away record exists.
function hostWakeMessage(paths, combined) {
  let shown = 0;
  const lines = combined.split(/\r?\n/).filter((line) => {
    if (HOST_LINE.test(line)) return true;
    if (WAKE_LINE.test(line) && shown < 8) {
      shown += 1;
      return true;
    }
    return false;
  });
  if (lines.length === 0) return "";
  if (awayRecordPresent(paths)) {
    lines.push("This wake comes from automatic supervision under the away-posture record, not from the captain: it is not a return, so handle it under the away posture.");
  }
  return lines.join("\n");
}

function classifyArmClose(paths, hostMode, stdout, stderr, code, signal) {
  const combined = `${stdout}\n${stderr}`;
  if (hostMode) {
    const message = hostWakeMessage(paths, combined);
    if (message) return { kind: "actionable", message };
    const stoodDown = combined.split(/\r?\n/).find((line) => /^supervision-host stood down:/.test(line));
    if (stoodDown) return { kind: "failure", message: `watcher: FAILED - ${stoodDown}` };
  }
  const reason = combined.split(/\r?\n/).find((line) => WAKE_LINE.test(line));
  if (reason) return { kind: "actionable", message: reason };
  const healthy = combined.split(/\r?\n/).find((line) => /^watcher: healthy\b/.test(line));
  if (healthy) {
    return {
      kind: "failure",
      message: `watcher: FAILED - OpenCode arm child found an external healthy watcher instead of owning wake delivery\n${healthy}`,
    };
  }
  // The arm's typed stalled-holder line is the one close the plugin must
  // answer with a force-restart: the holder is alive but its beacon passed the
  // watcher's own eviction bound, so a plain attach-or-start successor would
  // re-attach to the same wedged cycle forever. `--restart` is home-scoped
  // (bin/fm-watch-arm.sh stops only this home's locked watcher), and this is
  // the only path allowed to use it.
  const stalled = combined
    .split(/\r?\n/)
    .find((line) => /^watcher: FAILED - attached watcher pid=[0-9]+ stalled\b/.test(line));
  if (stalled) return { kind: "stalled", message: stalled };
  const failed = combined.split(/\r?\n/).find((line) => /^watcher: FAILED/.test(line));
  if (failed) return { kind: "failure", message: failed };
  if (signal) {
    return {
      kind: "failure",
      message: `watcher: FAILED - OpenCode arm child ended from ${signal}${combined.trim() ? `\n${combined.trim()}` : ""}`,
    };
  }
  if (code && code !== 0) {
    const script = hostMode ? "fm-supervision-host.sh" : "fm-watch-arm.sh";
    return {
      kind: "failure",
      message: `watcher: FAILED - ${script} exited ${code}${combined.trim() ? `\n${combined.trim()}` : ""}`,
    };
  }
  return {
    kind: "failure",
    message: "watcher: FAILED - OpenCode arm cycle ended without an actionable reason",
  };
}

function observeArmOutput(hostMode, stdout, stderr, settleReadiness) {
  const combined = `${stdout}\n${stderr}`;
  if (combined.split(/\r?\n/).some((line) => WAKE_LINE.test(line) || (hostMode && HOST_LINE.test(line)))) {
    setArmStatus("wake");
    settleReadiness("wake");
    return;
  }
  if (combined.split(/\r?\n/).some((line) => /^watcher: (?:started|attached)\b/.test(line))) {
    setArmStatus("armed");
    settleReadiness("armed");
    return;
  }
  if (combined.split(/\r?\n/).some((line) => /^watcher: healthy\b/.test(line))) {
    setArmStatus("external");
    settleReadiness("external");
    return;
  }
  if (combined.split(/\r?\n/).some((line) => /^watcher: FAILED/.test(line))) {
    setArmStatus("failed");
    settleReadiness("failed");
  }
}

async function sendPrompt(paths, client, sessionID, text) {
  const encoded = await encodeFirstmateOperationalInput(paths.root, "watcher", text);
  await client.session.prompt({ sessionID, text: encoded });
}

function confirmHandlingDelivery(paths, recovery) {
  try {
    const result = spawnSync(
      "bash",
      [`${paths.root}/bin/fm-watch-arm.sh`, "--handling-delivered", recovery.generation, "--watcher-pid", recovery.watcherPid],
      {
        cwd: paths.root,
        encoding: "utf8",
        env: { ...process.env, FM_HOME: paths.home, FM_STATE_OVERRIDE: paths.state, FM_ROOT_OVERRIDE: paths.root },
      },
    );
    if (result.status === 0) return { ok: true, detail: "" };
    const stderr = String(result.stderr || "").trim();
    return {
      ok: false,
      detail: `watcher: FAILED - handling delivery confirmation was rejected (status=${result.status ?? "none"} generation=${recovery.generation} watcherPid=${recovery.watcherPid})${stderr ? `\n${stderr}` : ""}`,
    };
  } catch (error) {
    return {
      ok: false,
      detail: `watcher: FAILED - handling delivery confirmation could not be executed (generation=${recovery.generation} watcherPid=${recovery.watcherPid})\n${String(error?.message ?? error)}`,
    };
  }
}

function confirmHandlingDeliveryWithRetry(paths, recovery) {
  const snapshot = () => armRecovery.get(child) ?? recovery;
  const first = confirmHandlingDelivery(paths, snapshot());
  if (first.ok) return first;
  return confirmHandlingDelivery(paths, snapshot());
}

async function deliverActionableWake(paths, client, sessionID, message, recovery) {
  if (recovery) {
    const confirmed = confirmHandlingDeliveryWithRetry(paths, recovery);
    if (!confirmed.ok) {
      if (recovery.watcherPid) {
        try {
          process.kill(Number(recovery.watcherPid), 0);
        } catch {
          await retireArm(child);
        }
      }
      await sendPrompt(paths, client, sessionID, wakePrompt(`${message}\n\n${confirmed.detail}`));
      return;
    }
  }
  await sendPrompt(paths, client, sessionID, wakePrompt(message));
}

function wakePrompt(reason) {
  return `WATCHER FIRED - drain queued wakes with bin/fm-wake-drain.sh and handle the reported wake. Watcher continuity is plugin-owned.\n\n${reason}`;
}

function surfaceFailure(paths, client, sessionID, reason) {
  void sendPrompt(paths, client, sessionID, wakePrompt(reason)).catch(() => {
    // OpenCode owns delivery errors; continuity restoration never waits on prompting.
  });
}

// Statuses that mean "a watcher is verified, or a succession is already under
// way". A retry or a readiness poll that lands on one of these must stay silent
// instead of announcing a continuity failure or starting a duplicate arm.
const SETTLED_OR_IN_FLIGHT_STATUSES = new Set([
  "armed",
  "wake",
  "existing",
  "retrying",
  "starting",
]);

function retryDelay(attempt) {
  return Math.min(REARM_RETRY_MAX_MS, REARM_RETRY_BASE_MS * 2 ** Math.max(0, attempt - 1));
}

// One succession at a time, home-scoped and durable.
//
// After an actionable close the plugin's `child` handle is already clear, so a
// second coordinator caller (the turn-end guard's ensureArmed, a second plugin
// instance, or a retry) sees an empty slot and starts its own successor. Those
// duplicates used to pile up as extra arms that each attached to, or restarted,
// this home's one watcher. The claim file makes the slot visible to every
// caller: a live, unexpired claim means a succession is already under way.
const claimPathOf = (paths) => `${paths.state}/${SUCCESSION_CLAIM}`;

function claimIsLive(paths) {
  const path = claimPathOf(paths);
  let raw;
  try {
    raw = readFileSync(path, "utf8");
  } catch {
    return false;
  }
  const fields = new Map();
  for (const line of raw.split(/\r?\n/)) {
    const index = line.indexOf("=");
    if (index > 0) fields.set(line.slice(0, index), line.slice(index + 1));
  }
  const pid = Number(fields.get("pid"));
  if (!Number.isInteger(pid) || pid <= 0) return false;
  let ageMs = Number.POSITIVE_INFINITY;
  try {
    ageMs = Date.now() - statSync(path).mtimeMs;
  } catch {
    return false;
  }
  // The TTL bounds every claim, including our own: a claim left behind by a
  // crashed succession must expire rather than suppress supervision forever.
  if (!(ageMs < SUCCESSION_CLAIM_TTL_MS)) return false;
  if (fields.get("owner") === SUCCESSION_OWNER) {
    // Our own claim, still inside its TTL: a concurrent caller joins it
    // instead of starting a duplicate successor.
    return true;
  }
  try {
    process.kill(pid, 0);
  } catch {
    return false;
  }
  return true;
}

function claimSuccession(paths, predecessorArmPid) {
  const path = claimPathOf(paths);
  const temp = `${path}.${process.pid}`;
  try {
    mkdirSync(paths.state, { recursive: true });
    writeFileSync(
      temp,
      `owner=${SUCCESSION_OWNER}\npid=${process.pid}\nat=${Date.now()}\npredecessor=${predecessorArmPid || ""}\n`,
    );
    renameSync(temp, path);
    return true;
  } catch {
    try {
      unlinkSync(temp);
    } catch {}
    return false;
  }
}

export function releaseSuccession(paths) {
  try {
    const raw = readFileSync(claimPathOf(paths), "utf8");
    // Only this instance may release its own claim: another instance in the
    // same process shares our pid but not our owner token.
    if (!raw.split(/\r?\n/).includes(`owner=${SUCCESSION_OWNER}`)) return;
  } catch {
    return;
  }
  try {
    unlinkSync(claimPathOf(paths));
  } catch {}
}

// The arm-slot record, read defensively: a missing, malformed, or foreign file
// must never be evidence of a live channel.
function armSlotFields(paths) {
  try {
    const raw = readFileSync(`${paths.state}/${ARM_SLOT}`, "utf8");
    const fields = new Map();
    for (const line of raw.split(/\r?\n/)) {
      const index = line.indexOf("=");
      if (index > 0) fields.set(line.slice(0, index), line.slice(index + 1));
    }
    return fields;
  } catch {
    return null;
  }
}

// A live arm channel: an armed child whose own process is still alive AND whose
// owner is still there to read its wake pipe. A slot left by a server that has
// exited is deliberately not live - that arm's stdout pipe died with its parent,
// so no wake it prints can reach a session, and continuity must take over
// instead of trusting a channel nobody reads. A slot owned by a DIFFERENT live
// server is live: two servers for one home must not both open a wake channel to
// the same watcher, because that delivers each wake twice.
function liveArmSlot(paths) {
  const fields = armSlotFields(paths);
  if (!fields) return null;
  const pid = Number(fields.get("pid"));
  if (!Number.isInteger(pid) || pid <= 0) return null;
  const server = Number(fields.get("server"));
  if (!Number.isInteger(server) || server <= 0) return null;
  try {
    process.kill(pid, 0);
    process.kill(server, 0);
  } catch {
    return null;
  }
  return { pid, server, watcher: fields.get("watcher") || "" };
}

function claimArmSlot(paths, pid) {
  if (!pid) return;
  const path = `${paths.state}/${ARM_SLOT}`;
  const temp = `${path}.${process.pid}`;
  try {
    mkdirSync(paths.state, { recursive: true });
    writeFileSync(temp, `owner=${SUCCESSION_OWNER}\nserver=${process.pid}\npid=${pid}\nat=${Date.now()}\n`);
    renameSync(temp, path);
  } catch {
    try {
      unlinkSync(temp);
    } catch {}
  }
}

// Release only the slot THIS arm child owns: a successor spawned by the same
// instance claims the slot before its predecessor's close event lands, and that
// close must not delete the live successor's channel.
function releaseArmSlot(paths, pid) {
  if (!pid) return;
  const fields = armSlotFields(paths);
  if (!fields) return;
  if (fields.get("owner") !== SUCCESSION_OWNER) return;
  if (fields.get("pid") !== String(pid)) return;
  try {
    unlinkSync(`${paths.state}/${ARM_SLOT}`);
  } catch {}
}

function waitForRetry(attempt) {
  return new Promise((resolve) => {
    const timer = setTimeout(resolve, retryDelay(attempt));
    timer.unref();
  });
}

async function retireArm(armChild) {
  if (!armChild) return true;
  armChild.kill("SIGTERM");
  const closed = armClose.get(armChild);
  if (!closed) return false;
  return new Promise((resolve) => {
    const timer = setTimeout(() => resolve(false), ARM_RETIRE_TIMEOUT_MS);
    timer.unref();
    void closed.then(() => {
      clearTimeout(timer);
      resolve(true);
    });
  });
}

function restorationFailure(status) {
  if (status === "read-only") {
    return "watcher: FAILED - OpenCode cannot restore continuity because this session no longer owns the lock";
  }
  return `watcher: FAILED - OpenCode could not verify a ready successor watcher (${status || "idle"})`;
}

// Statuses that mean "someone else already owns, or there is nothing to own".
// None of them is a continuity failure: `foreign-session` is another session's
// idle event on this server, `not-needed` is a home that no longer needs
// supervision, `read-only`/`not-primary`/`skipped` are ownership boundaries, and
// `existing`/`retrying` mean a succession this caller did not start is already
// running. Treating any of them as a failure is what produced the repeated
// `could not restore watcher continuity after 5 retries` line.
const NON_FAILURE_STATUSES = new Set([
  "existing",
  "retrying",
  "not-needed",
  "foreign-session",
  "read-only",
  "not-primary",
  "skipped",
]);

// Succession is idempotent. A successor started here runs in attach-or-start
// mode by default: a duplicate that lands while a healthy watcher still holds
// this home's lock must follow that cycle instead of force-stopping it. The one
// exception is the arm's own typed stalled-holder close, where the live holder
// is provably wedged past the watcher's eviction bound; that attempt escalates
// to the home-scoped `--restart`, which stops only this home's locked watcher
// and never a sibling home's. `--restart` remains owner-only everywhere else.
async function restoreAfterActionableClose(paths, sessionID, client, predecessorArmPid) {
  let failure = "";
  for (let attempt = 0; attempt <= REARM_RETRY_LIMIT; attempt += 1) {
    // An attempt that follows a stalled-holder close asks for the one
    // force-restart the plugin is allowed: attach-or-start would follow the
    // same wedged cycle for its whole TTL.
    const force = stalledEscalationPending;
    stalledEscalationPending = false;
    const { status, armChild } = await ensureArm(paths, sessionID, client, predecessorArmPid, true, force);
    if (status === "armed" || status === "wake") {
      // A stall reported while this attempt was in flight was already answered
      // by its readiness outcome, so it must not escalate a later, unrelated
      // cycle into a force-restart.
      stalledEscalationPending = false;
      releaseSuccession(paths);
      return { failure: "", recovery: armRecovery.get(armChild) };
    }
    if (NON_FAILURE_STATUSES.has(status)) {
      // Ownership decided elsewhere: report nothing and stay silent about
      // continuity. A `read-only` lock really cannot be repaired from here, so
      // that one keeps its typed line.
      stalledEscalationPending = false;
      releaseSuccession(paths);
      return {
        failure: status === "read-only" ? restorationFailure(status) : "",
        recovery: null,
      };
    }
    failure = restorationFailure(status);
    // Retire every unready attempt, including the last one: an arm that never
    // confirmed must not be left running past the restoration that gave up on
    // it, or it would keep a wedged child alive and could later close into a
    // second succession.
    if (!(await retireArm(armChild))) {
      setArmStatus("failed");
      releaseSuccession(paths);
      return {
        failure: `${failure}\nwatcher: FAILED - OpenCode could not restore watcher continuity because the unready successor arm did not exit within ${ARM_RETIRE_TIMEOUT_MS}ms`,
        recovery: null,
      };
    }
    if (attempt === REARM_RETRY_LIMIT) break;
    await waitForRetry(attempt + 1);
  }
  setArmStatus("failed");
  releaseSuccession(paths);
  return {
    failure: `${failure}\nwatcher: FAILED - OpenCode could not restore watcher continuity after ${REARM_RETRY_LIMIT} retries`,
    recovery: null,
  };
}

async function scheduleRetry(paths, sessionID, client, reason, predecessorArmPid, force = false) {
  if (child || retryTimer) return;
  // Same ownership question the arm gate asks, and the same fix: only a
  // positively proven live foreign session may suppress this home's continuity
  // retry. A stale lock after a restart must not end restoration as read-only.
  const facts = supervisionFacts(paths);
  if (facts.foreign) {
    setArmStatus("failed");
    noteDecision(paths, "skip", "lock-owned", `status=read-only lockPid=${facts.foreignPid}`);
    surfaceFailure(paths, client, sessionID, `watcher: FAILED - OpenCode cannot restore continuity because this session no longer owns the lock\n${reason}`);
    return;
  }
  retryFailures += 1;
  if (retryFailures > REARM_RETRY_LIMIT) {
    setArmStatus("failed");
    surfaceFailure(paths, client, sessionID, `watcher: FAILED - OpenCode could not restore watcher continuity after ${REARM_RETRY_LIMIT} retries\n${reason}`);
    return;
  }
  setArmStatus("retrying");
  const timer = setTimeout(() => {
    if (retryTimer === timer) retryTimer = null;
    void ensureArm(paths, sessionID, client, predecessorArmPid, false, force).then((status) => {
      // A status this set owns is a healthy club: armed/wake means a verified
      // successor, and existing/retrying means another caller is already
      // starting one, so this retry must neither announce a failure nor start
      // a duplicate.
      if (SETTLED_OR_IN_FLIGHT_STATUSES.has(status)) return;
      surfaceFailure(paths, client, sessionID, `watcher: FAILED - OpenCode could not launch a continuity retry (${status})`);
    });
  }, retryDelay(retryFailures));
  timer.unref();
  retryTimer = timer;
}

function spawnArm(paths, sessionID, client, predecessorArmPid = "", force = false) {
  setArmStatus("starting");
  const hostMode = hostModeEnabled(paths);
  const env = {
    ...process.env,
    FM_HOME: paths.home,
    FM_ROOT_OVERRIDE: paths.root,
    FM_CONFIG_OVERRIDE: paths.config,
    FM_ARM_CONFIRM_TIMEOUT: String(ARM_CONFIRM_SECONDS),
    FM_WATCH_PREDECESSOR_ARM_PID: predecessorArmPid,
  };
  if (hostMode) env.FM_SUPERVISION_HOST_PRIMARY = "opencode";
  // Attach-or-start by default (see restoreAfterActionableClose): the plugin
  // owns succession by starting a successor that joins a healthy cycle rather
  // than replacing it. `force` is set only for the arm's own typed
  // stalled-holder close, where the live holder is provably wedged past the
  // watcher's eviction bound and a plain attach would re-follow it forever.
  const armMode = force && !hostMode ? "--restart" : "--arm";
  const command = hostMode
    ? '"$FM_ROOT_OVERRIDE/bin/fm-supervision-host.sh" park --restart'
    : `"$FM_ROOT_OVERRIDE/bin/fm-watch-arm.sh" ${armMode}`;
  const armChild = spawn("bash", ["-lc", `config_dir="\${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"; [ -f "$config_dir/x-mode.env" ] && . "$config_dir/x-mode.env"; exec ${command}`], {
    cwd: paths.root,
    env,
    stdio: ["ignore", "pipe", "pipe"],
  });
  armHostMode.set(armChild, hostMode);
  child = armChild;
  claimArmSlot(paths, armChild.pid);
  let stdout = "";
  let stderr = "";
  let settled = false;
  let resolveClosed = null;
  let readinessSettled = false;
  let resolveReadiness = null;
  const readiness = new Promise((resolve) => {
    resolveReadiness = resolve;
  });
  armReadiness.set(armChild, readiness);
  const settleReadiness = (status) => {
    if (readinessSettled) return;
    readinessSettled = true;
    resolveReadiness(status);
  };
  const closed = new Promise((resolveClosedChild) => {
    resolveClosed = resolveClosedChild;
  });
  armClose.set(armChild, closed);
  const releaseChild = () => {
    if (child === armChild) child = null;
  };
  const observeRecovery = () => {
    const recovery = `${stdout}\n${stderr}`.match(/^watcher: started pid=([0-9]+).* recovery-generation=([A-Za-z0-9._-]+)$/m);
    if (recovery) armRecovery.set(armChild, { watcherPid: recovery[1], generation: recovery[2] });
  };
  armChild.stdout.on("data", (chunk) => {
    stdout += chunk.toString();
    observeRecovery();
    observeArmOutput(hostMode, stdout, stderr, settleReadiness);
  });
  armChild.stderr.on("data", (chunk) => {
    stderr += chunk.toString();
    observeRecovery();
    observeArmOutput(hostMode, stdout, stderr, settleReadiness);
  });
  armChild.on("close", (code, signal) => {
    if (settled) return;
    settled = true;
    resolveClosed();
    releaseChild();
    releaseArmSlot(paths, armChild.pid);
    const classification = classifyArmClose(paths, hostMode, stdout, stderr, code, signal);
    settleReadiness(classification.kind === "actionable" ? "wake" : "failed");
    const predecessor = String(armChild.pid ?? "");
    if (classification.kind === "actionable") {
      if (restorationInFlight) {
        // A later cycle closed for its own actionable reason while the earlier
        // one was still restoring. Dropping it swallowed that wake outright;
        // keep it and let the in-flight delivery carry both.
        pendingWakeMessages.push(classification.message);
        setArmStatus("wake");
        return;
      }
      retryFailures = 0;
      setArmStatus("wake");
      const restoration = restoreAfterActionableClose(paths, sessionID, client, predecessor);
      restorationInFlight = restoration;
      void restoration.then(async (result) => {
        try {
          // Drain the pending queue only AFTER each delivery. Splicing before
          // the await silently dropped a wake that arrived while the prompt
          // was being sent, because the close handler appends to this array.
          let leader = classification.message;
          let failure = result.failure;
          let recovery = result.recovery;
          do {
            const message = [leader, ...pendingWakeMessages.splice(0), failure].filter(Boolean).join("\n\n");
            leader = "";
            failure = "";
            await deliverActionableWake(paths, client, sessionID, message, recovery);
            recovery = null;
          } while (pendingWakeMessages.length > 0);
        } finally {
          if (restorationInFlight === restoration) restorationInFlight = null;
        }
      }).catch((error) => {
        if (restorationInFlight === restoration) restorationInFlight = null;
        surfaceFailure(
          paths,
          client,
          sessionID,
          `watcher: FAILED - OpenCode could not deliver an actionable wake\n${String(error?.message ?? error)}`,
        );
      });
      return;
    }
    if (restorationInFlight) {
      // A non-actionable close during restoration is that restoration's own
      // retry material, not a second failure to surface. A stalled-holder
      // close is the exception that must survive: the in-flight restoration
      // would otherwise retry in attach mode and re-follow the wedged holder.
      if (classification.kind === "stalled") stalledEscalationPending = true;
      setArmStatus("failed");
      return;
    }
    void scheduleRetry(
      paths,
      sessionID,
      client,
      classification.message,
      predecessor,
      classification.kind === "stalled",
    );
  });
  armChild.on("error", (error) => {
    if (settled) return;
    settled = true;
    resolveClosed();
    releaseChild();
    releaseArmSlot(paths, armChild.pid);
    settleReadiness("failed");
    if (restorationInFlight) {
      setArmStatus("failed");
      return;
    }
    void scheduleRetry(
      paths,
      sessionID,
      client,
      `watcher: FAILED - OpenCode arm child failed: ${error.message}`,
      String(armChild.pid ?? ""),
    );
  });
  return armChild;
}

// Containment by path semantics rather than string prefixes: a prefix test is
// both separator-specific (inert on win32, whose separator is a backslash) and
// wrong for a sibling that merely shares a prefix (`/lab` and `/lab2`).
// `relativeImpl`/`isAbsoluteImpl` exist so the win32 form can be exercised on
// any host with path.win32's own implementations.
export function directoryWithin(directory, base, relativeImpl = relative, isAbsoluteImpl = isAbsolute) {
  if (!directory || !base) return false;
  const dir = resolvePath(directory);
  const root = resolvePath(base);
  const rel = relativeImpl(root, dir);
  if (rel === "") return true;
  if (isAbsoluteImpl(rel)) return false;
  return rel.split(/[\\/]/)[0] !== "..";
}

function sessionDirectoryOf(info) {
  return (
    info?.directory ??
    info?.location?.directory ??
    info?.project?.directory ??
    ""
  );
}

// OpenCode v2's event stream is server-wide, so an idle event can originate
// from any session this server serves (every crewmate shares the server). Arming
// against a foreign session binds the supervision wake channel to it and
// delivers firstmate's notifications into a crewmate's window. Only arm for a
// session at this home's location; an unreadable session keeps the previous
// behavior so supervision never goes dark on a failed lookup.
async function sessionBelongsToHome(paths, client, sessionID) {
  if (!client || typeof client.session?.get !== "function") return true;
  let result;
  try {
    result = await client.session.get({ sessionID });
  } catch {
    return true;
  }
  const directory = sessionDirectoryOf(result?.data ?? result);
  if (!directory) return true;
  try {
    // A TUI opened in a subdirectory of the home is still this home's session;
    // exact equality alone left such a session never arming supervision. A
    // project clone below the home is NOT: it is another repository served by
    // the same OpenCode server, and arming against it delivers firstmate's
    // notifications into that project's window.
    const projects = resolvePath(`${paths.home}/projects`);
    const inHome =
      directoryWithin(directory, paths.root) || directoryWithin(directory, paths.home);
    if (!inHome || directoryWithin(directory, projects)) return false;
    // Any nested repository is foreign too, which catches clones outside the
    // conventional projects directory. A subdirectory of this repository
    // resolves to the same top level and stays ours.
    // Compare resolved paths: git may report the physical path while the
    // session reports a symlinked one (macOS /var versus /private/var).
    const top = resolvePath(await resolveRoot(directory));
    return top === resolvePath(paths.root) || top === resolvePath(paths.home);
  } catch {
    return true;
  }
}


async function beginArm(paths, sessionID, client, predecessorArmPid, force = false) {
  if (!sessionID) return declineArm(paths, "skipped", "no-session");
  // A copy loaded from another root is inert before it reads anything of the
  // home it inherited: no lock check, no watcher check, no arm, no claim.
  if (!ownsLoadedRoot(paths)) {
    return declineArm(paths, "not-primary", "foreign-root", `loadedRoot=${paths.own}`);
  }
  if (!(await sessionBelongsToHome(paths, client, sessionID))) {
    return declineArm(paths, "foreign-session", "foreign-session", `session=${sessionID}`);
  }
  if (!(await isPrimaryRoot(paths.root, paths.home))) return declineArm(paths, "not-primary", "not-primary-root");
  const facts = supervisionFacts(paths);
  if (facts.foreign) {
    // The one refusal that still means "another live session owns this home".
    // It is a positive proof (a live verified harness outside this server's
    // ancestry), never the absence of a match against a dead pid.
    return declineArm(paths, "read-only", "lock-owned", `lockPid=${facts.foreignPid} watcher=${facts.watcher}`);
  }
  if (!facts.ok) {
    // A home whose shared predicate cannot run cannot be reasoned about. This
    // is diagnosable instead of silent, and it still fails closed.
    return declineArm(paths, "read-only", "lock-unknown", `lock=${facts.lock}`);
  }
  if (child) {
    noteDecision(paths, "skip", "arm-running", `status=existing watcher=${facts.watcher}`);
    return { status: "existing", armChild: child };
  }
  if (retryTimer) {
    noteDecision(paths, "skip", "retry-scheduled", `status=retrying watcher=${facts.watcher}`);
    return { status: "retrying", armChild: null };
  }
  // Another module instance in this same server already holds the wake channel
  // for this home (a reloaded plugin, a second loader pass, the guard's copy).
  // Attach to it by leaving it alone: spawning a second `--arm` would not start
  // a second watcher, but it would deliver every wake twice.
  const slot = liveArmSlot(paths);
  if (slot) {
    noteDecision(paths, "skip", "arm-slot-live", `status=existing armPid=${slot.pid} watcher=${facts.watcher}`);
    return { status: "existing", armChild: null };
  }
  if (!shouldArm(paths)) {
    return declineArm(paths, "not-needed", "supervision-not-needed", `watcher=${facts.watcher} lock=${facts.lock}`);
  }
  // One succession at a time, whoever asks (see claimSuccession). A live claim
  // means another caller is already starting the successor for this close, so
  // this caller joins rather than starting a duplicate arm.
  if (claimIsLive(paths)) {
    noteDecision(paths, "skip", "succession-claimed", `status=retrying watcher=${facts.watcher}`);
    return { status: "retrying", armChild: null };
  }
  if (!claimSuccession(paths, predecessorArmPid)) {
    // An unwritable claim must not take supervision dark: continuity outranks
    // duplicate suppression, and a duplicate arm only attaches to the cycle.
  }
  noteDecision(
    paths,
    "arm",
    facts.watcher === "live" ? "watcher-live" : "no-watcher",
    `watcher=${facts.watcher}${facts.watcherPid ? `:${facts.watcherPid}` : ""} lock=${facts.lock}`,
  );
  return { status: "spawned", armChild: spawnArm(paths, sessionID, client, predecessorArmPid, force) };
}

function armAttempt(status, armChild, includeArmChild) {
  return includeArmChild ? { status, armChild } : status;
}

async function ensureArm(paths, sessionID, client, predecessorArmPid = "", includeArmChild = false, force = false) {
  let launchResult = null;
  if (!launchInFlight) {
    const launch = beginArm(paths, sessionID, client, predecessorArmPid, force);
    launchInFlight = launch;
    try {
      launchResult = await launch;
    } finally {
      if (launchInFlight === launch) launchInFlight = null;
    }
  } else {
    launchResult = await launchInFlight;
  }
  const armChild = launchResult.armChild;
  if (!armChild) {
    return armAttempt(launchResult.status, null, includeArmChild);
  }
  const readiness = await waitForArmReady(armChild);
  // The spawned arm now owns the slot (it is `child`), so the durable claim
  // exists only to cover the window between an empty slot and this point. A
  // claim left behind would suppress the next succession for its whole TTL.
  releaseSuccession(paths);
  // A spawn that never confirms is the other silent failure this file had: the
  // caller saw a bare status and nothing recorded that a successor was
  // attempted. `external` is a failure here for the same reason the guard
  // refuses it - the arm found a healthy watcher it could not bind wake
  // delivery to.
  if (readiness !== "armed" && readiness !== "wake") {
    noteDecision(paths, "arm-failed", readiness || "idle", `armPid=${armChild.pid ?? ""}`);
  }
  return armAttempt(readiness, armChild, includeArmChild);
}

// One coordinator per location on a shared Map: OpenCode 2 runs every
// location's plugin instances in one process with one globalThis (verified
// live on 2.0.26), so a single global slot would let one location's guard
// reach another location's arm. The turnend-guard looks its location up
// here.
function coordinatorRegistry() {
  const registry = globalThis[COORDINATOR_KEY];
  if (registry instanceof Map) return registry;
  const created = new Map();
  globalThis[COORDINATOR_KEY] = created;
  return created;
}

// The plugin's turn-end handling as a v1-shaped hook object. The tracked V2
// entry point below feeds it the server event stream; exporting it lets the
// succession regression suite drive the real claim, location gate, readiness
// and delivery code with a fake client instead of a source-text copy.
export const FmPrimaryWatchArm = async ({ client, directory, worktree }) => {
  // The root this copy was LOADED for. `effectivePaths` records it as `own` so
  // the arm gate can prove the copy belongs to the home it would supervise.
  const loadedRoot = worktree ? resolvePath(worktree) : await resolveRoot(directory);
  const paths = effectivePaths(loadedRoot);
  return {
    // The turnend-guard looks this up by location in coordinatorRegistry().
    coordinator: {
      ensureArmed: (sessionID, activeClient) => ensureArm(paths, sessionID, activeClient ?? client),
    },
    // OpenCode 2 publishes the terminal execution events; a v1 session.idle (if
    // a host ever emits it) carries the same payload under `properties`.
    event: async ({ event }) => {
      const type = event?.type;
      if (!TURN_END_TYPES.has(type) && type !== "session.idle") return;
      const data = event?.data ?? event?.properties ?? {};
      if (type === "session.execution.interrupted" && data.reason === "shutdown") return;
      const sessionID = data.sessionID;
      if (!sessionID) return;
      // The location gate lives in beginArm (sessionBelongsToHome): it admits
      // this home and its subdirectories and refuses a project clone or any
      // other nested repository the shared OpenCode server serves.
      void ensureArm(paths, sessionID, client).catch((error) => {
        noteDecision(paths, "arm-failed", "unexpected-error", `detail=${String(error?.message ?? error)}`);
      });
    },
  };
};

export default {
  id: "fm-primary-watch-arm",
  async setup(ctx) {
    const hooks = await FmPrimaryWatchArm({
      client: ctx,
      directory: ctx.location.directory,
    });
    const registry = coordinatorRegistry();
    registry.set(ctx.location.directory, hooks.coordinator);

    const controller = new AbortController();
    void (async () => {
      for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
        try {
          await hooks.event({ event });
        } catch {
          // One event must never end the subscription: continuity depends on
          // this loop staying alive.
        }
      }
    })();

    return () => {
      controller.abort();
      if (registry.get(ctx.location.directory) === hooks.coordinator) {
        registry.delete(ctx.location.directory);
      }
    };
  },
};

#!/usr/bin/env bash
# Behavior tests for fm-wave-request.sh: the durable per-ISO-week request with
# its wake, and the fail-closed refusal that alerts instead of requesting when
# no live session holds the lock.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REQUEST="$ROOT/bin/fm-wave-request.sh"
TMP_ROOT=$(fm_test_tmproot fm-wave-request)

# Refusals escalate through fm-notify.sh; keep the suite quiet and deterministic
# on hosts that have a real notifier by resolving every tool except osascript.
SANS_OSASCRIPT=$(fm_test_base_path_sans "$PATH" osascript)

# A live harness for state/.lock: fm_agent_standin's long-running executable
# symlinked under a verified harness name, so the kernel records `pi` as the
# process identity (tests/lib.sh owns why it is never a copy).
STANDIN_DIR=$(fm_test_tmproot fm-wave-request-standin)
STANDIN_BIN=$(fm_agent_standin "$STANDIN_DIR") || {
  echo "skip: no long-running stand-in binary survives a foreign name (multicall coreutils, no C compiler)"
  exit 0
}
HARNESS_BIN="$TMP_ROOT/harness-bin"
mkdir -p "$HARNESS_BIN"
ln -s "$STANDIN_BIN" "$HARNESS_BIN/pi"

LOCK_PIDS=()
cleanup() {
  local status=$? pid
  trap - EXIT
  for pid in "${LOCK_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null || true
  done
  for pid in "${LOCK_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    wait "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
  exit "$status"
}
trap cleanup EXIT INT TERM

make_home() {  # <name>
  local home
  home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data"
  printf '%s\n' "$home"
}

start_lock_owner() {  # <home>
  local home=$1 pid
  "$HARNESS_BIN/pi" & pid=$!
  LOCK_PIDS+=("$pid")
  printf '%s\n' "$pid" > "$home/state/.lock"
}

dead_pid() {  # a pid that has been reaped, for the stale-lock case
  local pid
  true & pid=$!
  wait "$pid" 2>/dev/null || true
  printf '%s\n' "$pid"
}

test_request_written_woken_and_idempotent_per_period() {
  local home out status req count
  home=$(make_home written)
  start_lock_owner "$home"
  req="$home/data/research-wave/request-2026-10-05.md"

  out=$(FM_HOME="$home" PATH="$SANS_OSASCRIPT" "$REQUEST" --date 2026-10-05 2>&1)
  status=$?
  expect_code 0 "$status" "wave request with a live lock"
  assert_contains "$out" "requested " "the first run must report a new request"
  assert_contains "$out" "$req" "the status line must name the request path"
  assert_present "$req" "the request file was not written"
  assert_grep "period=2026-W41" "$req" "the request period is wrong"
  assert_grep "date=2026-10-05" "$req" "the request date is wrong"
  assert_grep "project=job-crawler" "$req" "the request project is wrong"
  assert_grep "loop=scripts/research-loop/dispatch.py" "$req" "the request loop path is wrong"
  assert_grep "at=" "$req" "the request timestamp is missing"

  count=$(wc -l < "$home/state/.wake-queue" | tr -d ' ')
  assert_equals 1 "$count" "the request must append exactly one wake"
  assert_grep "check: research wave request 2026-10-05" "$home/state/.wake-queue" \
    "the wake payload is missing"

  out=$(FM_HOME="$home" PATH="$SANS_OSASCRIPT" "$REQUEST" --date 2026-10-05 2>&1)
  expect_code 0 "$?" "same-date re-run"
  assert_contains "$out" "present $req" "a same-date re-run must report the existing request"

  out=$(FM_HOME="$home" PATH="$SANS_OSASCRIPT" "$REQUEST" --date 2026-10-07 2>&1)
  expect_code 0 "$?" "same-week re-run"
  assert_contains "$out" "present $req" "another date in the same ISO week is the same period"

  count=$(find "$home/data/research-wave" -name 'request-*.md' | wc -l | tr -d ' ')
  assert_equals 1 "$count" "one period must never own two request files"
  count=$(wc -l < "$home/state/.wake-queue" | tr -d ' ')
  assert_equals 1 "$count" "a re-run must never append a second wake"
  pass "the weekly request is durable, woken, and idempotent within its ISO week"
}

test_new_period_writes_its_own_request() {
  local home out req2
  home=$(make_home new-period)
  start_lock_owner "$home"
  FM_HOME="$home" PATH="$SANS_OSASCRIPT" "$REQUEST" --date 2026-10-05 >/dev/null
  out=$(FM_HOME="$home" PATH="$SANS_OSASCRIPT" "$REQUEST" --date 2026-10-12 2>&1)
  expect_code 0 "$?" "wave request for the next period"
  assert_contains "$out" "requested " "the next ISO week must write a new request"
  req2="$home/data/research-wave/request-2026-10-12.md"
  assert_present "$req2" "the next period's request is missing"
  assert_grep "period=2026-W42" "$req2" "the next period is wrong"
  pass "a new ISO week writes its own request"
}

test_refused_without_live_session() {
  local home out status
  home=$(make_home no-live-session)

  status=0
  out=$(FM_HOME="$home" PATH="$SANS_OSASCRIPT" "$REQUEST" --date 2026-10-05 2>&1) || status=$?
  expect_code 1 "$status" "refusal with no lock at all"
  assert_contains "$out" "refused no-live-session: lock free (alert logged)" \
    "the refusal must name the lock state and the alert"
  assert_absent "$home/data/research-wave/request-2026-10-05.md" \
    "a refusal must not write a request"
  assert_grep "Research wave request 2026-10-05 not queued" "$home/data/escalations.log" \
    "the refusal must leave a durable escalation"
  if [ -e "$home/state/.wake-queue" ] && [ -s "$home/state/.wake-queue" ]; then
    fail "a refusal must not append a wake"
  fi

  printf '%s\n' "$(dead_pid)" > "$home/state/.lock"
  status=0
  out=$(FM_HOME="$home" PATH="$SANS_OSASCRIPT" "$REQUEST" --date 2026-10-05 2>&1) || status=$?
  expect_code 1 "$status" "refusal with a stale lock"
  assert_contains "$out" "lock stale" "a stale lock must be named in the refusal"

  printf '%s\n' "$$" > "$home/state/.lock"
  status=0
  out=$(FM_HOME="$home" PATH="$SANS_OSASCRIPT" "$REQUEST" --date 2026-10-05 2>&1) || status=$?
  expect_code 1 "$status" "refusal with a live non-harness lock"
  assert_contains "$out" "lock unknown" "a live non-harness lock must be named in the refusal"

  assert_absent "$home/data/research-wave/request-2026-10-05.md" \
    "no refusal path may write a request"
  pass "the request fails closed and alerts when no live session holds the lock"
}

test_invalid_arguments_refused() {
  local home status
  home=$(make_home invalid-args)
  status=0
  FM_HOME="$home" PATH="$SANS_OSASCRIPT" "$REQUEST" --date 10-05-2026 >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "an invalid --date"
  status=0
  FM_HOME="$home" PATH="$SANS_OSASCRIPT" "$REQUEST" --nope >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "an unknown flag"
  assert_absent "$home/data/research-wave" "an invalid call must write nothing"
  pass "invalid arguments are refused before anything is written"
}

test_request_written_woken_and_idempotent_per_period
test_new_period_writes_its_own_request
test_refused_without_live_session
test_invalid_arguments_refused

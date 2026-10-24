#!/usr/bin/env bash
# tests/fm-wake-drain-bounded.test.sh - a small-queue drain is bounded, and a
# bounded presentation loses nothing.
#
# The drain's status presentation cost tracks unread status lines (its per-line
# work forks), not queue size, and it used to run to completion with no bound:
# a home with many status lines, or a slowed filesystem, could push a drain with
# one queued row past ninety seconds. This pins the contract the fix added:
#
#   * the presentation phase runs under FM_WAKE_DRAIN_PRESENTATION_TIMEOUT;
#   * exceeding it prints a typed, retriable deferral instead of stalling;
#   * the deferred work is still unread, so the next drain presents it;
#   * the wake rows themselves are presented either way (no swallowed wake).
#
# Determinism comes from a reader seam the classify library already exposes:
# FM_STATUS_SIZE_READER answers the per-file size for every status file, so a
# deliberate sleep slows presentation without touching the clock.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-wake-drain-bounded-tests)

mkdir -p "$TMP_ROOT/config"
: > "$TMP_ROOT/config/supervision-host-off"

make_drain_case() { # <name> -> case dir with one durable wake and unread status
  local name=$1 dir
  dir=$(make_case "$name")
  printf 'note: the captain wants the drain bounded end to end\n' > "$dir/state/task1.status"
  append_wake "$dir/state" check "bounded-${name}" "check: bounded drain fixture for ${name}"
  printf '%s\n' "$dir"
}

# run_drain <dir> <out-file> <err-file> [env assignments...]
# Writes stdout to <out-file> and leaves the exit status in DRAIN_STATUS, which a
# command substitution would not carry back to the caller.
run_drain() {
  local dir=$1 out=$2 err=$3
  shift 3
  DRAIN_STATUS=0
  env "$@" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$TMP_ROOT/config" \
    "$DRAIN" > "$out" 2> "$err" || DRAIN_STATUS=$?
}

wait_seconds() { # <start-epoch>
  printf '%s' "$(( $(date +%s) - $1 ))"
}

test_slow_presentation_defers_within_the_bound() {
  local dir out err started elapsed
  dir=$(make_drain_case slow-presentation)
  cat > "$dir/slow-reader.sh" <<'SH'
#!/usr/bin/env bash
sleep 1
exec wc -c < "$1"
SH
  chmod +x "$dir/slow-reader.sh"
  err="$dir/drain.err"
  started=$(date +%s)
  run_drain "$dir" "$dir/drain.out" "$err" FM_STATUS_SIZE_READER="$dir/slow-reader.sh" FM_WAKE_DRAIN_PRESENTATION_TIMEOUT=2
  out=$(cat "$dir/drain.out")
  elapsed=$(wait_seconds "$started")
  [ "$DRAIN_STATUS" -eq 0 ] || fail "a bounded drain failed instead of deferring: $(cat "$err")"
  [ "$elapsed" -lt 30 ] || fail "a slow presentation was not bounded: drain took ${elapsed}s"
  printf '%s' "$out" | grep -F 'STATUS PRESENTATION DEFERRED' >/dev/null \
    || fail "the bounded drain did not report its deferral: $out"
  printf '%s' "$out" | grep -F 'bounded-slow-presentation' >/dev/null \
    || fail "the bounded drain dropped the queued wake row: $out"
  [ ! -e "$dir/state/.status-presentation-cursor" ] \
    || fail 'a deferred presentation committed its cursor, which would swallow the unread lines'
  pass 'a slow presentation is deferred within the bound, the wake row still surfaces, and nothing is marked read'
}

test_deferred_presentation_is_presented_by_the_next_drain() {
  local dir out err
  dir=$(make_drain_case deferred-recovers)
  cat > "$dir/slow-reader.sh" <<'SH'
#!/usr/bin/env bash
sleep 1
exec wc -c < "$1"
SH
  chmod +x "$dir/slow-reader.sh"
  err="$dir/drain.err"
  run_drain "$dir" "$dir/drain1.out" "$err" FM_STATUS_SIZE_READER="$dir/slow-reader.sh" FM_WAKE_DRAIN_PRESENTATION_TIMEOUT=2
  out=$(cat "$dir/drain1.out")
  printf '%s' "$out" | grep -F 'STATUS PRESENTATION DEFERRED' >/dev/null \
    || fail "the first drain did not defer: $out"

  run_drain "$dir" "$dir/drain2.out" "$err" FM_WAKE_DRAIN_PRESENTATION_TIMEOUT=20
  out=$(cat "$dir/drain2.out")
  [ "$DRAIN_STATUS" -eq 0 ] || fail "the recovery drain failed: $(cat "$err")"
  printf '%s' "$out" | grep -F 'UNREAD STATUS' >/dev/null \
    || fail "the deferred status section was lost: $out"
  printf '%s' "$out" | grep -F 'the captain wants the drain bounded end to end' >/dev/null \
    || fail "the deferred status line was not presented by the next drain: $out"
  pass 'a deferred presentation is retried and presented by the next drain'
}

test_held_queue_lock_returns_bounded() {
  local dir out err started elapsed holder
  dir=$(make_drain_case held-queue-lock)
  err="$dir/drain.err"
  # A live holder is what an unbounded spin waits on forever; use the real lock
  # helper so the fixture cannot drift from the production lock shape.
  bash -c '. "$1"; fm_lock_acquire_wait "$2"; sleep 60' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$dir/state/.wake-queue.lock" &
  holder=$!
  sleep 0.5
  started=$(date +%s)
  run_drain "$dir" "$dir/drain.out" "$err" FM_STATUS_PRESENTATION_LOCK_TIMEOUT=2
  out=$(cat "$dir/drain.out")
  elapsed=$(wait_seconds "$started")
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ "$DRAIN_STATUS" -eq 0 ] || fail "a held queue lock failed the drain instead of skipping it: $(cat "$err")"
  [ "$elapsed" -lt 20 ] || fail "a held queue lock stalled the drain for ${elapsed}s"
  printf '%s' "$out" | grep -F 'WAKE DRAIN SKIPPED' >/dev/null \
    || fail "a held queue lock produced no typed advisory: $out"
  pass 'a live queue-lock holder produces a bounded, typed skip instead of wedging the drain'
}

test_slow_presentation_defers_within_the_bound
test_deferred_presentation_is_presented_by_the_next_drain
test_held_queue_lock_returns_bounded

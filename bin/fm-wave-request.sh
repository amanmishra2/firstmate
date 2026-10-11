#!/usr/bin/env bash
# fm-wave-request.sh - write the durable weekly research-wave request.
#
# The weekly trigger of the research-wave program. One call per period writes
# data/research-wave/request-<date>.md and wakes firstmate with a
# `check: research wave request <date>` line, so the wave is triggered by a
# durable record rather than by a session remembering a schedule.
# The wave procedure that reads the request is .agents/skills/research-wave/SKILL.md;
# docs/research-wave.md is the operator reference for the weekly plist, the
# switches, and the rollback.
#
# Usage:
#   fm-wave-request.sh [--date <YYYY-MM-DD>] [--project <name>] [--loop <path>]
#
#   --date     request date, also the request file's name (default: today, UTC).
#              Tests pin it; a manual catch-up run may backdate it.
#   --project  registered project whose clone holds the loop (default: job-crawler).
#   --loop     loop dispatcher path inside that clone
#              (default: scripts/research-loop/dispatch.py).
#
# Idempotent per ISO week: when a request whose period= is the current period
# already exists, nothing is written and the existing request is reported
# present. The period check runs before the live-session gate, so any re-run in
# the same week is a no-op that cannot fail for a lock that moved on.
#
# Fail closed without a live session: a request exists to be picked up, and a
# home whose session lock is not held by a live verified harness (the exact
# `held` reading of bin/fm-session-lock-lib.sh, the same inspection
# `fm-inbox.sh ready` uses) has nobody on watch. Nothing is requested then: the
# refusal appends one escalation through bin/fm-notify.sh and exits 1, leaving
# no request file behind for a later wave to mistake for a pending period.
#
# Request format (single writer: this script; readers treat it as read-only and
# never rewrite it, because the scorecard is the wave's record):
#   period=<ISO year and week, e.g. 2026-W41>
#   date=<YYYY-MM-DD>
#   at=<UTC ISO-8601 timestamp>
#   project=<registered project name>
#   loop=<loop dispatcher path inside the project clone>
#
# Output: exactly one status line.
#   requested <request-path>                    request written and firstmate woken
#   requested <request-path> wake=failed        written, NOT woken (exit 3)
#   present <request-path>                      this period's request already exists
#   refused no-live-session: lock <state> (alert logged|failed)   (exit 1)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
WAVE_DIR="$DATA/research-wave"

DATE=$(date -u +%Y-%m-%d)
PROJECT=job-crawler
LOOP=scripts/research-loop/dispatch.py

usage() {
  awk 'NR == 1 { next }
       /^#/ { sub(/^# ?/, ""); print; next }
       { exit }' "${BASH_SOURCE[0]}"
  exit 2
}

die() {
  printf 'fm-wave-request: %s\n' "$*" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --date)
      [ "$#" -ge 2 ] || usage
      DATE=$2
      shift 2
      ;;
    --project)
      [ "$#" -ge 2 ] || usage
      PROJECT=$2
      shift 2
      ;;
    --loop)
      [ "$#" -ge 2 ] || usage
      LOOP=$2
      shift 2
      ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

case "$DATE" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
  *) die "invalid --date (expected YYYY-MM-DD): $DATE" ;;
esac
case "$PROJECT" in
  ''|*[!A-Za-z0-9._-]*) die "invalid --project: $PROJECT" ;;
esac
case "$LOOP" in
  ''|*[!A-Za-z0-9._/-]*) die "invalid --loop: $LOOP" ;;
esac

# ISO year and week for the request date. GNU date takes -d; BSD date (macOS)
# takes -j -f. Whichever probe parses the date is the one that understood the
# request, exactly as tests/lib.sh's fm_touch_epoch documents for the same
# split. Neither probe succeeding means the date itself is invalid.
iso_week() {  # <YYYY-MM-DD>
  local d=$1 week
  if week=$(date -u -d "$d" +%G-W%V 2>/dev/null) && [ -n "$week" ]; then
    printf '%s\n' "$week"
    return 0
  fi
  if week=$(date -u -j -f %Y-%m-%d "$d" +%G-W%V 2>/dev/null) && [ -n "$week" ]; then
    printf '%s\n' "$week"
    return 0
  fi
  return 1
}

PERIOD=$(iso_week "$DATE") || die "cannot resolve an ISO week for date: $DATE"

# The existing request for this period, if any. A request is one single-link
# regular file; anything else in the directory is not a request.
period_request() {
  local f
  for f in "$WAVE_DIR"/request-*.md; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    if grep -F -x -q "period=$PERIOD" "$f" 2>/dev/null; then
      printf '%s\n' "$f"
      return 0
    fi
  done
  return 1
}

if EXISTING=$(period_request); then
  printf 'present %s\n' "$EXISTING"
  exit 0
fi

# Live-session gate. `held` is the only state that promises a watcher on this
# home; every other reading (free, stale, unreadable, unknown) fails closed.
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
fm_session_lock_inspect "$STATE"
if [ "$FM_LOCK_INSPECT_STATE" != held ]; then
  ALERT=logged
  if ! FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-notify.sh" \
    --title "Firstmate research wave" \
    "Research wave request $DATE not queued: no live firstmate session (lock=$FM_LOCK_INSPECT_STATE). Start a session and run bin/fm-wave-request.sh." \
    >/dev/null 2>&1; then
    ALERT=failed
    printf 'fm-wave-request: escalation could not be logged under %s\n' "$DATA" >&2
  fi
  printf 'refused no-live-session: lock %s (alert %s)\n' "$FM_LOCK_INSPECT_STATE" "$ALERT"
  exit 1
fi

mkdir -p "$WAVE_DIR" || die "cannot create $WAVE_DIR"
umask 077
REQUEST="$WAVE_DIR/request-$DATE.md"
TMP=$(mktemp "$WAVE_DIR/.request-XXXXXX") || die "cannot stage a request under $WAVE_DIR"
{
  printf 'period=%s\n' "$PERIOD"
  printf 'date=%s\n' "$DATE"
  printf 'at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'project=%s\n' "$PROJECT"
  printf 'loop=%s\n' "$LOOP"
} > "$TMP" || { rm -f "$TMP"; die "cannot write the request"; }
mv -f "$TMP" "$REQUEST" || { rm -f "$TMP"; die "cannot publish the request"; }

# Wake firstmate. The request record is already durable, so a wake failure
# leaves the wave owed rather than lost; report it as a partial outcome.
WAKE_FAILED=0
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
if fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"; then
  if ! fm_wake_append_locked check "research-wave:$PERIOD" \
    "check: research wave request $DATE - read $REQUEST"; then
    WAKE_FAILED=1
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
else
  WAKE_FAILED=1
fi

if [ "$WAKE_FAILED" -eq 1 ]; then
  printf 'requested %s wake=failed\n' "$REQUEST"
  printf 'fm-wave-request: request saved at %s but firstmate was NOT woken\n' "$REQUEST" >&2
  exit 3
fi
printf 'requested %s\n' "$REQUEST"

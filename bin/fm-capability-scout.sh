#!/usr/bin/env bash
# fm-capability-scout.sh - cadence mechanics for the monthly capability scout.
#
# Single owner of the one-session-per-UTC-calendar-month due test that lets the
# capability scout ride the first weekly review of each month with no daemon,
# cron job, or platform project. The scout PROCEDURE (wave size, security gate, durable-learning bar,
# store targets, rejection log) is owned by
# .agents/skills/capability-scout/SKILL.md; this script owns only the date
# arithmetic and its durable anchor under
# data/capability-scout/last-sweep.
#
# Usage:
#   fm-capability-scout.sh due [--now <epoch>]
#   fm-capability-scout.sh mark [--task <id>] [--now <epoch>]
#
#   due     prints CAPABILITY_SCOUT_DUE: true and exits 0 when no anchor exists
#           or its validated UTC date is in another UTC calendar month, otherwise
#           prints false and exits 1, so a weekly review can branch on it
#           directly. Exit 2 is a real error for a corrupt or unsafe anchor.
#   mark    records the sweep anchor after the scout session is dispatched,
#           so a failed session still consumes that month's single session
#           budget instead of re-triggering every week. --task records the
#           dispatched task id for traceability.
#
# --now <epoch> is a deterministic-test and replay override only; it must be
# plain digits. The anchor is key=value text written atomically; a corrupt or
# symlinked anchor is refused rather than repaired, so a damaged record is
# repaired deliberately instead of silently resetting the cadence.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

SCOUT_DIR="$DATA/capability-scout"
ANCHOR="$SCOUT_DIR/last-sweep"

LAST_EPOCH=''
LAST_DATE=''

usage() {
  sed -n '2,24{s/^# \{0,1\}//;p;}' "$0"
}

die() {
  printf 'capability-scout: %s\n' "$1" >&2
  exit 2
}

is_digits() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  return 0
}

# UTC calendar date for an epoch, on BSD and GNU date alike.
epoch_to_date() {
  local epoch=$1 out
  if out=$(date -u -r "$epoch" +%Y-%m-%d 2>/dev/null) && [ -n "$out" ]; then
    printf '%s\n' "$out"
    return 0
  fi
  date -u -d "@$epoch" +%Y-%m-%d
}

normalize_epoch() {
  local epoch=$1
  is_digits "$epoch" || return 1
  while [ "${epoch#0}" != "$epoch" ]; do
    epoch=${epoch#0}
  done
  [ -n "$epoch" ] || epoch=0
  epoch_to_date "$epoch" >/dev/null 2>&1 || return 1
  printf '%s\n' "$epoch"
}

utc_month() {
  printf '%s\n' "${1%-*}"
}

next_month_start() {
  local date=$1 year month next_month
  year=${date%%-*}
  month=${date#*-}
  month=${month%%-*}
  case "$month" in
    01) next_month=02 ;;
    02) next_month=03 ;;
    03) next_month=04 ;;
    04) next_month=05 ;;
    05) next_month=06 ;;
    06) next_month=07 ;;
    07) next_month=08 ;;
    08) next_month=09 ;;
    09) next_month=10 ;;
    10) next_month=11 ;;
    11) next_month=12 ;;
    12)
      year=$(printf '%04d' "$((10#$year + 1))")
      next_month=01
      ;;
    *) return 1 ;;
  esac
  printf '%s-%s-01\n' "$year" "$next_month"
}

read_anchor() {
  LAST_EPOCH=''
  LAST_DATE=''
  [ ! -L "$SCOUT_DIR" ] || die "refusing symlinked data directory $SCOUT_DIR"
  if [ -e "$SCOUT_DIR" ] && [ ! -d "$SCOUT_DIR" ]; then
    die "data directory is not a directory: $SCOUT_DIR"
  fi
  [ ! -L "$ANCHOR" ] || die "refusing symlinked anchor $ANCHOR"
  [ -e "$ANCHOR" ] || return 0
  [ -f "$ANCHOR" ] || die "anchor is not a regular file: $ANCHOR"
  local line key val canonical_date
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    case "$line" in
      *=*) ;;
      *) die "corrupt anchor $ANCHOR: line without '=': $line" ;;
    esac
    key=${line%%=*}
    val=${line#*=}
    case "$key" in
      last_epoch) LAST_EPOCH=$val ;;
      last_date) LAST_DATE=$val ;;
    esac
  done < "$ANCHOR"
  is_digits "$LAST_EPOCH" || die "corrupt anchor $ANCHOR: last_epoch is not plain digits"
  if ! LAST_EPOCH=$(normalize_epoch "$LAST_EPOCH"); then
    die "corrupt anchor $ANCHOR: last_epoch is not a valid epoch"
  fi
  [ -n "$LAST_DATE" ] || die "corrupt anchor $ANCHOR: last_date is missing"
  if ! canonical_date=$(epoch_to_date "$LAST_EPOCH" 2>/dev/null); then
    die "corrupt anchor $ANCHOR: last_epoch is not a valid epoch"
  fi
  [ "$LAST_DATE" = "$canonical_date" ] || die "corrupt anchor $ANCHOR: last_date does not match last_epoch"
}

resolve_now() {
  local given=$1 epoch
  if [ -n "$given" ]; then
    is_digits "$given" || die "--now must be an epoch in plain digits"
    if ! epoch=$(normalize_epoch "$given"); then
      die "--now must be a representable epoch in plain digits"
    fi
  else
    epoch=$(date +%s)
    if ! epoch=$(normalize_epoch "$epoch"); then
      die "current time is not a representable epoch"
    fi
  fi
  printf '%s\n' "$epoch"
}

cmd_due() {
  local now=$1 due now_date next_due
  read_anchor
  if ! now_date=$(epoch_to_date "$now" 2>/dev/null); then
    die "current epoch is not a valid UTC date"
  fi
  if [ -z "$LAST_DATE" ] || [ "$(utc_month "$LAST_DATE")" != "$(utc_month "$now_date")" ]; then
    due=true
  else
    due=false
  fi
  if ! next_due=$(next_month_start "$now_date"); then
    die "current epoch is not a valid UTC month"
  fi
  printf 'CAPABILITY_SCOUT_DUE: %s\n' "$due"
  if [ -n "$LAST_DATE" ]; then
    printf 'last_sweep=%s\n' "$LAST_DATE"
  else
    printf 'last_sweep=none\n'
  fi
  printf 'next_due=%s\n' "$next_due"
  [ "$due" = true ]
}

cmd_mark() {
  local now=$1 task=$2 mark_date
  if [ -n "$task" ]; then
    case "$task" in
      *[!A-Za-z0-9._-]*) die "--task must be a plain task id (letters, digits, dot, dash, underscore)" ;;
    esac
  fi
  if ! mark_date=$(epoch_to_date "$now" 2>/dev/null); then
    die "mark epoch is not a valid epoch"
  fi
  read_anchor
  mkdir -p "$SCOUT_DIR" || die "cannot create $SCOUT_DIR"
  local tmp
  tmp=$(mktemp "$SCOUT_DIR/.last-sweep.XXXXXX") || die "cannot create a temporary anchor in $SCOUT_DIR"
  chmod 600 "$tmp"
  {
    printf 'last_epoch=%s\n' "$now"
    printf 'last_date=%s\n' "$mark_date"
    printf 'task=%s\n' "$task"
  } > "$tmp"
  mv -f -- "$tmp" "$ANCHOR" || die "cannot write $ANCHOR"
  printf 'marked capability scout sweep: %s\n' "$mark_date"
}

CMD=${1:-}
case "$CMD" in
  -h|--help)
    usage
    exit 0
    ;;
esac
if [ -z "$CMD" ]; then
  usage >&2
  exit 2
fi
shift
NOW=''
TASK=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --now)
      [ "$#" -ge 2 ] || die "--now requires an epoch"
      NOW=$2
      shift 2
      ;;
    --task)
      [ "$#" -ge 2 ] || die "--task requires an id"
      TASK=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

NOW=$(resolve_now "$NOW")
case "$CMD" in
  due)
    cmd_due "$NOW"
    ;;
  mark)
    cmd_mark "$NOW" "$TASK"
    ;;
  *)
    printf 'capability-scout: unknown command: %s\n' "$CMD" >&2
    usage >&2
    exit 2
    ;;
esac

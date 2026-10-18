#!/usr/bin/env bash
# fm-capability-scout.sh - cadence mechanics for the monthly capability scout.
#
# Single owner of the one-session-per-UTC-calendar-month due test that lets the
# capability scout ride the first weekly review of each month with no daemon,
# cron job, or platform project. The scout PROCEDURE (wave size, security gate, durable-learning bar,
# store targets, rejection log) is owned by
# .agents/skills/capability-scout/SKILL.md; this script owns only the date
# arithmetic, its dispatch claim under data/capability-scout/claim/, and its
# durable anchor under data/capability-scout/last-sweep.
#
# Usage:
#   fm-capability-scout.sh due [--now <epoch>]
#   fm-capability-scout.sh claim --task <id> [--now <epoch>]
#   fm-capability-scout.sh start --task <id> [--now <epoch>]
#   fm-capability-scout.sh mark --task <id> [--now <epoch>]
#   fm-capability-scout.sh release [--task <id>] [--now <epoch>]
#
#   due     prints CAPABILITY_SCOUT_DUE: true and exits 0 when no anchor exists
#           or its validated UTC date is in another UTC calendar month, otherwise
#           prints false and exits 1, so a weekly review can branch on it
#           directly. A fresh claim also makes due false; a started claim keeps
#           its start month closed and is never stale-retaken. Exit 2 is a real
#           error for corrupt or unsafe state.
#   claim   atomically reserves the due monthly dispatch for --task <id>.
#           A fresh claim is refused; an unstarted claim at least 24 hours old
#           may be retaken.
#   start   records durable dispatch-started state for the owning claim before
#           dispatch. Started claims cannot be released or stale-retaken; the
#           next month can retire the prior started claim after anchoring it.
#   mark    records the sweep anchor once dispatch starts, so a failed session
#           still consumes that month's single session budget. It then clears the
#           claim owned by --task, which is required for every mark.
#   release clears a claim only when dispatch never started and succeeds as a
#           no-op when no claim exists. When a claim exists, --task is required
#           and must identify the current claim.
#
# Workflow: claim --task <review-id> -> start --task <review-id> -> dispatch ->
# mark --task <review-id>. If dispatch never starts, release the unstarted claim.
#
# --now <epoch> is a deterministic-test and replay override only; it must be
# plain digits. The claim metadata and anchor are key=value text written under
# validated non-symlinked directories; corrupt state is refused rather than
# repaired or silently resetting the cadence.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

SCOUT_DIR="$DATA/capability-scout"
ANCHOR="$SCOUT_DIR/last-sweep"
CLAIM_DIR="$SCOUT_DIR/claim"
CLAIM_META="$CLAIM_DIR/metadata"
CLAIM_START_MARKER="$CLAIM_DIR/.dispatch-started"

LAST_EPOCH=''
LAST_DATE=''
LAST_TASK=''
CLAIM_PRESENT=false
CLAIM_STATE=none
CLAIM_EPOCH=''
CLAIM_DATE=''
CLAIM_TASK=''
CLAIM_STARTED=false
CLAIM_STARTED_EPOCH=''
CLAIM_STARTED_DATE=''

usage() {
  sed -n '2,/^set -eu$/ { /^set -eu$/d; s/^# \{0,1\}//; p; }' "$0"
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
  if out=$(date -u -d "@$epoch" +%Y-%m-%d 2>/dev/null) && [ -n "$out" ]; then
    printf '%s\n' "$out"
    return 0
  fi
  date -u -r "$epoch" +%Y-%m-%d
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

validate_task() {
  local task=$1 label=$2
  [ -n "$task" ] || die "$label must be a plain task id (letters, digits, dot, dash, underscore)"
  case "$task" in
    *[!A-Za-z0-9._-]*) die "$label must be a plain task id (letters, digits, dot, dash, underscore)" ;;
  esac
}

validate_paths() {
  [ ! -L "$SCOUT_DIR" ] || die "refusing symlinked data directory $SCOUT_DIR"
  if [ -e "$SCOUT_DIR" ] && [ ! -d "$SCOUT_DIR" ]; then
    die "data directory is not a directory: $SCOUT_DIR"
  fi
  [ ! -L "$ANCHOR" ] || die "refusing symlinked anchor $ANCHOR"
  if [ -e "$ANCHOR" ] && [ ! -f "$ANCHOR" ]; then
    die "anchor is not a regular file: $ANCHOR"
  fi
  [ ! -L "$CLAIM_DIR" ] || die "refusing symlinked claim path $CLAIM_DIR"
  if [ -e "$CLAIM_DIR" ] && [ ! -d "$CLAIM_DIR" ]; then
    die "claim path is not a directory: $CLAIM_DIR"
  fi
  if [ -d "$CLAIM_DIR" ]; then
    [ ! -L "$CLAIM_META" ] || die "refusing symlinked claim metadata $CLAIM_META"
    if [ -e "$CLAIM_META" ] && [ ! -f "$CLAIM_META" ]; then
      die "claim metadata is not a regular file: $CLAIM_META"
    fi
    [ ! -L "$CLAIM_START_MARKER" ] || die "refusing symlinked dispatch-start marker $CLAIM_START_MARKER"
    if [ -e "$CLAIM_START_MARKER" ] && [ ! -d "$CLAIM_START_MARKER" ]; then
      die "dispatch-start marker is not a directory: $CLAIM_START_MARKER"
    fi
  fi
}

mtime_epoch() {
  local path=$1 mtime
  if mtime=$(stat -f %m "$path" 2>/dev/null) && is_digits "$mtime"; then
    printf '%s\n' "$mtime"
    return 0
  fi
  if mtime=$(stat -c %Y "$path" 2>/dev/null) && is_digits "$mtime"; then
    printf '%s\n' "$mtime"
    return 0
  fi
  return 1
}

read_claim_from_dir() {
  local dir=$1 allow_pending=$2
  local started_marker=false
  CLAIM_STATE=none
  CLAIM_EPOCH=''
  CLAIM_DATE=''
  CLAIM_TASK=''
  CLAIM_STARTED=false
  CLAIM_STARTED_EPOCH=''
  CLAIM_STARTED_DATE=''
  [ ! -L "$dir" ] || die "refusing symlinked claim path $dir"
  [ -d "$dir" ] || die "claim path is not a directory: $dir"
  local meta="$dir/metadata"
  local marker="$dir/.dispatch-started"
  [ ! -L "$meta" ] || die "refusing symlinked claim metadata $meta"
  [ ! -L "$marker" ] || die "refusing symlinked dispatch-start marker $marker"
  if [ -e "$marker" ]; then
    [ -d "$marker" ] || die "dispatch-start marker is not a directory: $marker"
    started_marker=true
  fi
  if [ ! -e "$meta" ]; then
    [ "$allow_pending" = true ] || die "claim metadata is missing: $meta"
    [ "$started_marker" = false ] || die "claim metadata is missing beside dispatch-start marker: $meta"
    CLAIM_STATE=pending
    return 0
  fi
  [ -f "$meta" ] || die "claim metadata is not a regular file: $meta"
  local line key val canonical_date started_seen=false
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    case "$line" in
      *=*) ;;
      *) die "corrupt claim $meta: line without '=': $line" ;;
    esac
    key=${line%%=*}
    val=${line#*=}
    case "$key" in
      claim_epoch) CLAIM_EPOCH=$val ;;
      claim_date) CLAIM_DATE=$val ;;
      task) CLAIM_TASK=$val ;;
      dispatch_started) CLAIM_STARTED=$val; started_seen=true ;;
      dispatch_started_epoch) CLAIM_STARTED_EPOCH=$val ;;
      dispatch_started_date) CLAIM_STARTED_DATE=$val ;;
    esac
  done < "$meta"
  is_digits "$CLAIM_EPOCH" || die "corrupt claim $meta: claim_epoch is not plain digits"
  if ! CLAIM_EPOCH=$(normalize_epoch "$CLAIM_EPOCH"); then
    die "corrupt claim $meta: claim_epoch is not a valid epoch"
  fi
  [ -n "$CLAIM_DATE" ] || die "corrupt claim $meta: claim_date is missing"
  if ! canonical_date=$(epoch_to_date "$CLAIM_EPOCH" 2>/dev/null); then
    die "corrupt claim $meta: claim_epoch is not a valid epoch"
  fi
  [ "$CLAIM_DATE" = "$canonical_date" ] || die "corrupt claim $meta: claim_date does not match claim_epoch"
  validate_task "$CLAIM_TASK" "claim task"
  if [ "$started_seen" = false ]; then
    CLAIM_STARTED=false
  fi
  case "$CLAIM_STARTED" in
    false)
      [ -z "$CLAIM_STARTED_EPOCH" ] && [ -z "$CLAIM_STARTED_DATE" ] \
        || die "corrupt claim $meta: unstarted claim carries dispatch-started data"
      ;;
    true)
      is_digits "$CLAIM_STARTED_EPOCH" \
        || die "corrupt claim $meta: dispatch_started_epoch is not plain digits"
      if ! CLAIM_STARTED_EPOCH=$(normalize_epoch "$CLAIM_STARTED_EPOCH"); then
        die "corrupt claim $meta: dispatch_started_epoch is not a valid epoch"
      fi
      [ "$CLAIM_STARTED_EPOCH" -ge "$CLAIM_EPOCH" ] \
        || die "corrupt claim $meta: dispatch start precedes claim creation"
      if ! canonical_date=$(epoch_to_date "$CLAIM_STARTED_EPOCH" 2>/dev/null); then
        die "corrupt claim $meta: dispatch_started_epoch is not a valid epoch"
      fi
      [ "$CLAIM_STARTED_DATE" = "$canonical_date" ] \
        || die "corrupt claim $meta: dispatch_started_date does not match dispatch_started_epoch"
      [ "$(utc_month "$CLAIM_STARTED_DATE")" = "$(utc_month "$CLAIM_DATE")" ] \
        || die "corrupt claim $meta: dispatch start is outside the claim month"
      ;;
    *)
      die "corrupt claim $meta: dispatch_started must be true or false"
      ;;
  esac
  if [ "$started_marker" = true ] && [ "$CLAIM_STARTED" = false ]; then
    CLAIM_STARTED=true
    CLAIM_STARTED_EPOCH=$CLAIM_EPOCH
    CLAIM_STARTED_DATE=$CLAIM_DATE
  fi
  CLAIM_STATE=ready
}

read_claim() {
  CLAIM_PRESENT=false
  CLAIM_STATE=none
  CLAIM_EPOCH=''
  CLAIM_DATE=''
  CLAIM_TASK=''
  CLAIM_STARTED=false
  CLAIM_STARTED_EPOCH=''
  CLAIM_STARTED_DATE=''
  validate_paths
  [ -e "$CLAIM_DIR" ] || return 0
  CLAIM_PRESENT=true
  read_claim_from_dir "$CLAIM_DIR" true
}

read_anchor() {
  LAST_EPOCH=''
  LAST_DATE=''
  LAST_TASK=''
  validate_paths
  [ -e "$ANCHOR" ] || return 0
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
      task) LAST_TASK=$val ;;
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
  [ -n "$LAST_TASK" ] || die "corrupt anchor $ANCHOR: task is missing"
  case "$LAST_TASK" in
    *[!A-Za-z0-9._-]*) die "corrupt anchor $ANCHOR: task is not a plain task id" ;;
  esac
}

claim_is_stale() {
  local now=$1 claim_epoch
  case "$CLAIM_STATE" in
    ready)
      [ "$CLAIM_STARTED" = false ] || return 1
      claim_epoch=$CLAIM_EPOCH
      ;;
    pending)
      if ! claim_epoch=$(mtime_epoch "$CLAIM_DIR"); then
        die "cannot read claim directory mtime: $CLAIM_DIR"
      fi
      ;;
    *)
      return 1
      ;;
  esac
  [ "$now" -ge "$claim_epoch" ] || return 1
  [ "$((now - claim_epoch))" -ge 86400 ]
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

cadence_is_due() {
  local now_date=$1
  [ -z "$LAST_DATE" ] || [ "$(utc_month "$LAST_DATE")" != "$(utc_month "$now_date")" ]
}

print_claim_state() {
  local now=$1 state
  case "$CLAIM_STATE" in
    none)
      printf 'claim_state=none\n'
      ;;
    pending)
      if claim_is_stale "$now"; then
        printf 'claim_state=stale\n'
      else
        printf 'claim_state=pending\n'
      fi
      ;;
    ready)
      if [ "$CLAIM_STARTED" = true ]; then
        state=started
      elif claim_is_stale "$now"; then
        state=stale
      else
        state=fresh
      fi
      printf 'claim_state=%s\n' "$state"
      printf 'claim_epoch=%s\n' "$CLAIM_EPOCH"
      printf 'claim_date=%s\n' "$CLAIM_DATE"
      printf 'claim_task=%s\n' "$CLAIM_TASK"
      if [ "$CLAIM_STARTED" = true ]; then
        printf 'claim_started=true\n'
        printf 'claim_started_epoch=%s\n' "$CLAIM_STARTED_EPOCH"
        printf 'claim_started_date=%s\n' "$CLAIM_STARTED_DATE"
      else
        printf 'claim_started=false\n'
      fi
      ;;
    *)
      die "unknown claim state: $CLAIM_STATE"
      ;;
  esac
}

write_claim_metadata() {
  local dir=$1 epoch=$2 claim_date=$3 task=$4 tmp meta
  validate_task "$task" "--task"
  [ ! -L "$dir" ] || die "refusing symlinked claim path $dir"
  [ -d "$dir" ] || die "claim path is not a directory: $dir"
  meta="$dir/metadata"
  [ ! -L "$meta" ] || die "refusing symlinked claim metadata $meta"
  [ ! -e "$meta" ] || die "claim metadata already exists: $meta"
  tmp=$(mktemp "$SCOUT_DIR/.claim-metadata.XXXXXX") || die "cannot create temporary claim metadata in $SCOUT_DIR"
  chmod 600 "$tmp" || die "cannot secure temporary claim metadata in $dir"
  {
    printf 'claim_epoch=%s\n' "$epoch"
    printf 'claim_date=%s\n' "$claim_date"
    printf 'task=%s\n' "$task"
    printf 'dispatch_started=false\n'
    printf 'dispatch_started_epoch=\n'
    printf 'dispatch_started_date=\n'
  } > "$tmp"
  mv -f -- "$tmp" "$meta" || die "cannot write claim metadata $meta"
}

write_claim_started_metadata() {
  local dir=$1 epoch=$2 claim_date=$3 task=$4 started_epoch=$5 started_date=$6 meta marker
  local metadata_tmp
  validate_task "$task" "claim task"
  validate_paths
  [ ! -L "$dir" ] || die "refusing symlinked claim path $dir"
  [ -d "$dir" ] || die "claim path is not a directory: $dir"
  meta="$dir/metadata"
  marker="$dir/.dispatch-started"
  [ ! -L "$meta" ] || die "refusing symlinked claim metadata $meta"
  [ -f "$meta" ] || die "claim metadata is missing: $meta"
  read_claim_from_dir "$dir" false
  [ "$CLAIM_STATE" = ready ] && [ "$CLAIM_EPOCH" = "$epoch" ] && \
    [ "$CLAIM_DATE" = "$claim_date" ] && [ "$CLAIM_TASK" = "$task" ] && \
    [ "$CLAIM_STARTED" = false ] \
    || die "claim changed before dispatch started"

  if ! mkdir -- "$marker" 2>/dev/null; then
    read_claim_from_dir "$dir" false
    if [ "$CLAIM_STATE" = ready ] && [ "$CLAIM_STARTED" = true ]; then
      die "dispatch has already started for this claim"
    fi
    die "claim changed before dispatch started"
  fi

  metadata_tmp=$(mktemp "$SCOUT_DIR/.claim-metadata.XXXXXX") \
    || die "cannot create a temporary claim metadata in $SCOUT_DIR"
  chmod 600 "$metadata_tmp" || {
    rm -f -- "$metadata_tmp"
    die "cannot secure temporary claim metadata in $dir"
  }
  {
    printf 'claim_epoch=%s\n' "$epoch"
    printf 'claim_date=%s\n' "$claim_date"
    printf 'task=%s\n' "$task"
    printf 'dispatch_started=true\n'
    printf 'dispatch_started_epoch=%s\n' "$started_epoch"
    printf 'dispatch_started_date=%s\n' "$started_date"
  } > "$metadata_tmp" || {
    rm -f -- "$metadata_tmp"
    die "cannot write temporary claim metadata in $SCOUT_DIR"
  }
  if ! mv -f -- "$metadata_tmp" "$meta"; then
    rm -f -- "$metadata_tmp"
    die "cannot record dispatch start in $meta"
  fi
}

cmd_start() {
  local now=$1 task=$2 started_date
  validate_task "$task" "--task"
  if ! started_date=$(epoch_to_date "$now" 2>/dev/null); then
    die "dispatch-start epoch is not a valid UTC date"
  fi
  read_anchor
  read_claim
  [ "$CLAIM_STATE" = ready ] || die "a ready capability scout claim is required before dispatch"
  [ "$CLAIM_TASK" = "$task" ] || die "claim belongs to task $CLAIM_TASK, not $task"
  [ "$CLAIM_STARTED" = false ] || die "dispatch has already started for this claim"
  claim_is_stale "$now" && die "capability scout claim expired before dispatch started"
  [ "$now" -ge "$CLAIM_EPOCH" ] || die "dispatch start precedes claim creation"
  [ "$(utc_month "$CLAIM_DATE")" = "$(utc_month "$started_date")" ] \
    || die "dispatch start is outside the claim month"
  cadence_is_due "$started_date" \
    || die "capability scout dispatch is no longer due in the current UTC month"
  local claim_epoch=$CLAIM_EPOCH claim_date=$CLAIM_DATE claim_task=$CLAIM_TASK
  write_claim_started_metadata "$CLAIM_DIR" "$claim_epoch" "$claim_date" "$claim_task" \
    "$now" "$started_date"
  read_claim
  [ "$CLAIM_STATE" = ready ] && [ "$CLAIM_EPOCH" = "$claim_epoch" ] && \
    [ "$CLAIM_DATE" = "$claim_date" ] && [ "$CLAIM_TASK" = "$claim_task" ] && \
    [ "$CLAIM_STARTED" = true ] && [ "$CLAIM_STARTED_EPOCH" = "$now" ] \
    || die "claim changed while recording dispatch start"
  printf 'dispatch started for capability scout claim: %s task=%s\n' "$started_date" "$task"
}

preflight_claim_dir_clear() {
  local dir=$1 meta marker entry
  [ ! -L "$dir" ] || die "refusing symlinked claim path $dir"
  [ -e "$dir" ] || return 0
  [ -d "$dir" ] || die "claim path is not a directory: $dir"
  meta="$dir/metadata"
  marker="$dir/.dispatch-started"
  [ ! -L "$meta" ] || die "refusing symlinked claim metadata $meta"
  if [ -e "$meta" ]; then
    [ -f "$meta" ] || die "claim metadata is not a regular file: $meta"
  fi
  [ ! -L "$marker" ] || die "refusing symlinked dispatch-start marker $marker"
  if [ -e "$marker" ]; then
    [ -d "$marker" ] || die "dispatch-start marker is not a directory: $marker"
  fi
  for entry in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    [ "$entry" = "$meta" ] || [ "$entry" = "$marker" ] \
      || die "cannot clear claim $dir: unexpected contents remain"
  done
}

clear_claim_dir() {
  local dir=$1 meta marker has_meta=false has_marker=false
  preflight_claim_dir_clear "$dir"
  [ -e "$dir" ] || return 0
  meta="$dir/metadata"
  marker="$dir/.dispatch-started"
  if [ -e "$meta" ]; then
    has_meta=true
  fi
  if [ -e "$marker" ]; then
    has_marker=true
  fi
  if [ "$has_meta" = true ]; then
    rm -- "$meta" || die "cannot remove claim metadata $meta"
  fi
  if [ "$has_marker" = true ]; then
    rmdir -- "$marker" || die "cannot remove dispatch-start marker $marker"
  fi
  rmdir -- "$dir" || die "cannot clear claim $dir: unexpected contents remain"
}

claim_metadata_matches() {
  local dir=$1 expected_epoch=$2 expected_date=$3 expected_task=$4
  local expected_started=$5 expected_started_epoch=$6 expected_started_date=$7
  local meta="$dir/metadata" marker="$dir/.dispatch-started" line key val
  local actual_epoch='' actual_date='' actual_task=''
  local actual_started=false actual_started_epoch='' actual_started_date=''
  local marker_present=false canonical_epoch canonical_started_epoch=''
  [ ! -L "$dir" ] && [ -d "$dir" ] || return 1
  [ ! -L "$meta" ] || return 1
  [ ! -L "$marker" ] || return 1
  if [ -e "$marker" ]; then
    [ -d "$marker" ] || return 1
    marker_present=true
  fi

  [ -f "$meta" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
      *=*) ;;
      *) return 1 ;;
    esac
    key=${line%%=*}
    val=${line#*=}
    case "$key" in
      claim_epoch) actual_epoch=$val ;;
      claim_date) actual_date=$val ;;
      task) actual_task=$val ;;
      dispatch_started) actual_started=$val ;;
      dispatch_started_epoch) actual_started_epoch=$val ;;
      dispatch_started_date) actual_started_date=$val ;;
    esac
  done < "$meta"
  if ! canonical_epoch=$(normalize_epoch "$actual_epoch"); then
    return 1
  fi
  if [ "$actual_started" = false ] && [ "$marker_present" = true ]; then
    actual_started=true
    actual_started_epoch=$canonical_epoch
    actual_started_date=$actual_date
    canonical_started_epoch=$canonical_epoch
  elif [ "$actual_started" = true ]; then
    if ! canonical_started_epoch=$(normalize_epoch "$actual_started_epoch"); then
      return 1
    fi
    [ "$actual_started_date" = "$(epoch_to_date "$canonical_started_epoch")" ] || return 1
  fi
  [ "$canonical_epoch" = "$expected_epoch" ] &&
    [ "$actual_date" = "$expected_date" ] &&
    [ "$actual_task" = "$expected_task" ] &&
    [ "$actual_started" = "$expected_started" ] &&
    [ "$canonical_started_epoch" = "$expected_started_epoch" ] &&
    [ "$actual_started_date" = "$expected_started_date" ]
}

clear_current_claim_if_matches() {
  local expected_epoch=$1 expected_date=$2 expected_task=$3
  local expected_started=$4 expected_started_epoch=$5 expected_started_date=$6
  local transition_dir="$SCOUT_DIR/.claim-clear.$$.$RANDOM"
  validate_task "$expected_task" "claim task"
  validate_paths
  [ -e "$CLAIM_DIR" ] || return 0
  read_claim
  [ "$CLAIM_STATE" = pending ] && die "claim metadata is incomplete: $CLAIM_META"
  [ "$CLAIM_STATE" = ready ] || return 0
  [ "$CLAIM_EPOCH" = "$expected_epoch" ] || die "claim changed during clear; refusing to remove the current claim"
  [ "$CLAIM_DATE" = "$expected_date" ] || die "claim changed during clear; refusing to remove the current claim"
  [ "$CLAIM_TASK" = "$expected_task" ] || die "claim changed during clear; refusing to remove the current claim"
  [ "$CLAIM_STARTED" = "$expected_started" ] \
    || die "claim changed during clear; refusing to remove the current claim"
  [ "$CLAIM_STARTED_EPOCH" = "$expected_started_epoch" ] \
    || die "claim changed during clear; refusing to remove the current claim"
  [ "$CLAIM_STARTED_DATE" = "$expected_started_date" ] \
    || die "claim changed during clear; refusing to remove the current claim"
  preflight_claim_dir_clear "$CLAIM_DIR"
  [ ! -e "$transition_dir" ] && [ ! -L "$transition_dir" ] \
    || die "claim clear recovery path already exists: $transition_dir"
  mkdir -- "$transition_dir" || die "cannot create claim clear recovery path $transition_dir"
  if ! mv -- "$CLAIM_DIR" "$transition_dir/claim"; then
    rmdir -- "$transition_dir" || die "cannot clear claim clear recovery path $transition_dir"
    [ -e "$CLAIM_DIR" ] || return 0
    die "claim changed during clear; refusing to remove the current claim"
  fi
  if ! claim_metadata_matches "$transition_dir/claim" \
    "$expected_epoch" "$expected_date" "$expected_task" \
    "$expected_started" "$expected_started_epoch" "$expected_started_date"; then
    if [ ! -e "$CLAIM_DIR" ] && [ ! -L "$CLAIM_DIR" ]; then
      mv -n -- "$transition_dir/claim" "$CLAIM_DIR" || true
      if [ ! -e "$transition_dir/claim" ] && [ ! -L "$transition_dir/claim" ]; then
        rmdir -- "$transition_dir" || die "cannot clear claim clear recovery path $transition_dir"
        die "claim changed during clear; restored the current claim"
      fi
    fi
    die "claim changed during clear; preserved unverified claim at $transition_dir"
  fi
  clear_claim_dir "$transition_dir/claim"
  rmdir -- "$transition_dir" || die "cannot clear claim clear recovery path $transition_dir"
}

create_claim() {
  local now=$1 claim_date=$2 task=$3
  validate_paths
  mkdir -p "$SCOUT_DIR" || die "cannot create $SCOUT_DIR"
  validate_paths
  if mkdir -- "$CLAIM_DIR"; then
    write_claim_metadata "$CLAIM_DIR" "$now" "$claim_date" "$task"
    return 0
  fi
  return 1
}

retake_stale_claim() {
  local now=$1 claim_date=$2 task=$3
  validate_paths
  read_claim
  [ "$CLAIM_PRESENT" = true ] || return 1
  [ "$CLAIM_STATE" = ready ] || [ "$CLAIM_STATE" = pending ] || return 1
  claim_is_stale "$now" || return 1
  local old_state=$CLAIM_STATE old_epoch=$CLAIM_EPOCH old_date=$CLAIM_DATE old_task=$CLAIM_TASK
  local old_started=$CLAIM_STARTED old_started_epoch=$CLAIM_STARTED_EPOCH old_started_date=$CLAIM_STARTED_DATE
  local old_mtime=''
  if [ "$old_state" = pending ]; then
    if ! old_mtime=$(mtime_epoch "$CLAIM_DIR"); then
      die "cannot read claim directory mtime: $CLAIM_DIR"
    fi
  fi
  local stale_dir="$SCOUT_DIR/.claim-stale.$$.$RANDOM"
  [ ! -e "$stale_dir" ] || die "stale claim recovery path already exists: $stale_dir"
  [ ! -L "$stale_dir" ] || die "refusing symlinked stale claim recovery path $stale_dir"

  if ! mv -- "$CLAIM_DIR" "$stale_dir"; then
    validate_paths
    read_claim
    [ "$CLAIM_PRESENT" = true ] || return 1
    if [ "$CLAIM_STATE" = pending ] && ! claim_is_stale "$now"; then
      die "a capability scout claim is already being created"
    fi
    claim_is_stale "$now" || return 1
    return 1
  fi

  read_claim_from_dir "$stale_dir" true
  local moved_mtime=''
  if [ "$old_state" = ready ]; then
    [ "$CLAIM_STATE" = ready ] || moved_mtime=mismatch
    [ "$CLAIM_EPOCH" = "$old_epoch" ] || moved_mtime=mismatch
    [ "$CLAIM_DATE" = "$old_date" ] || moved_mtime=mismatch
    [ "$CLAIM_TASK" = "$old_task" ] || moved_mtime=mismatch
    [ "$CLAIM_STARTED" = "$old_started" ] || moved_mtime=mismatch
    [ "$CLAIM_STARTED_EPOCH" = "$old_started_epoch" ] || moved_mtime=mismatch
    [ "$CLAIM_STARTED_DATE" = "$old_started_date" ] || moved_mtime=mismatch
  else
    if [ "$CLAIM_STATE" != pending ] || ! moved_mtime=$(mtime_epoch "$stale_dir") || [ "$moved_mtime" != "$old_mtime" ]; then
      moved_mtime=mismatch
    fi
  fi
  if [ "$moved_mtime" = mismatch ]; then
    if [ ! -e "$CLAIM_DIR" ]; then
      mv -- "$stale_dir" "$CLAIM_DIR" || die "cannot restore claim after concurrent change"
    else
      die "claim changed during stale recovery; preserved the newer claim"
    fi
    return 1
  fi

  if mkdir -- "$CLAIM_DIR"; then
    write_claim_metadata "$CLAIM_DIR" "$now" "$claim_date" "$task"
    clear_claim_dir "$stale_dir"
    return 0
  fi

  validate_paths
  read_claim
  if [ "$CLAIM_PRESENT" = true ]; then
    if [ "$CLAIM_STATE" = pending ]; then
      if ! claim_is_stale "$now"; then
        clear_claim_dir "$stale_dir"
        die "a capability scout claim is already being created"
      fi
    elif ! claim_is_stale "$now"; then
      clear_claim_dir "$stale_dir"
      die "a fresh capability scout claim already exists for task $CLAIM_TASK"
    fi
  fi
  clear_claim_dir "$stale_dir"
  return 1
}

report_claim_success() {
  local now=$1 now_date=$2 task=$3 suffix=$4
  read_anchor
  read_claim
  if [ "$CLAIM_STATE" != ready ] || [ "$CLAIM_EPOCH" != "$now" ] || \
    [ "$CLAIM_DATE" != "$now_date" ] || [ "$CLAIM_TASK" != "$task" ] || \
    [ "$CLAIM_STARTED" != false ]; then
    die "capability scout claim changed during due revalidation"
  fi
  if ! cadence_is_due "$now_date"; then
    clear_current_claim_if_matches "$now" "$now_date" "$task" \
      "$CLAIM_STARTED" "$CLAIM_STARTED_EPOCH" "$CLAIM_STARTED_DATE"
    die "capability scout dispatch is no longer due in the current UTC month"
  fi
  printf 'claimed capability scout dispatch: %s task=%s%s\n' "$now_date" "$task" "$suffix"
}

cmd_due() {
  local now=$1 due now_date next_due
  read_anchor
  read_claim
  if ! now_date=$(epoch_to_date "$now" 2>/dev/null); then
    die "current epoch is not a valid UTC date"
  fi
  if [ "$CLAIM_STATE" = ready ] && [ "$CLAIM_STARTED" = true ]; then
    if [ "$(utc_month "$CLAIM_STARTED_DATE")" = "$(utc_month "$now_date")" ]; then
      due=false
    elif cadence_is_due "$now_date"; then
      due=true
    else
      due=false
    fi
  elif [ "$CLAIM_STATE" = ready ] || [ "$CLAIM_STATE" = pending ]; then
    if claim_is_stale "$now"; then
      if cadence_is_due "$now_date"; then
        due=true
      else
        due=false
      fi
    else
      due=false
    fi
  elif cadence_is_due "$now_date"; then
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
  print_claim_state "$now"
  [ "$due" = true ]
}

cmd_claim() {
  local now=$1 task=$2 now_date
  validate_task "$task" "--task"
  if ! now_date=$(epoch_to_date "$now" 2>/dev/null); then
    die "current epoch is not a valid UTC date"
  fi
  read_anchor
  read_claim
  if [ "$CLAIM_STATE" = ready ] && [ "$CLAIM_STARTED" = true ]; then
    local previous_epoch=$CLAIM_EPOCH previous_date=$CLAIM_DATE previous_task=$CLAIM_TASK
    local started_epoch=$CLAIM_STARTED_EPOCH started_date=$CLAIM_STARTED_DATE
    if [[ "$now_date" < "$started_date" ]]; then
      die "dispatch start date is after the current UTC date"
    fi
    if [ "$(utc_month "$started_date")" = "$(utc_month "$now_date")" ]; then
      die "dispatch already started for the current UTC month"
    fi
    if [ -z "$LAST_EPOCH" ] || [ "$LAST_EPOCH" -lt "$started_epoch" ]; then
      write_anchor "$started_epoch" "$started_date" "$previous_task"
    fi
    clear_current_claim_if_matches "$previous_epoch" "$previous_date" "$previous_task" \
      true "$started_epoch" "$started_date"
    read_anchor
    read_claim
  fi
  if ! cadence_is_due "$now_date"; then
    die "capability scout dispatch is not due in the current UTC month"
  fi
  if [ "$CLAIM_STATE" = pending ] || [ "$CLAIM_STATE" = ready ]; then
    if ! claim_is_stale "$now"; then
      if [ "$CLAIM_STATE" = pending ]; then
        die "a capability scout claim is already being created"
      fi
      die "a fresh capability scout claim already exists for task $CLAIM_TASK"
    fi
    if retake_stale_claim "$now" "$now_date" "$task"; then
      report_claim_success "$now" "$now_date" "$task" ' (stale claim retaken)'
      return 0
    fi
    read_anchor
    read_claim
    if ! cadence_is_due "$now_date"; then
      die "capability scout dispatch is not due in the current UTC month"
    fi
  fi
  if create_claim "$now" "$now_date" "$task"; then
    report_claim_success "$now" "$now_date" "$task" ''
    return 0
  fi
  read_anchor
  read_claim
  if ! cadence_is_due "$now_date"; then
    die "capability scout dispatch is not due in the current UTC month"
  fi
  if [ "$CLAIM_STATE" = pending ] || [ "$CLAIM_STATE" = ready ]; then
    if claim_is_stale "$now"; then
      if retake_stale_claim "$now" "$now_date" "$task"; then
        report_claim_success "$now" "$now_date" "$task" ' (stale claim retaken)'
        return 0
      fi
    elif [ "$CLAIM_STATE" = pending ]; then
      die "a capability scout claim is already being created"
    else
      die "a fresh capability scout claim already exists for task $CLAIM_TASK"
    fi
  fi
  if create_claim "$now" "$now_date" "$task"; then
    report_claim_success "$now" "$now_date" "$task" ''
    return 0
  fi
  die "capability scout claim changed during reservation"
}

write_anchor() {
  local now=$1 mark_date=$2 task=$3 tmp
  mkdir -p "$SCOUT_DIR" || die "cannot create $SCOUT_DIR"
  validate_paths
  tmp=$(mktemp "$SCOUT_DIR/.last-sweep.XXXXXX") || die "cannot create a temporary anchor in $SCOUT_DIR"
  chmod 600 "$tmp"
  {
    printf 'last_epoch=%s\n' "$now"
    printf 'last_date=%s\n' "$mark_date"
    printf 'task=%s\n' "$task"
  } > "$tmp"
  mv -f -- "$tmp" "$ANCHOR" || die "cannot write $ANCHOR"
}

cmd_mark() {
  local now=$1 task=$2 mark_date
  validate_task "$task" "--task"
  if ! mark_date=$(epoch_to_date "$now" 2>/dev/null); then
    die "mark epoch is not a valid epoch"
  fi
  read_anchor
  read_claim
  [ "$CLAIM_STATE" != pending ] || die "claim metadata is incomplete: $CLAIM_META"
  local claim_present=$CLAIM_PRESENT claim_epoch=$CLAIM_EPOCH claim_date=$CLAIM_DATE claim_task=$CLAIM_TASK
  local claim_started=$CLAIM_STARTED claim_started_epoch=$CLAIM_STARTED_EPOCH claim_started_date=$CLAIM_STARTED_DATE
  if [ "$claim_present" = false ]; then
    if create_claim "$now" "$mark_date" "$task"; then
      claim_present=true
      claim_epoch=$now
      claim_date=$mark_date
      claim_task=$task
      claim_started=false
      claim_started_epoch=''
      claim_started_date=''
      read_anchor
      read_claim
      [ "$CLAIM_STATE" = ready ] || die "claim changed during mark reservation"
      [ "$CLAIM_EPOCH" = "$claim_epoch" ] || die "claim changed during mark reservation"
      [ "$CLAIM_DATE" = "$claim_date" ] || die "claim changed during mark reservation"
      [ "$CLAIM_TASK" = "$claim_task" ] || die "claim changed during mark reservation"
    else
      read_anchor
      read_claim
      [ "$CLAIM_STATE" != pending ] || die "claim metadata is incomplete: $CLAIM_META"
      if [ "$CLAIM_PRESENT" = false ]; then
        if ! create_claim "$now" "$mark_date" "$task"; then
          die "capability scout claim changed during mark reservation"
        fi
      fi
      [ "$CLAIM_STATE" = ready ] || read_claim
      [ "$CLAIM_STATE" = ready ] || die "claim metadata is incomplete: $CLAIM_META"
      claim_present=true
      claim_epoch=$CLAIM_EPOCH
      claim_date=$CLAIM_DATE
      claim_task=$CLAIM_TASK
      claim_started=$CLAIM_STARTED
      claim_started_epoch=$CLAIM_STARTED_EPOCH
      claim_started_date=$CLAIM_STARTED_DATE
    fi
  fi
  if [ "$task" != "$claim_task" ]; then
    die "claim belongs to task $claim_task, not $task"
  fi
  write_anchor "$now" "$mark_date" "$task"
  clear_current_claim_if_matches "$claim_epoch" "$claim_date" "$claim_task" \
    "$claim_started" "$claim_started_epoch" "$claim_started_date"
  printf 'marked capability scout sweep: %s\n' "$mark_date"
}

cmd_release() {
  local task=$1
  if [ -n "$task" ]; then
    case "$task" in
      *[!A-Za-z0-9._-]*) die "--task must be a plain task id (letters, digits, dot, dash, underscore)" ;;
    esac
  fi
  validate_paths
  if [ ! -e "$CLAIM_DIR" ]; then
    return 0
  fi
  read_claim
  if [ "$CLAIM_PRESENT" = false ]; then
    return 0
  fi
  [ "$CLAIM_STATE" != pending ] || die "claim metadata is incomplete: $CLAIM_META"
  [ -n "$task" ] || die "--task is required when a capability scout claim exists"
  if [ "$task" != "$CLAIM_TASK" ]; then
    die "claim belongs to task $CLAIM_TASK, not $task"
  fi
  [ "$CLAIM_STARTED" = false ] \
    || die "cannot release a claim after dispatch has started; mark it instead"
  clear_current_claim_if_matches "$CLAIM_EPOCH" "$CLAIM_DATE" "$CLAIM_TASK" \
    "$CLAIM_STARTED" "$CLAIM_STARTED_EPOCH" "$CLAIM_STARTED_DATE"
  printf 'released capability scout claim: task=%s\n' "$CLAIM_TASK"
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
  claim)
    cmd_claim "$NOW" "$TASK"
    ;;
  start)
    cmd_start "$NOW" "$TASK"
    ;;
  mark)
    cmd_mark "$NOW" "$TASK"
    ;;
  release)
    cmd_release "$TASK"
    ;;
  *)
    printf 'capability-scout: unknown command: %s\n' "$CMD" >&2
    usage >&2
    exit 2
    ;;
esac

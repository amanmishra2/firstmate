#!/usr/bin/env bash
# fm-agy-consult.sh - bounded tmux consultation helper for Antigravity CLI (agy).
#
# Starts or reuses a named tmux session in a target directory, applies the
# consultation permission policy, sends one single-line-normalized prompt,
# waits for the answer to settle back to the idle composer, captures the pane,
# deduplicates TUI redraw and spinner noise, and writes the result to
# <data>/agy-reviews/<YYYY-MM-DD>-<topic>.txt.
#
# Usage:
#   fm-agy-consult.sh --topic <slug> [options] [<prompt>]
#
# Options:
#   -t, --topic <slug>              Required topic slug for the dated review log
#                                   (<data>/agy-reviews/<YYYY-MM-DD>-<topic>.txt).
#                                   A leading <YYYY-MM-DD>- or trailing .txt is
#                                   stripped automatically.
#   -p, --prompt <text>             Prompt text to send (mutually exclusive with
#                                   --prompt-file and positional <prompt>).
#   -f, --prompt-file <path>        Read prompt text from <path> ('-' reads stdin).
#   -C, -c, --dir <dir>             Target directory when creating the tmux session
#                                   (default: current working directory).
#   -s, --session <name>            Named tmux session to start or reuse
#                                   (default: agy).
#   --fresh, --restart              Kill any existing <session> first and launch a
#                                   clean agy session. Use when switching --model
#                                   or --dir on an existing session name.
#   -m, --model <id>                Pass --model <id> to agy when launching a
#                                   session. Verified model IDs:
#                                     gemini-3.8-flash-high
#                                     gemini-3.8-flash-medium
#                                     gemini-3.8-flash-low
#                                     gemini-4-argon-high
#                                     gemini-4-argon-medium
#                                     gemini-4-argon-low
#   --effort <level>                Pass --effort <low|medium|high> to agy when
#                                   launching a session.
#   --policy, --permission-policy <mode>
#                                   Permission policy for the consultation:
#                                     read-only     (default) Prepend an explicit
#                                                   read-only instruction to the
#                                                   prompt and launch without
#                                                   --dangerously-skip-permissions.
#                                     prompt-as-is  Send the prompt without adding
#                                                   the read-only prefix; still
#                                                   launches without
#                                                   --dangerously-skip-permissions.
#   -n, --lines <count>             Scrollback line count for tmux capture-pane
#                                   -S -<count> (default: 500, or
#                                   FM_AGY_CONSULT_LINES).
#   --timeout <seconds>             Maximum wait for the answer to settle
#                                   (default: 300, or FM_AGY_CONSULT_TIMEOUT).
#   --poll-interval <seconds>       Seconds between pane captures while waiting
#                                   (default: 2, or FM_AGY_CONSULT_POLL_INTERVAL).
#   --settle-polls <count>          Consecutive identical idle captures required
#                                   when no busy footer was observed (default: 2,
#                                   or FM_AGY_CONSULT_SETTLE_POLLS).
#   --date <YYYY-MM-DD>             Date prefix override for the output filename
#                                   (default: today, or FM_AGY_CONSULT_DATE).
#   --output-dir <dir>              Output directory override (default:
#                                   ${FM_DATA_OVERRIDE:-$FM_HOME/data}/agy-reviews).
#   -q, --quiet                     Print only the written log path on stdout.
#   -h, --help                      Print this usage and mechanics reference.
#
# Mechanics and permission caveats:
#   1. Session launch and reuse:
#      When <session> does not exist (or after --fresh kills it), the helper runs:
#        tmux new-session -d -s <session> -c <dir> 'agy [--model <id>] [--effort <level>]'
#      When <session> already exists without --fresh, the helper reuses it after
#      verifying the pane is not already mid-turn ('esc to cancel'). Because
#      in-session model switching in tmux and cross-session model binding are
#      unverified, pass --fresh when changing --model or --dir.
#   2. Single-line prompt delivery:
#      Newlines, carriage returns, and tabs are collapsed to single spaces before
#      calling `tmux send-keys -t <session> -l <prompt>` followed by
#      `tmux send-keys -t <session> Enter`, preventing multi-line paste splits in
#      agy's composer.
#   3. Folder-trust caveat:
#      On first launch in an unseen directory, agy presents "Do you trust the
#      contents of this project?" with "Yes, I trust this folder" preselected.
#      This helper sends one Enter to accept that initial folder-trust dialog so
#      the consultation runs in <dir> rather than agy's scratch directory.
#      Accepting folder trust records <dir> in
#      ~/.gemini/antigravity-cli/settings.json (trustedWorkspaces) and grants agy
#      workspace permission to read, edit, and execute files in that folder -
#      folder trust is NOT a read-only sandbox.
#   4. Per-command approval caveat:
#      This helper is a firstmate-side consultation tool, not an autonomous
#      worker spawn: it never passes --dangerously-skip-permissions and never
#      auto-approves tool or shell-command permission prompts beyond the initial
#      folder-trust Enter. Inside a trusted workspace, agy's file-reading and
#      search tools run without modal prompts, whereas shell commands or file
#      mutations trigger interactive per-command approval dialogs in the TUI.
#      The default `read-only` policy instructs agy not to modify files or run
#      state-changing commands so research consults do not wedge on approval
#      dialogs. If a turn still parks on a per-command approval prompt instead of
#      returning to the idle `? for shortcuts` footer, the helper does not answer
#      it and fails closed when the wait budget expires.
#   5. Settle detection and deduplication:
#      During a turn, agy pins `esc to cancel` in the status row and replaces it
#      with `? for shortcuts` when the turn completes. The helper polls
#      `tmux capture-pane -p -t <session> -S -<lines>` until `esc to cancel`
#      clears to `? for shortcuts` (or until --settle-polls consecutive identical
#      idle captures appear after the prompt lands), strips transient braille
#      spinner lines, deduplicates redraw noise with `awk '!seen[$0]++'`, and
#      writes the output atomically to <output-dir>/<date>-<topic>.txt.
set -u
unset CDPATH

SCRIPT_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd -P -- "$SCRIPT_DIR/.." && pwd -P)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA_DIR="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

die_usage() {
  printf 'error: %s\n' "$*" >&2
  exit 2
}

is_verified_model() {
  case "$1" in
    gemini-3.8-flash-high | gemini-3.8-flash-medium | gemini-3.8-flash-low | \
    gemini-4-argon-high | gemini-4-argon-medium | gemini-4-argon-low)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_positive_int() {
  case "${1:-}" in
    '' | *[!0-9]* | 0*) return 1 ;;
    *) return 0 ;;
  esac
}

normalize_single_line() {
  printf '%s' "$1" | tr '\r\n\t' '   ' | awk '
    {
      gsub(/[[:space:]]+/, " ")
      line = (line == "" ? $0 : line " " $0)
    }
    END {
      sub(/^ /, "", line)
      sub(/ $/, "", line)
      printf "%s", line
    }
  '
}

pane_tail_lines() {
  printf '%s\n' "$1" | awk 'NF { lines[++n] = $0 } END { start = (n > 15 ? n - 14 : 1); for (i = start; i <= n; i++) print lines[i] }'
}

pane_shows_trust_dialog() {
  printf '%s\n' "$1" | grep -Fq 'Do you trust the contents of this project?'
}

pane_is_busy() {
  pane_tail_lines "$1" | grep -Fq 'esc to cancel'
}

pane_is_idle() {
  if pane_is_busy "$1"; then
    return 1
  fi
  pane_tail_lines "$1" | grep -Fq '? for shortcuts'
}

pane_has_empty_composer() {
  pane_tail_lines "$1" | grep -Eq '^[[:space:]]*>[[:space:]]*$'
}

pane_conflicts_with_model() {  # <pane> <requested-model>
  local pane=$1 req=$2
  case "$req" in
    gemini-3.8-flash-*)
      printf '%s\n' "$pane" | grep -Fq 'Gemini 4 Argon' && return 0
      ;;
    gemini-4-argon-*)
      printf '%s\n' "$pane" | grep -Fq 'Gemini 3.8 Flash' && return 0
      ;;
  esac
  return 1
}

pane_shows_command_approval() {
  pane_tail_lines "$1" | grep -Eq 'Allow .* to (run|execute|edit|write|modify)|Do you want to (run|execute|allow|approve)|requires permission to (run|execute|edit|write)'
}

send_literal_prompt() {  # <session> <prompt>
  case "$2" in
    -*) tmux send-keys -t "$1" -l -- "$2" ;;
    *) tmux send-keys -t "$1" -l "$2" ;;
  esac
}

dedupe_capture() {
  printf '%s\n' "$1" | awk '
    {
      sub(/\r$/, "")
    }
    /^[[:space:]]*(⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏|⣾|⣽|⣻|⢿|⡿|⣟|⣯|⣷)([[:space:]]|$)/ {
      next
    }
    !seen[$0]++
  '
}

TOPIC=""
PROMPT_TEXT=""
PROMPT_SOURCE=""
PROMPT_FILE=""
TARGET_DIR="$PWD"
SESSION="agy"
FRESH=0
MODEL=""
EFFORT=""
POLICY="read-only"
LINES="${FM_AGY_CONSULT_LINES:-500}"
TIMEOUT="${FM_AGY_CONSULT_TIMEOUT:-300}"
POLL_INTERVAL="${FM_AGY_CONSULT_POLL_INTERVAL:-2}"
SETTLE_POLLS="${FM_AGY_CONSULT_SETTLE_POLLS:-2}"
DATE_STR="${FM_AGY_CONSULT_DATE:-}"
OUTPUT_DIR="${FM_AGY_REVIEWS_DIR:-$DATA_DIR/agy-reviews}"
QUIET=0
POSITIONAL_PROMPT=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    -t | --topic)
      [ "$#" -ge 2 ] || die_usage "$1 requires a topic slug"
      TOPIC=$2
      shift 2
      ;;
    --topic=*)
      TOPIC=${1#--topic=}
      shift
      ;;
    -p | --prompt)
      [ "$#" -ge 2 ] || die_usage "$1 requires prompt text"
      [ -z "$PROMPT_SOURCE" ] || die_usage "specify only one of --prompt, --prompt-file, or positional prompt"
      PROMPT_SOURCE="flag"
      PROMPT_TEXT=$2
      shift 2
      ;;
    --prompt=*)
      [ -z "$PROMPT_SOURCE" ] || die_usage "specify only one of --prompt, --prompt-file, or positional prompt"
      PROMPT_SOURCE="flag"
      PROMPT_TEXT=${1#--prompt=}
      shift
      ;;
    -f | --prompt-file)
      [ "$#" -ge 2 ] || die_usage "$1 requires a file path"
      [ -z "$PROMPT_SOURCE" ] || die_usage "specify only one of --prompt, --prompt-file, or positional prompt"
      PROMPT_SOURCE="file"
      PROMPT_FILE=$2
      shift 2
      ;;
    --prompt-file=*)
      [ -z "$PROMPT_SOURCE" ] || die_usage "specify only one of --prompt, --prompt-file, or positional prompt"
      PROMPT_SOURCE="file"
      PROMPT_FILE=${1#--prompt-file=}
      shift
      ;;
    -C | -c | --dir)
      [ "$#" -ge 2 ] || die_usage "$1 requires a directory path"
      TARGET_DIR=$2
      shift 2
      ;;
    --dir=*)
      TARGET_DIR=${1#--dir=}
      shift
      ;;
    -s | --session)
      [ "$#" -ge 2 ] || die_usage "$1 requires a tmux session name"
      SESSION=$2
      shift 2
      ;;
    --session=*)
      SESSION=${1#--session=}
      shift
      ;;
    --fresh | --restart)
      FRESH=1
      shift
      ;;
    -m | --model)
      [ "$#" -ge 2 ] || die_usage "$1 requires a model id"
      MODEL=$2
      shift 2
      ;;
    --model=*)
      MODEL=${1#--model=}
      shift
      ;;
    --effort)
      [ "$#" -ge 2 ] || die_usage "--effort requires low, medium, or high"
      EFFORT=$2
      shift 2
      ;;
    --effort=*)
      EFFORT=${1#--effort=}
      shift
      ;;
    --policy | --permission-policy)
      [ "$#" -ge 2 ] || die_usage "$1 requires read-only or prompt-as-is"
      POLICY=$2
      shift 2
      ;;
    --policy=* | --permission-policy=*)
      POLICY=${1#*=}
      shift
      ;;
    -n | --lines)
      [ "$#" -ge 2 ] || die_usage "$1 requires a positive line count"
      LINES=$2
      shift 2
      ;;
    --lines=*)
      LINES=${1#--lines=}
      shift
      ;;
    --timeout)
      [ "$#" -ge 2 ] || die_usage "--timeout requires a positive integer (seconds)"
      TIMEOUT=$2
      shift 2
      ;;
    --timeout=*)
      TIMEOUT=${1#--timeout=}
      shift
      ;;
    --poll-interval)
      [ "$#" -ge 2 ] || die_usage "--poll-interval requires a positive integer (seconds)"
      POLL_INTERVAL=$2
      shift 2
      ;;
    --poll-interval=*)
      POLL_INTERVAL=${1#--poll-interval=}
      shift
      ;;
    --settle-polls)
      [ "$#" -ge 2 ] || die_usage "--settle-polls requires a positive integer"
      SETTLE_POLLS=$2
      shift 2
      ;;
    --settle-polls=*)
      SETTLE_POLLS=${1#--settle-polls=}
      shift
      ;;
    --date)
      [ "$#" -ge 2 ] || die_usage "--date requires YYYY-MM-DD"
      DATE_STR=$2
      shift 2
      ;;
    --date=*)
      DATE_STR=${1#--date=}
      shift
      ;;
    --output-dir)
      [ "$#" -ge 2 ] || die_usage "--output-dir requires a directory path"
      OUTPUT_DIR=$2
      shift 2
      ;;
    --output-dir=*)
      OUTPUT_DIR=${1#--output-dir=}
      shift
      ;;
    -q | --quiet)
      QUIET=1
      shift
      ;;
    --)
      shift
      while [ "$#" -gt 0 ]; do
        POSITIONAL_PROMPT+=("$1")
        shift
      done
      ;;
    -*)
      die_usage "unknown option: $1 (see --help)"
      ;;
    *)
      POSITIONAL_PROMPT+=("$1")
      shift
      ;;
  esac
done

if [ "${#POSITIONAL_PROMPT[@]}" -gt 0 ]; then
  [ -z "$PROMPT_SOURCE" ] || die_usage "specify only one of --prompt, --prompt-file, or positional prompt"
  PROMPT_SOURCE="positional"
  PROMPT_TEXT="${POSITIONAL_PROMPT[*]}"
fi

[ -n "$DATE_STR" ] || DATE_STR=$(date +%Y-%m-%d)
case "$DATE_STR" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
  *) die_usage "invalid --date '$DATE_STR'; expected YYYY-MM-DD" ;;
esac

[ -n "$TOPIC" ] || die_usage "--topic <slug> is required"
TOPIC=${TOPIC%.txt}
case "$TOPIC" in
  "$DATE_STR"-*) TOPIC=${TOPIC#"$DATE_STR"-} ;;
esac
case "$TOPIC" in
  '' | .* | -* | *..* | */* | *[!A-Za-z0-9._-]*)
    die_usage "invalid --topic '$TOPIC'; use a safe filename slug matching [A-Za-z0-9][A-Za-z0-9._-]*"
    ;;
esac

case "$SESSION" in
  '' | -* | *[!A-Za-z0-9_.-]*)
    die_usage "invalid --session '$SESSION'; use [A-Za-z0-9_.-]+"
    ;;
esac

if [ -n "$MODEL" ]; then
  if ! is_verified_model "$MODEL"; then
    die "unverified agy model '$MODEL'; verified model IDs are gemini-3.8-flash-high, gemini-3.8-flash-medium, gemini-3.8-flash-low, gemini-4-argon-high, gemini-4-argon-medium, gemini-4-argon-low"
  fi
fi

if [ -n "$EFFORT" ]; then
  case "$EFFORT" in
    low | medium | high) ;;
    *) die "unsupported agy --effort '$EFFORT'; verified levels are low, medium, high" ;;
  esac
fi

case "$POLICY" in
  read-only | prompt-as-is | none) ;;
  *)
    die "unsupported permission policy '$POLICY'; supported policies are 'read-only' (default) and 'prompt-as-is' (no auto-approval beyond initial folder trust)"
    ;;
esac

is_positive_int "$LINES" || die_usage "--lines must be a positive integer (got '$LINES')"
is_positive_int "$TIMEOUT" || die_usage "--timeout must be a positive integer in seconds (got '$TIMEOUT')"
is_positive_int "$POLL_INTERVAL" || die_usage "--poll-interval must be a positive integer in seconds (got '$POLL_INTERVAL')"
is_positive_int "$SETTLE_POLLS" || die_usage "--settle-polls must be a positive integer (got '$SETTLE_POLLS')"

[ -n "$PROMPT_SOURCE" ] || die_usage "a prompt is required via --prompt, --prompt-file, or a positional argument"
if [ "$PROMPT_SOURCE" = "file" ]; then
  if [ "$PROMPT_FILE" = "-" ]; then
    PROMPT_TEXT=$(cat)
  else
    [ -f "$PROMPT_FILE" ] && [ -r "$PROMPT_FILE" ] || die "prompt file '$PROMPT_FILE' is not a readable regular file"
    PROMPT_TEXT=$(cat -- "$PROMPT_FILE")
  fi
fi

SINGLE_LINE_RAW=$(normalize_single_line "$PROMPT_TEXT")
[ -n "$SINGLE_LINE_RAW" ] || die_usage "prompt text must not be empty"

if [ "$POLICY" = "read-only" ]; then
  case "$SINGLE_LINE_RAW" in
    [Rr]ead-only\ consultation*)
      FINAL_PROMPT="$SINGLE_LINE_RAW"
      ;;
    *)
      FINAL_PROMPT="Read-only consultation (do not modify, create, or delete any file, and do not run state-changing commands): $SINGLE_LINE_RAW"
      ;;
  esac
else
  FINAL_PROMPT="$SINGLE_LINE_RAW"
fi

TARGET_DIR_REAL=$(cd -P -- "$TARGET_DIR" 2>/dev/null && pwd -P) || true
[ -n "$TARGET_DIR_REAL" ] || die "target directory '$TARGET_DIR' is not an accessible directory"

command -v tmux >/dev/null 2>&1 || die "tmux executable not found on PATH"
command -v agy >/dev/null 2>&1 || die "agy executable not found on PATH"

mkdir -p -- "$OUTPUT_DIR" || die "could not create output directory '$OUTPUT_DIR'"
OUTPUT_DIR_REAL=$(cd -P -- "$OUTPUT_DIR" 2>/dev/null && pwd -P) || die "output directory '$OUTPUT_DIR' is not accessible"
OUT_FILE="$OUTPUT_DIR_REAL/${DATE_STR}-${TOPIC}.txt"

if [ "$FRESH" -eq 1 ]; then
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux kill-session -t "$SESSION" >/dev/null 2>&1 || die "could not kill existing tmux session '$SESSION'"
  fi
fi

TRUST_ANSWERED=0
SESSION_REUSED=1
if ! tmux has-session -t "$SESSION" 2>/dev/null; then
  SESSION_REUSED=0
  AGY_LAUNCH_CMD="agy"
  if [ -n "$MODEL" ]; then
    AGY_LAUNCH_CMD="$AGY_LAUNCH_CMD --model $MODEL"
  fi
  if [ -n "$EFFORT" ]; then
    AGY_LAUNCH_CMD="$AGY_LAUNCH_CMD --effort $EFFORT"
  fi
  tmux new-session -d -s "$SESSION" -c "$TARGET_DIR_REAL" "$AGY_LAUNCH_CMD" \
    || die "failed to start tmux session '$SESSION' in '$TARGET_DIR_REAL'"
fi

PRE_CAPTURE=$(tmux capture-pane -p -t "$SESSION" -S -"$LINES" 2>/dev/null) \
  || die "failed to capture tmux session '$SESSION'"

if pane_shows_trust_dialog "$PRE_CAPTURE"; then
  tmux send-keys -t "$SESSION" Enter || die "failed to accept folder-trust dialog in tmux session '$SESSION'"
  TRUST_ANSWERED=1
  sleep "$POLL_INTERVAL"
  PRE_CAPTURE=$(tmux capture-pane -p -t "$SESSION" -S -"$LINES" 2>/dev/null) \
    || die "failed to capture tmux session '$SESSION' after folder-trust Enter"
fi

if pane_is_busy "$PRE_CAPTURE"; then
  die "tmux session '$SESSION' is already busy (esc to cancel); wait for the active turn to finish or pass --fresh"
fi

if [ "$SESSION_REUSED" -eq 1 ] && [ -n "$MODEL" ] && pane_conflicts_with_model "$PRE_CAPTURE" "$MODEL"; then
  die "existing tmux session '$SESSION' is running a different model than requested '$MODEL'; pass --fresh to restart the session"
fi

send_literal_prompt "$SESSION" "$FINAL_PROMPT" \
  || die "failed to send prompt text to tmux session '$SESSION'"
tmux send-keys -t "$SESSION" Enter \
  || die "failed to send Enter to tmux session '$SESSION'"

MAX_POLLS=$(( TIMEOUT / POLL_INTERVAL ))
[ "$MAX_POLLS" -ge 1 ] || MAX_POLLS=1
START_EPOCH=$(date +%s)
POLL_COUNT=0
SAW_BUSY=0
IDLE_STABLE=0
PREV_IDLE_PANE=""
SETTLED_PANE=""
LAST_PANE="$PRE_CAPTURE"

while [ "$POLL_COUNT" -lt "$MAX_POLLS" ]; do
  sleep "$POLL_INTERVAL"
  POLL_COUNT=$(( POLL_COUNT + 1 ))

  PANE=$(tmux capture-pane -p -t "$SESSION" -S -"$LINES" 2>/dev/null) \
    || die "lost tmux session '$SESSION' while waiting for consultation reply"
  LAST_PANE="$PANE"

  if [ "$TRUST_ANSWERED" -eq 0 ] && pane_shows_trust_dialog "$PANE"; then
    tmux send-keys -t "$SESSION" Enter || die "failed to accept folder-trust dialog in tmux session '$SESSION'"
    TRUST_ANSWERED=1
    IDLE_STABLE=0
    PREV_IDLE_PANE=""
    continue
  fi

  if pane_is_busy "$PANE"; then
    SAW_BUSY=1
    IDLE_STABLE=0
    PREV_IDLE_PANE=""
  elif pane_is_idle "$PANE"; then
    if [ "$SAW_BUSY" -eq 1 ]; then
      SETTLED_PANE="$PANE"
      break
    fi
    if [ "$PANE" != "$PRE_CAPTURE" ] && pane_has_empty_composer "$PANE"; then
      if [ "$PANE" = "$PREV_IDLE_PANE" ]; then
        IDLE_STABLE=$(( IDLE_STABLE + 1 ))
      else
        IDLE_STABLE=1
        PREV_IDLE_PANE="$PANE"
      fi
      if [ "$IDLE_STABLE" -ge "$SETTLE_POLLS" ]; then
        SETTLED_PANE="$PANE"
        break
      fi
    fi
  else
    IDLE_STABLE=0
    PREV_IDLE_PANE=""
  fi

  NOW_EPOCH=$(date +%s)
  if [ $(( NOW_EPOCH - START_EPOCH )) -ge "$TIMEOUT" ]; then
    break
  fi
done

if [ -z "$SETTLED_PANE" ]; then
  if pane_shows_command_approval "$LAST_PANE"; then
    die "agy consultation in session '$SESSION' parked on a per-command approval prompt (helper never auto-approves command or edit permissions; inspect tmux session '$SESSION')"
  fi
  die "agy consultation in session '$SESSION' did not settle within ${TIMEOUT}s (inspect tmux session '$SESSION')"
fi

DEDUPED=$(dedupe_capture "$SETTLED_PANE")
TMP_OUT="$OUTPUT_DIR_REAL/.${DATE_STR}-${TOPIC}.txt.tmp.$$"
if ! printf '%s\n' "$DEDUPED" > "$TMP_OUT" || ! mv -f -- "$TMP_OUT" "$OUT_FILE"; then
  rm -f -- "$TMP_OUT" 2>/dev/null || true
  die "could not write consultation log '$OUT_FILE'"
fi

if [ "$QUIET" -eq 1 ]; then
  printf '%s\n' "$OUT_FILE"
else
  printf 'saved: %s\n%s\n' "$OUT_FILE" "$DEDUPED"
fi

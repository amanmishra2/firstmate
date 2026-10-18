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
#   fm-agy-consult.sh --topic <slug> (--prompt <text> | --prompt-file <path>) [options]
#
# Options:
#   --topic <slug>                  Required topic slug for the dated review log
#                                   (<data>/agy-reviews/<YYYY-MM-DD>-<topic>.txt).
#                                   A leading <YYYY-MM-DD>- or trailing .txt is
#                                   stripped automatically.
#   --prompt <text>                 Prompt text to send (mutually exclusive with
#                                   --prompt-file).
#   --prompt-file <path>            Read prompt text from a regular file.
#   --dir <dir>                     Target directory when creating the tmux session
#                                   (default: current working directory).
#   --session <name>                Named tmux session to start or reuse
#                                   (default: agy).
#   --model <id>                    Pass --model <id> to agy when launching a
#                                   session. Verified model IDs:
#                                     gemini-3.8-flash-high
#                                     gemini-3.8-flash-medium
#                                     gemini-3.8-flash-low
#                                     gemini-4-argon-high
#                                     gemini-4-argon-medium
#                                     gemini-4-argon-low
#   --effort <level>                Pass --effort <low|medium|high> to agy when
#                                   launching a session.
#   --policy <mode>
#                                   Permission policy for the consultation:
#                                     read-only     (default) Prepend an explicit
#                                                   read-only instruction to the
#                                                   prompt and launch without
#                                                   --dangerously-skip-permissions.
#                                     prompt-as-is  Send the prompt without adding
#                                                   the read-only prefix; still
#                                                   launches without
#                                                   --dangerously-skip-permissions.
#   --lines <count>                 Scrollback line count for tmux capture-pane
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
#   --quiet                         Print only the written log path on stdout.
#   -h, --help                      Print this usage and mechanics reference.
#
# Mechanics and permission caveats:
#   1. Session launch and reuse:
#      Before launch or reuse, <dir> and the live pane directory must already be
#      listed in ${FM_AGY_SETTINGS_FILE:-$HOME/.gemini/antigravity-cli/settings.json}
#      under trustedWorkspaces. Untrusted directories are refused; pre-register a
#      linked task worktree with bin/fm-agy-trust.sh or launch agy manually once.
#      When <session> does not exist, the helper runs:
#        tmux new-session -d -s <session> -c <dir> 'agy [--model <id>] [--effort <level>]'
#      When <session> already exists, the helper reuses it after verifying its
#      pane directory is trusted, it is not already mid-turn, and its idle
#      composer is ready. It never kills or restarts an existing session.
#   2. Single-line prompt delivery:
#      Newlines, carriage returns, and tabs are collapsed to single spaces before
#      calling `tmux send-keys -t <session> -l <prompt>` followed by
#      `tmux send-keys -t <session> Enter`. On a fresh launch, it waits for the
#      ready idle composer before sending and then requires pane evidence that
#      the prompt landed before accepting any idle settle.
#   3. Folder-trust caveat:
#      This helper never answers "Do you trust the contents of this project?".
#      A dialog appearing despite the trust-store preflight is refused without
#      sending Enter. Workspace trust permits agy to read, edit, and execute
#      files in that folder; it is not a read-only sandbox.
#   4. Per-command approval caveat:
#      This helper is a firstmate-side consultation tool, not an autonomous
#      worker spawn: it never passes --dangerously-skip-permissions and never
#      auto-approves tool or shell-command permission prompts. Inside a trusted
#      workspace, agy's file-reading and search tools run without modal prompts,
#      whereas shell commands or file
#      mutations trigger interactive per-command approval dialogs in the TUI.
#      The default `read-only` policy instructs agy not to modify files or run
#      state-changing commands so research consults do not wedge on approval
#      dialogs. If a turn still parks on a per-command approval prompt instead of
#      returning to the idle `? for shortcuts` footer, the helper does not answer
#      it and fails closed when the wait budget expires.
#   5. Settle detection and output:
#      During a turn, agy pins `esc to cancel` in the status row and replaces it
#      with `? for shortcuts` when the turn completes. The helper polls
#      `tmux capture-pane -p -t <session> -S -<lines>` until `esc to cancel`
#      clears to `? for shortcuts` (or until --settle-polls consecutive identical
#      idle captures appear after the prompt lands). It keeps only the current
#      turn from its submitted prompt, strips spinner and footer chrome, preserves
#      repeated answer lines, and writes atomically to <data>/agy-reviews.
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

is_calendar_date() {
  local value=$1 year month day max_day
  case "$value" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) return 1 ;;
  esac
  year=$((10#${value:0:4}))
  month=$((10#${value:5:2}))
  day=$((10#${value:8:2}))
  (( year >= 1 && month >= 1 && month <= 12 && day >= 1 )) || return 1
  case "$month" in
    1 | 3 | 5 | 7 | 8 | 10 | 12) max_day=31 ;;
    4 | 6 | 9 | 11) max_day=30 ;;
    2)
      if (( year % 400 == 0 || (year % 4 == 0 && year % 100 != 0) )); then
        max_day=29
      else
        max_day=28
      fi
      ;;
  esac
  (( day <= max_day ))
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

pane_bottom_lines() {
  printf '%s\n' "$1" | awk 'NF { lines[++n] = $0 } END { start = (n > 8 ? n - 7 : 1); for (i = start; i <= n; i++) print lines[i] }'
}

pane_last_nonblank_line() {
  printf '%s\n' "$1" | awk 'NF { line = $0 } END { print line }'
}

pane_shows_trust_dialog() {
  if pane_is_idle "$1" || pane_is_busy "$1"; then
    return 1
  fi
  pane_bottom_lines "$1" | awk '
    /Do you trust the contents of this project\?/ { question = NR }
    question && /^[[:space:]]*(>[[:space:]]*)?Yes, I trust this folder([[:space:]]|$)/ { yes = NR }
    question && /^[[:space:]]*No, exit([[:space:]]|$)/ { no = NR }
    END {
      if (question && yes > question && no > yes && NR - question <= 5) exit 0
      exit 1
    }
  '
}

pane_is_busy() {
  pane_last_nonblank_line "$1" | grep -Eq '^[[:space:]]*esc to cancel([[:space:]]+Gemini[[:space:]]+[0-9]+(\.[0-9]+)*[[:space:]]+(Flash|Argon)[[:space:]]+·[[:space:]]+(high|medium|low))?[[:space:]]*$'
}

pane_is_idle() {
  if pane_last_nonblank_line "$1" | grep -Eq '^[[:space:]]*\? for shortcuts([[:space:]]+Gemini[[:space:]]+[0-9]+(\.[0-9]+)*[[:space:]]+(Flash|Argon)[[:space:]]+·[[:space:]]+(high|medium|low))?[[:space:]]*$'; then
    pane_has_empty_composer "$1"
  else
    return 1
  fi
}

pane_has_empty_composer() {
  pane_bottom_lines "$1" | awk '
    function is_divider(line) {
      return line ~ /^[[:space:]]*(─+|━+|-+)[[:space:]]*$/
    }
    function is_composer(line) {
      return line ~ /^[[:space:]]*>[[:space:]]*$/
    }
    { rows[NR] = $0 }
    END {
      i = NR - 1
      if (i < 1) exit 1
      if (is_divider(rows[i])) i--
      if (i < 1 || !is_composer(rows[i])) exit 1
      i--
      if (i >= 1 && is_divider(rows[i])) i--
      exit 0
    }
  '
}

pane_is_ready() {
  pane_is_idle "$1"
}

pane_model_matches_requested() {  # <pane> <requested-model>
  local line model_label tier
  line=$(pane_last_nonblank_line "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  case "$2" in
    gemini-3.8-flash-high) model_label='Gemini 3.8 Flash'; tier=high ;;
    gemini-3.8-flash-medium) model_label='Gemini 3.8 Flash'; tier=medium ;;
    gemini-3.8-flash-low) model_label='Gemini 3.8 Flash'; tier=low ;;
    gemini-4-argon-high) model_label='Gemini 4 Argon'; tier=high ;;
    gemini-4-argon-medium) model_label='Gemini 4 Argon'; tier=medium ;;
    gemini-4-argon-low) model_label='Gemini 4 Argon'; tier=low ;;
    *) return 1 ;;
  esac
  case "$line" in
    "? for shortcuts "*"$model_label · $tier") return 0 ;;
    *) return 1 ;;
  esac
}

pane_shows_command_approval() {
  if pane_is_busy "$1" || pane_is_idle "$1"; then
    return 1
  fi
  pane_bottom_lines "$1" | awk '
    function is_approval(line) {
      return line ~ /Allow .* to (run|execute|edit|write|modify)/ ||
        line ~ /Do you want to (run|execute|allow|approve)/ ||
        line ~ /requires permission to (run|execute|edit|write)/
    }
    {
      if (is_approval($0)) question = NR
      if (question && NR > question && $0 ~ /^[[:space:]]*(>[[:space:]]*)?(Yes|Allow|Approve)([[:space:]]|$)/) yes = NR
      if (question && NR > question && $0 ~ /^[[:space:]]*(>[[:space:]]*)?(No|Deny|Cancel)([[:space:]]|$)/) no = NR
    }
    END {
      if (question && yes > question && no > yes && NR - question <= 5) exit 0
      exit 1
    }
  '
}

send_literal_prompt() {  # <session> <prompt>
  case "$2" in
    -*) tmux send-keys -t "$1" -l -- "$2" ;;
    *) tmux send-keys -t "$1" -l "$2" ;;
  esac
}

dedupe_capture() {
  printf '%s\n' "$1" | awk '
    function is_footer(line) {
      return line ~ /^[[:space:]]*(\? for shortcuts|esc to cancel)([[:space:]]+Gemini[[:space:]]+[0-9]+(\.[0-9]+)*[[:space:]]+(Flash|Argon)[[:space:]]+·[[:space:]]+(high|medium|low))?[[:space:]]*$/
    }
    function is_divider(line) {
      return line ~ /^[[:space:]]*(─+|━+|-+)[[:space:]]*$/
    }
    function is_composer(line) {
      return line ~ /^[[:space:]]*>[[:space:]]*$/
    }
    function is_spinner(line) {
      return line ~ /^[[:space:]]*[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏⣾⣽⣻⢿⡿⣟⣯⣷][[:space:]]+(Generating\.\.\.|Focusing on plan)[[:space:]]*$/
    }
    {
      gsub(/\r/, "")
      lines[NR] = $0
      if ($0 ~ /[^[:space:]]/) nonblank[++count] = NR
    }
    END {
      end_line = NR
      if (count >= 2 && is_footer(lines[nonblank[count]])) {
        i = count - 1
        if (i >= 1 && is_divider(lines[nonblank[i]])) i--
        if (i >= 1 && is_composer(lines[nonblank[i]])) {
          end_line = nonblank[i] - 1
          i--
          if (i >= 1 && is_divider(lines[nonblank[i]])) end_line = nonblank[i] - 1
        }
      }
      while (end_line > 0 && is_spinner(lines[end_line])) end_line--
      for (i = 1; i <= end_line; i++) {
        print lines[i]
      }
    }
  '
}

find_turn_start() {  # <capture> <final-prompt> <pre-capture>
  printf '%s\n' "$1" | CURRENT_PROMPT="$2" PRE_CAPTURE="$3" awk '
    function compact(text) {
      gsub(/[[:space:]]/, "", text)
      return text
    }
    function occurrences(text, needle,   rest, at, count) {
      if (needle == "") return 0
      rest = text
      count = 0
      while ((at = index(rest, needle)) > 0) {
        count++
        rest = substr(rest, at + length(needle))
      }
      return count
    }
    BEGIN {
      needle = ">" compact(ENVIRON["CURRENT_PROMPT"])
      baseline_count = occurrences(compact(ENVIRON["PRE_CAPTURE"]), needle)
    }
    {
      lines[NR] = $0
      normalized = compact($0)
      starts[NR] = length(current) + 1
      current = current normalized
      ends[NR] = length(current)
    }
    END {
      if (needle == ">") exit 1
      target = baseline_count + 1
      count = 0
      for (pos = 1; pos <= length(current) - length(needle) + 1; pos++) {
        if (substr(current, pos, length(needle)) == needle) {
          count++
          if (count == target) {
            for (line = 1; line <= NR; line++) {
              if (starts[line] <= pos && pos <= ends[line]) {
                print line
                exit 0
              }
            }
          }
        }
      }
      exit 1
    }
  '
}

extract_current_turn() {  # <capture> <final-prompt> <pre-capture>
  local start
  start=$(find_turn_start "$1" "$2" "$3") || return 1
  printf '%s\n' "$1" | tail -n +"$start"
}

TOPIC=""
PROMPT_TEXT=""
PROMPT_SOURCE=""
PROMPT_FILE=""
TARGET_DIR="$PWD"
SESSION="agy"
MODEL=""
EFFORT=""
POLICY="read-only"
LINES="${FM_AGY_CONSULT_LINES:-500}"
TIMEOUT="${FM_AGY_CONSULT_TIMEOUT:-300}"
POLL_INTERVAL="${FM_AGY_CONSULT_POLL_INTERVAL:-2}"
SETTLE_POLLS="${FM_AGY_CONSULT_SETTLE_POLLS:-2}"
DATE_STR="${FM_AGY_CONSULT_DATE:-}"
OUTPUT_DIR="$DATA_DIR/agy-reviews"
QUIET=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --topic)
      [ "$#" -ge 2 ] || die_usage "$1 requires a topic slug"
      TOPIC=$2
      shift 2
      ;;
    --prompt)
      [ "$#" -ge 2 ] || die_usage "$1 requires prompt text"
      [ -z "$PROMPT_SOURCE" ] || die_usage "specify only one of --prompt or --prompt-file"
      PROMPT_SOURCE="flag"
      PROMPT_TEXT=$2
      shift 2
      ;;
    --prompt-file)
      [ "$#" -ge 2 ] || die_usage "$1 requires a file path"
      [ -z "$PROMPT_SOURCE" ] || die_usage "specify only one of --prompt or --prompt-file"
      PROMPT_SOURCE="file"
      PROMPT_FILE=$2
      shift 2
      ;;
    --dir)
      [ "$#" -ge 2 ] || die_usage "$1 requires a directory path"
      TARGET_DIR=$2
      shift 2
      ;;
    --session)
      [ "$#" -ge 2 ] || die_usage "$1 requires a tmux session name"
      SESSION=$2
      shift 2
      ;;
    --model)
      [ "$#" -ge 2 ] || die_usage "$1 requires a model id"
      MODEL=$2
      shift 2
      ;;
    --effort)
      [ "$#" -ge 2 ] || die_usage "--effort requires low, medium, or high"
      EFFORT=$2
      shift 2
      ;;
    --policy)
      [ "$#" -ge 2 ] || die_usage "$1 requires read-only or prompt-as-is"
      POLICY=$2
      shift 2
      ;;
    --lines)
      [ "$#" -ge 2 ] || die_usage "$1 requires a positive line count"
      LINES=$2
      shift 2
      ;;
    --timeout)
      [ "$#" -ge 2 ] || die_usage "--timeout requires a positive integer (seconds)"
      TIMEOUT=$2
      shift 2
      ;;
    --poll-interval)
      [ "$#" -ge 2 ] || die_usage "--poll-interval requires a positive integer (seconds)"
      POLL_INTERVAL=$2
      shift 2
      ;;
    --settle-polls)
      [ "$#" -ge 2 ] || die_usage "--settle-polls requires a positive integer"
      SETTLE_POLLS=$2
      shift 2
      ;;
    --date)
      [ "$#" -ge 2 ] || die_usage "--date requires YYYY-MM-DD"
      DATE_STR=$2
      shift 2
      ;;
    --quiet)
      QUIET=1
      shift
      ;;
    -*)
      die_usage "unknown option: $1 (see --help)"
      ;;
    *)
      die_usage "unexpected argument: $1 (use --prompt or --prompt-file)"
      ;;
  esac
done

[ -n "$DATE_STR" ] || DATE_STR=$(date +%Y-%m-%d)
is_calendar_date "$DATE_STR" || die_usage "invalid --date '$DATE_STR'; expected a real calendar date in YYYY-MM-DD form"

[ -n "$TOPIC" ] || die_usage "--topic <slug> is required"
TOPIC=${TOPIC%.txt}
case "${TOPIC:0:11}" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-) TOPIC=${TOPIC:11} ;;
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
  read-only | prompt-as-is) ;;
  *)
    die "unsupported permission policy '$POLICY'; supported policies are 'read-only' (default) and 'prompt-as-is'"
    ;;
esac

is_positive_int "$LINES" || die_usage "--lines must be a positive integer (got '$LINES')"
is_positive_int "$TIMEOUT" || die_usage "--timeout must be a positive integer in seconds (got '$TIMEOUT')"
is_positive_int "$POLL_INTERVAL" || die_usage "--poll-interval must be a positive integer in seconds (got '$POLL_INTERVAL')"
is_positive_int "$SETTLE_POLLS" || die_usage "--settle-polls must be a positive integer (got '$SETTLE_POLLS')"

[ -n "$PROMPT_SOURCE" ] || die_usage "a prompt is required via --prompt or --prompt-file"
if [ "$PROMPT_SOURCE" = "file" ]; then
  [ -f "$PROMPT_FILE" ] && [ -r "$PROMPT_FILE" ] || die "prompt file '$PROMPT_FILE' is not a readable regular file"
  PROMPT_TEXT=$(cat -- "$PROMPT_FILE")
fi

SINGLE_LINE_RAW=$(normalize_single_line "$PROMPT_TEXT")
[ -n "$SINGLE_LINE_RAW" ] || die_usage "prompt text must not be empty"

if [ "$POLICY" = "read-only" ]; then
  READ_ONLY_PREFIX='Read-only consultation (do not modify, create, or delete any file, and do not run state-changing commands): '
  case "$SINGLE_LINE_RAW" in
    "$READ_ONLY_PREFIX"*)
      FINAL_PROMPT="$SINGLE_LINE_RAW"
      ;;
    *)
      FINAL_PROMPT="$READ_ONLY_PREFIX$SINGLE_LINE_RAW"
      ;;
  esac
else
  FINAL_PROMPT="$SINGLE_LINE_RAW"
fi

TARGET_DIR_REAL=$(cd -P -- "$TARGET_DIR" 2>/dev/null && pwd -P) || true
[ -n "$TARGET_DIR_REAL" ] || die "target directory '$TARGET_DIR' is not an accessible directory"

command -v tmux >/dev/null 2>&1 || die "tmux executable not found on PATH"
command -v agy >/dev/null 2>&1 || die "agy executable not found on PATH"
command -v node >/dev/null 2>&1 || die "node executable is required to verify the agy workspace trust store"
[ -n "${HOME:-}" ] || [ -n "${FM_AGY_SETTINGS_FILE:-}" ] \
  || die "HOME is not set, so the agy workspace trust store cannot be located"

AGY_SETTINGS_FILE="${FM_AGY_SETTINGS_FILE:-${HOME:-}/.gemini/antigravity-cli/settings.json}"
agy_directory_is_trusted() {  # <directory>...
  node - "$AGY_SETTINGS_FILE" "$@" <<'NODE'
const fs = require("node:fs");
const [store, ...directories] = process.argv.slice(2);
try {
  const settings = JSON.parse(fs.readFileSync(store, "utf8"));
  if (settings === null || typeof settings !== "object" || Array.isArray(settings)) {
    process.exit(1);
  }
  const trusted = settings.trustedWorkspaces;
  if (!Array.isArray(trusted) || !directories.every((directory) => trusted.includes(directory))) {
    process.exit(1);
  }
} catch {
  process.exit(1);
}
NODE
}

refuse_untrusted_directory() {
  die "agy workspace '$1' is not listed in '$AGY_SETTINGS_FILE' trustedWorkspaces; trust a linked task worktree with bin/fm-agy-trust.sh or launch agy manually once, then retry"
}

agy_directory_is_trusted "$TARGET_DIR_REAL" || refuse_untrusted_directory "$TARGET_DIR_REAL"

SESSION_REUSED=1
if ! tmux has-session -t "$SESSION" 2>/dev/null; then
  SESSION_REUSED=0
else
  PANE_DIR=$(tmux display-message -p -t "$SESSION" '#{pane_current_path}' 2>/dev/null) \
    || die "could not read the working directory of tmux session '$SESSION'"
  PANE_DIR_REAL=$(cd -P -- "$PANE_DIR" 2>/dev/null && pwd -P) \
    || die "live pane directory '$PANE_DIR' for tmux session '$SESSION' is not accessible"
  agy_directory_is_trusted "$PANE_DIR" "$PANE_DIR_REAL" \
    || refuse_untrusted_directory "$PANE_DIR_REAL"
fi

mkdir -p -- "$OUTPUT_DIR" || die "could not create output directory '$OUTPUT_DIR'"
OUTPUT_DIR_REAL=$(cd -P -- "$OUTPUT_DIR" 2>/dev/null && pwd -P) || die "output directory '$OUTPUT_DIR' is not accessible"
OUT_FILE="$OUTPUT_DIR_REAL/${DATE_STR}-${TOPIC}.txt"

if [ "$SESSION_REUSED" -eq 0 ]; then
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

PRE_CAPTURE=""
READY_PANE=""
READY_START=$(date +%s)
READY_POLLS=0
READY_MAX_POLLS=$(( TIMEOUT / POLL_INTERVAL ))
[ "$READY_MAX_POLLS" -ge 1 ] || READY_MAX_POLLS=1
while [ "$READY_POLLS" -lt "$READY_MAX_POLLS" ]; do
  PRE_CAPTURE=$(tmux capture-pane -p -t "$SESSION" -S -"$LINES" 2>/dev/null) \
    || die "failed to capture tmux session '$SESSION'"
  if pane_shows_trust_dialog "$PRE_CAPTURE"; then
    die "agy session '$SESSION' displayed a folder-trust dialog for '$TARGET_DIR_REAL'; refusing to answer it. Trust a linked task worktree with bin/fm-agy-trust.sh or launch agy manually once, then retry"
  fi
  if [ "$SESSION_REUSED" -eq 1 ] && pane_is_busy "$PRE_CAPTURE"; then
    die "tmux session '$SESSION' is already busy (esc to cancel); wait for the active turn to finish or use a different --session"
  fi
  if pane_is_ready "$PRE_CAPTURE"; then
    READY_PANE="$PRE_CAPTURE"
    break
  fi
  sleep "$POLL_INTERVAL"
  READY_POLLS=$(( READY_POLLS + 1 ))
  READY_NOW=$(date +%s)
  if [ $(( READY_NOW - READY_START )) -ge "$TIMEOUT" ]; then
    break
  fi
done
[ -n "$READY_PANE" ] || die "agy session '$SESSION' did not reach the ready idle composer within ${TIMEOUT}s"
PRE_CAPTURE="$READY_PANE"

if [ "$SESSION_REUSED" -eq 1 ] && [ -n "$MODEL" ] && ! pane_model_matches_requested "$PRE_CAPTURE" "$MODEL"; then
  die "existing tmux session '$SESSION' is running a different model than requested '$MODEL' or its model cannot be identified; use a different --session"
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
PROMPT_LANDED=0

while [ "$POLL_COUNT" -lt "$MAX_POLLS" ]; do
  sleep "$POLL_INTERVAL"
  POLL_COUNT=$(( POLL_COUNT + 1 ))

  PANE=$(tmux capture-pane -p -t "$SESSION" -S -"$LINES" 2>/dev/null) \
    || die "lost tmux session '$SESSION' while waiting for consultation reply"
  LAST_PANE="$PANE"

  if pane_shows_trust_dialog "$PANE"; then
    die "agy session '$SESSION' displayed a folder-trust dialog for '$TARGET_DIR_REAL'; refusing to answer it. Trust a linked task worktree with bin/fm-agy-trust.sh or launch agy manually once, then retry"
  fi

  if [ "$PROMPT_LANDED" -eq 0 ]; then
    if find_turn_start "$PANE" "$FINAL_PROMPT" "$PRE_CAPTURE" >/dev/null; then
      PROMPT_LANDED=1
    else
      if pane_shows_command_approval "$PANE"; then
        die "agy consultation in session '$SESSION' parked on a per-command approval prompt before the submitted prompt appeared in the pane (helper never auto-approves command or edit permissions; inspect tmux session '$SESSION')"
      fi
      NOW_EPOCH=$(date +%s)
      if [ $(( NOW_EPOCH - START_EPOCH )) -ge "$TIMEOUT" ]; then
        break
      fi
      continue
    fi
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
    if [ "$PANE" != "$PRE_CAPTURE" ]; then
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
  if [ "$PROMPT_LANDED" -eq 0 ]; then
    die "submitted prompt never appeared in the pane for session '$SESSION'"
  fi
  if pane_shows_command_approval "$LAST_PANE"; then
    die "agy consultation in session '$SESSION' parked on a per-command approval prompt (helper never auto-approves command or edit permissions; inspect tmux session '$SESSION')"
  fi
  die "agy consultation in session '$SESSION' did not settle within ${TIMEOUT}s (inspect tmux session '$SESSION')"
fi

TURN_CAPTURE=$(extract_current_turn "$SETTLED_PANE" "$FINAL_PROMPT" "$PRE_CAPTURE") \
  || die "could not isolate the submitted prompt and answer for session '$SESSION'"
DEDUPED=$(dedupe_capture "$TURN_CAPTURE"; printf '\034')
DEDUPED=${DEDUPED%$'\034'}
TMP_OUT="$OUTPUT_DIR_REAL/.${DATE_STR}-${TOPIC}.txt.tmp.$$"
if ! printf '%s' "$DEDUPED" > "$TMP_OUT" || ! mv -f -- "$TMP_OUT" "$OUT_FILE"; then
  rm -f -- "$TMP_OUT" 2>/dev/null || true
  die "could not write consultation log '$OUT_FILE'"
fi

if [ "$QUIET" -eq 1 ]; then
  printf '%s\n' "$OUT_FILE"
else
  printf 'saved: %s\n' "$OUT_FILE"
  printf '%s' "$DEDUPED"
fi

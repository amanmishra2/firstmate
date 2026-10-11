#!/usr/bin/env bash
# fm-notify.sh - escalation push for the captain.
#
# Append exactly one durable escalation record to data/escalations.log and,
# best-effort, show a macOS notification. The log is the durable record: a
# notification that cannot be shown (not macOS, osascript absent, or the
# notification itself refused) never fails the command and is reported in the
# status line instead. Only an unwritable log fails.
# Callers use this for events the captain must eventually see - the research
# wave refusal in bin/fm-wave-request.sh is the first caller - never for
# routine progress, which stays in chat.
#
# Usage:
#   fm-notify.sh [--title <title>] <message>...
#   fm-notify.sh [--title <title>] -          (message from stdin)
#
# One record per call, one physical line each:
#   <ISO-8601 UTC timestamp> <message>
# The message is the whole durable record; the title is notification-only and
# never reaches the log. Embedded tabs, newlines, and carriage returns collapse
# to single spaces so a message can never span records.
# An empty or whitespace-only message is refused before anything is written.
#
# Output: exactly one status line, on every path that records the escalation.
#   logged+notified <log-path>   record written and a notification was shown
#   logged <log-path>            record written; no notification was shown
# Exit status: 0 whenever the record is written, whatever the notification did;
# nonzero means nothing was recorded, and the escalation still needs another
# route.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
LOG="$DATA/escalations.log"

TITLE="Firstmate escalation"

usage() {
  awk 'NR == 1 { next }
       /^#/ { sub(/^# ?/, ""); print; next }
       { exit }' "${BASH_SOURCE[0]}"
  exit 2
}

die() {
  printf 'fm-notify: %s\n' "$*" >&2
  exit 1
}

BODY_SET=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --title)
      [ "$#" -ge 2 ] || usage
      TITLE=$2
      shift 2
      ;;
    -h|--help) usage ;;
    --) shift; BODY_SET=1; break ;;
    *) BODY_SET=1; break ;;
  esac
done

[ "$BODY_SET" -eq 1 ] || usage

if [ "$#" -eq 1 ] && [ "$1" = "-" ]; then
  BODY=$(cat)
else
  BODY="$*"
fi
[ -n "${BODY//[[:space:]]/}" ] || die "refusing to log an empty escalation"

# One physical line per record: collapse tabs, newlines, and runs of spaces.
MESSAGE=$(printf '%s' "$BODY" | tr '\t\r\n' '   ' | sed 's/  */ /g; s/^ //; s/ $//')
[ -n "$MESSAGE" ] || die "refusing to log an empty escalation"

mkdir -p "$DATA" || die "cannot create $DATA"
umask 077
STAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '%s %s\n' "$STAMP" "$MESSAGE" >> "$LOG" || die "cannot append to $LOG"

NOTIFIED=0
if command -v osascript >/dev/null 2>&1; then
  ESC_MESSAGE=$(printf '%s' "$MESSAGE" | sed 's/\\/\\\\/g; s/"/\\"/g')
  ESC_TITLE=$(printf '%s' "$TITLE" | sed 's/\\/\\\\/g; s/"/\\"/g')
  if osascript -e "display notification \"$ESC_MESSAGE\" with title \"$ESC_TITLE\"" >/dev/null 2>&1; then
    NOTIFIED=1
  fi
fi

if [ "$NOTIFIED" -eq 1 ]; then
  printf 'logged+notified %s\n' "$LOG"
else
  printf 'logged %s\n' "$LOG"
fi

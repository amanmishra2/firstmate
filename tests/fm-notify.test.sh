#!/usr/bin/env bash
# Behavior tests for fm-notify.sh: the durable escalations-log append, the
# one-physical-line-per-record guarantee, and the best-effort notification that
# must neither crash nor fail the record when osascript is unavailable.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NOTIFY="$ROOT/bin/fm-notify.sh"
TMP_ROOT=$(fm_test_tmproot fm-notify)

# A PATH that resolves every ordinary tool but not osascript, so the
# absent-notifier cases decide identically on macOS and Linux and a test run
# never fires a real notification (fm_test_base_path_sans owns the mechanism).
SANS_OSASCRIPT=$(fm_test_base_path_sans "$PATH" osascript)

make_home() {  # <name>
  local home
  home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data"
  printf '%s\n' "$home"
}

test_log_append_one_record_per_call() {
  local home out status line count
  home=$(make_home append)
  out=$(FM_HOME="$home" PATH="$SANS_OSASCRIPT" "$NOTIFY" \
    "research wave refused: no live session" 2>&1)
  status=$?
  expect_code 0 "$status" "notify with a message"
  assert_contains "$out" "logged " "notify must report the recorded escalation"
  assert_present "$home/data/escalations.log" "notify wrote no log"
  count=$(wc -l < "$home/data/escalations.log" | tr -d ' ')
  assert_equals 1 "$count" "one call must write exactly one record"
  line=$(cat "$home/data/escalations.log")
  assert_contains "$line" "research wave refused: no live session" "record lost the message"
  case "$line" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z" "*) ;;
    *) fail "record does not open with an ISO-8601 UTC timestamp: $line" ;;
  esac

  FM_HOME="$home" PATH="$SANS_OSASCRIPT" "$NOTIFY" "second escalation" >/dev/null
  count=$(wc -l < "$home/data/escalations.log" | tr -d ' ')
  assert_equals 2 "$count" "a second call must append a second record"
  pass "fm-notify appends exactly one durable record per call"
}

test_multiline_message_stays_one_line() {
  local home count line
  home=$(make_home multiline)
  printf 'line one\nline two\tend\n' | FM_HOME="$home" PATH="$SANS_OSASCRIPT" "$NOTIFY" - >/dev/null
  count=$(wc -l < "$home/data/escalations.log" | tr -d ' ')
  assert_equals 1 "$count" "a multiline message must stay one record"
  line=$(cat "$home/data/escalations.log")
  assert_contains "$line" "line one line two end" "newlines and tabs must collapse to single spaces"
  pass "embedded newlines and tabs collapse into the single log line"
}

test_no_osascript_logs_and_exits_zero() {
  local home out status
  home=$(make_home no-osascript)
  status=0
  out=$(FM_HOME="$home" PATH="$SANS_OSASCRIPT" "$NOTIFY" \
    "works without osascript" 2>&1) || status=$?
  expect_code 0 "$status" "notify without osascript"
  assert_contains "$out" "logged " "notify must report the log-only outcome"
  assert_not_contains "$out" "notified" "notify must not claim a notification it could not show"
  assert_grep "works without osascript" "$home/data/escalations.log" \
    "record missing when osascript is unavailable"
  pass "fm-notify logs the record and exits zero when osascript is unavailable"
}

test_notification_attempted_when_osascript_present() {
  local home fakebin out osalog
  home=$(make_home osascript)
  fakebin=$(fm_fakebin "$home")
  osalog="$home/osascript.log"
  : > "$osalog"
  cat > "$fakebin/osascript" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$osalog"
exit 0
SH
  chmod +x "$fakebin/osascript"
  out=$(FM_HOME="$home" PATH="$fakebin:$SANS_OSASCRIPT" "$NOTIFY" \
    --title "Test title" "notify me" 2>&1)
  assert_contains "$out" "logged+notified" "notify must report the notification outcome"
  assert_grep "display notification" "$osalog" \
    "osascript was not asked to display the notification"
  assert_grep "notify me" "$osalog" "the notification lost the message"
  assert_grep "Test title" "$osalog" "the notification lost the title"
  assert_grep "notify me" "$home/data/escalations.log" "the durable record lost the message"
  pass "fm-notify fires the best-effort notification when osascript exists"
}

test_empty_message_refused_before_writing() {
  local home status
  home=$(make_home empty)
  status=0
  FM_HOME="$home" PATH="$SANS_OSASCRIPT" "$NOTIFY" "   " >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "an empty escalation was accepted"
  assert_absent "$home/data/escalations.log" "an empty escalation wrote a record"
  pass "fm-notify refuses an empty escalation before writing anything"
}

test_log_append_one_record_per_call
test_multiline_message_stays_one_line
test_no_osascript_logs_and_exits_zero
test_notification_attempted_when_osascript_present
test_empty_message_refused_before_writing

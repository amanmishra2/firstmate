#!/usr/bin/env bash
# Behavior tests for bin/fm-capability-scout.sh, the monthly capability scout's
# cadence mechanics: the 28-day due test, its durable anchor, and the fail-loud
# handling of a damaged anchor. The scout procedure itself is owned by the
# skill and is not exercised here.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-capability-scout)
SCOUT="$ROOT/bin/fm-capability-scout.sh"
DAY=86400
CADENCE=$((28 * DAY))

new_home() {  # <name> -> prints a fresh home path
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data"
  printf '%s\n' "$home"
}

test_absent_anchor_is_due() {
  local home out rc
  home=$(new_home absent)
  out=$(FM_HOME="$home" "$SCOUT" due 2>&1); rc=$?
  expect_code 0 "$rc" "due on an absent anchor must exit 0 (got: $out)"
  assert_contains "$out" "CAPABILITY_SCOUT_DUE: true" "due line missing on absent anchor"
  assert_contains "$out" "last_sweep=none" "absent anchor must report no prior sweep"
  pass "fm-capability-scout.sh: absent anchor is due"
}

test_mark_then_not_due_and_boundary() {
  local home t out rc anchor
  home=$(new_home mark)
  t=1000000000
  FM_HOME="$home" "$SCOUT" mark --now "$t" --task wave-1 >/dev/null 2>&1 \
    || fail "mark should succeed on a fresh home"
  anchor="$home/data/capability-scout/last-sweep"
  assert_grep "last_epoch=$t" "$anchor" "anchor must record the marked epoch"
  assert_grep "last_date=2001-09-09" "$anchor" "anchor must record the canonical marked date"
  assert_grep "task=wave-1" "$anchor" "anchor must record the dispatched task id"

  out=$(FM_HOME="$home" "$SCOUT" due --now "$((t + 27 * DAY))" 2>&1); rc=$?
  expect_code 1 "$rc" "27 days after a mark is still within cadence (got: $out)"
  assert_contains "$out" "CAPABILITY_SCOUT_DUE: false" "27 days must not be due"

  out=$(FM_HOME="$home" "$SCOUT" due --now "$((t + CADENCE - 1))" 2>&1); rc=$?
  expect_code 1 "$rc" "one second before the interval is not due (got: $out)"

  out=$(FM_HOME="$home" "$SCOUT" due --now "$((t + CADENCE))" 2>&1); rc=$?
  expect_code 0 "$rc" "the interval boundary itself is due (got: $out)"
  assert_contains "$out" "CAPABILITY_SCOUT_DUE: true" "boundary check must report due"
  pass "fm-capability-scout.sh: mark resets the cadence and the boundary is exact"
}

test_corrupt_anchor_fails_loud() {
  local home anchor before out rc
  home=$(new_home corrupt)
  mkdir -p "$home/data/capability-scout"
  anchor="$home/data/capability-scout/last-sweep"
  printf 'last_epoch=soon\n' > "$anchor"
  before=$(cat "$anchor")
  out=$(FM_HOME="$home" "$SCOUT" due 2>&1); rc=$?
  expect_code 2 "$rc" "a corrupt anchor must be a real error, not 'not due' (got: $out)"
  assert_contains "$out" "corrupt anchor" "the refusal must name the damaged anchor"
  out=$(FM_HOME="$home" "$SCOUT" mark 2>&1); rc=$?
  expect_code 2 "$rc" "mark must reject a corrupt anchor (got: $out)"
  [ "$(cat "$anchor")" = "$before" ] || fail "mark replaced the corrupt anchor"
  pass "fm-capability-scout.sh: a corrupt anchor is refused and preserved"
}

test_symlinked_anchor_is_refused() {
  local home out rc anchor target
  home=$(new_home symlink)
  mkdir -p "$home/data/capability-scout"
  anchor="$home/data/capability-scout/last-sweep"
  target=missing-anchor-target
  ln -s "$target" "$anchor"
  out=$(FM_HOME="$home" "$SCOUT" due 2>&1); rc=$?
  expect_code 2 "$rc" "a symlinked anchor must be refused (got: $out)"
  assert_contains "$out" "refusing symlinked anchor" "the refusal must say why"
  out=$(FM_HOME="$home" "$SCOUT" mark 2>&1); rc=$?
  expect_code 2 "$rc" "mark must not write through a symlinked anchor (got: $out)"
  [ -L "$anchor" ] || fail "mark replaced the dangling symlinked anchor"
  [ "$(readlink "$anchor")" = "$target" ] || fail "mark changed the dangling symlink target"
  pass "fm-capability-scout.sh: a symlinked anchor is refused"
}

test_empty_anchor_is_refused() {
  local home anchor before out rc
  home=$(new_home empty)
  mkdir -p "$home/data/capability-scout"
  anchor="$home/data/capability-scout/last-sweep"
  : > "$anchor"
  before=$(cat "$anchor")
  out=$(FM_HOME="$home" "$SCOUT" due 2>&1); rc=$?
  expect_code 2 "$rc" "due must reject an empty anchor (got: $out)"
  assert_contains "$out" "last_epoch" "empty-anchor refusal must name the missing epoch"
  out=$(FM_HOME="$home" "$SCOUT" mark 2>&1); rc=$?
  expect_code 2 "$rc" "mark must reject an empty anchor (got: $out)"
  [ "$(cat "$anchor")" = "$before" ] || fail "mark replaced the empty anchor"
  pass "fm-capability-scout.sh: an empty anchor is refused and preserved"
}

test_missing_epoch_anchor_is_refused() {
  local home anchor before out rc
  home=$(new_home missing-epoch)
  mkdir -p "$home/data/capability-scout"
  anchor="$home/data/capability-scout/last-sweep"
  printf 'last_date=2001-09-09\n' > "$anchor"
  before=$(cat "$anchor")
  out=$(FM_HOME="$home" "$SCOUT" due 2>&1); rc=$?
  expect_code 2 "$rc" "due must reject an anchor missing last_epoch (got: $out)"
  assert_contains "$out" "last_epoch" "missing-epoch refusal must name the missing epoch"
  out=$(FM_HOME="$home" "$SCOUT" mark 2>&1); rc=$?
  expect_code 2 "$rc" "mark must reject an anchor missing last_epoch (got: $out)"
  [ "$(cat "$anchor")" = "$before" ] || fail "mark replaced the missing-epoch anchor"
  pass "fm-capability-scout.sh: a missing epoch is refused and preserved"
}

test_invalid_last_date_is_refused() {
  local variant home anchor before out rc value
  for variant in malformed mismatched; do
    home=$(new_home "last-date-$variant")
    mkdir -p "$home/data/capability-scout"
    anchor="$home/data/capability-scout/last-sweep"
    if [ "$variant" = malformed ]; then
      value=not-a-date
    else
      value=2001-09-10
    fi
    printf 'last_epoch=1000000000\nlast_date=%s\n' "$value" > "$anchor"
    before=$(cat "$anchor")
    out=$(FM_HOME="$home" "$SCOUT" due 2>&1); rc=$?
    expect_code 2 "$rc" "due must reject a $variant last_date (got: $out)"
    assert_contains "$out" "last_date" "$variant last_date refusal must name the invalid date"
    out=$(FM_HOME="$home" "$SCOUT" mark 2>&1); rc=$?
    expect_code 2 "$rc" "mark must reject a $variant last_date (got: $out)"
    [ "$(cat "$anchor")" = "$before" ] || fail "mark replaced the $variant last-date anchor"
  done
  pass "fm-capability-scout.sh: malformed and mismatched dates are refused and preserved"
}

test_argument_validation() {
  local home out rc
  home=$(new_home args)
  out=$(FM_HOME="$home" "$SCOUT" due --now later 2>&1); rc=$?
  expect_code 2 "$rc" "--now must reject a non-numeric epoch (got: $out)"
  out=$(FM_HOME="$home" "$SCOUT" mark --task 'bad id' 2>&1); rc=$?
  expect_code 2 "$rc" "--task must reject a non-id value (got: $out)"
  out=$(FM_HOME="$home" "$SCOUT" bogus 2>&1); rc=$?
  expect_code 2 "$rc" "an unknown command must exit 2 (got: $out)"
  out=$(FM_HOME="$home" "$SCOUT" --help 2>&1); rc=$?
  expect_code 0 "$rc" "--help must exit 0 (got: $out)"
  pass "fm-capability-scout.sh: arguments are validated"
}

test_absent_anchor_is_due
test_mark_then_not_due_and_boundary
test_corrupt_anchor_fails_loud
test_symlinked_anchor_is_refused
test_empty_anchor_is_refused
test_missing_epoch_anchor_is_refused
test_invalid_last_date_is_refused
test_argument_validation

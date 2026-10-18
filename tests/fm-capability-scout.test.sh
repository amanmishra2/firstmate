#!/usr/bin/env bash
# Behavior tests for bin/fm-capability-scout.sh, the monthly capability scout's
# cadence mechanics: one UTC calendar month per due session, its durable anchor,
# and the fail-loud
# handling of a damaged anchor. The scout procedure itself is owned by the
# skill and is not exercised here.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-capability-scout)
SCOUT="$ROOT/bin/fm-capability-scout.sh"
new_home() {  # <name> -> prints a fresh home path
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data"
  printf '%s\n' "$home"
}

test_absent_anchor_is_due() {
  local home out rc
  home=$(new_home absent)
  out=$(FM_HOME="$home" "$SCOUT" due --now 1705276800 2>&1); rc=$?
  expect_code 0 "$rc" "due on an absent anchor must exit 0 (got: $out)"
  assert_contains "$out" "CAPABILITY_SCOUT_DUE: true" "due line missing on absent anchor"
  assert_contains "$out" "last_sweep=none" "absent anchor must report no prior sweep"
  assert_contains "$out" "next_due=2024-02-01" "absent anchor must report the next UTC calendar month"
  pass "fm-capability-scout.sh: absent anchor is due"
}

test_same_month_is_not_due_and_next_month_is_due() {
  local home t out rc anchor
  home=$(new_home monthly-boundary)
  t=1705276800
  FM_HOME="$home" "$SCOUT" mark --now "$t" --task wave-1 >/dev/null 2>&1 \
    || fail "mark should succeed on a fresh home"
  anchor="$home/data/capability-scout/last-sweep"
  assert_grep "last_epoch=$t" "$anchor" "anchor must record the marked epoch"
  assert_grep "last_date=2024-01-15" "$anchor" "anchor must record the canonical marked date"
  assert_grep "task=wave-1" "$anchor" "anchor must record the dispatched task id"

  out=$(FM_HOME="$home" "$SCOUT" due --now 1706659200 2>&1); rc=$?
  expect_code 1 "$rc" "a same-month weekly check must not be due (got: $out)"
  assert_contains "$out" "CAPABILITY_SCOUT_DUE: false" "same-month check must not be due"
  assert_contains "$out" "next_due=2024-02-01" "same-month check must point to the next month"

  out=$(FM_HOME="$home" "$SCOUT" due --now 1706745600 2>&1); rc=$?
  expect_code 0 "$rc" "the first check in the next month must be due (got: $out)"
  assert_contains "$out" "CAPABILITY_SCOUT_DUE: true" "next-month check must be due"
  assert_contains "$out" "next_due=2024-03-01" "next-month check must point to the following month"
  pass "fm-capability-scout.sh: same-month checks stay closed and the next month is due"
}

test_leading_zero_epoch_is_normalized() {
  local home out rc anchor
  home=$(new_home leading-zero)
  FM_HOME="$home" "$SCOUT" mark --now 01000000000 --task wave-leading >/dev/null 2>&1 \
    || fail "mark should accept a leading-zero epoch"
  anchor="$home/data/capability-scout/last-sweep"
  assert_grep "last_epoch=1000000000" "$anchor" "mark must persist a canonical epoch"
  assert_no_grep "last_epoch=01000000000" "$anchor" "mark must not persist leading zeroes"
  out=$(FM_HOME="$home" "$SCOUT" due --now 1000000001 2>&1); rc=$?
  expect_code 1 "$rc" "a same-month check after a leading-zero mark must not be due (got: $out)"
  assert_contains "$out" "CAPABILITY_SCOUT_DUE: false" "leading-zero epoch must preserve the anchor month"
  out=$(FM_HOME="$home" "$SCOUT" due --now 1001894400 2>&1); rc=$?
  expect_code 0 "$rc" "the next month after a leading-zero mark must be due (got: $out)"
  assert_contains "$out" "CAPABILITY_SCOUT_DUE: true" "leading-zero epoch must preserve the monthly boundary"
  pass "fm-capability-scout.sh: leading-zero epochs are normalized"
}

test_december_to_january_is_due() {
  local home out rc
  home=$(new_home december-january)
  FM_HOME="$home" "$SCOUT" mark --now 1735689540 --task wave-december >/dev/null 2>&1 \
    || fail "December mark should succeed"
  out=$(FM_HOME="$home" "$SCOUT" due --now 1735689540 2>&1); rc=$?
  expect_code 1 "$rc" "a second December check must not be due (got: $out)"
  assert_contains "$out" "CAPABILITY_SCOUT_DUE: false" "December must allow only one due session"
  assert_contains "$out" "next_due=2025-01-01" "December must point to January 1"
  out=$(FM_HOME="$home" "$SCOUT" due --now 1735689600 2>&1); rc=$?
  expect_code 0 "$rc" "January must be due after a December mark (got: $out)"
  assert_contains "$out" "last_sweep=2024-12-31" "December mark must retain its UTC date"
  assert_contains "$out" "next_due=2025-02-01" "January due output must point to February 1"
  pass "fm-capability-scout.sh: December-to-January rollover is due"
}

weekly_check() {
  local home=$1 epoch=$2 expected=$3 next_due=$4 out rc
  out=$(FM_HOME="$home" "$SCOUT" due --now "$epoch" 2>&1); rc=$?
  if [ "$expected" = true ]; then
    expect_code 0 "$rc" "weekly check at $epoch should be due (got: $out)"
  else
    expect_code 1 "$rc" "weekly check at $epoch should not be due (got: $out)"
  fi
  assert_contains "$out" "CAPABILITY_SCOUT_DUE: $expected" "weekly check at $epoch returned the wrong due state"
  assert_contains "$out" "next_due=$next_due" "weekly check at $epoch returned the wrong next month"
}

test_weekly_checks_across_several_months() {
  local home
  home=$(new_home weekly-months)
  FM_HOME="$home" "$SCOUT" mark --now 1788220800 --task wave-september >/dev/null 2>&1 \
    || fail "September mark should succeed"

  weekly_check "$home" 1788825600 false 2026-10-01
  weekly_check "$home" 1789430400 false 2026-10-01
  weekly_check "$home" 1790035200 false 2026-10-01
  weekly_check "$home" 1790640000 false 2026-10-01
  weekly_check "$home" 1791244800 true 2026-11-01
  FM_HOME="$home" "$SCOUT" mark --now 1791244800 --task wave-october >/dev/null 2>&1 \
    || fail "October mark should succeed"

  weekly_check "$home" 1791849600 false 2026-11-01
  weekly_check "$home" 1792454400 false 2026-11-01
  weekly_check "$home" 1793059200 false 2026-11-01
  weekly_check "$home" 1793664000 true 2026-12-01
  FM_HOME="$home" "$SCOUT" mark --now 1793664000 --task wave-november >/dev/null 2>&1 \
    || fail "November mark should succeed"

  weekly_check "$home" 1794268800 false 2026-12-01
  weekly_check "$home" 1794873600 false 2026-12-01
  weekly_check "$home" 1795478400 false 2026-12-01
  weekly_check "$home" 1796083200 true 2027-01-01
  FM_HOME="$home" "$SCOUT" mark --now 1796083200 --task wave-december >/dev/null 2>&1 \
    || fail "December mark should succeed"

  weekly_check "$home" 1796688000 false 2027-01-01
  weekly_check "$home" 1797292800 false 2027-01-01
  weekly_check "$home" 1797897600 false 2027-01-01
  weekly_check "$home" 1798502400 false 2027-01-01
  weekly_check "$home" 1799107200 true 2027-02-01
  pass "fm-capability-scout.sh: weekly Tuesday checks allow one due session across several UTC months"
}

test_out_of_range_now_is_refused() {
  local home out rc out_of_range
  home=$(new_home now-range)
  out_of_range=999999999999999999999999
  out=$(FM_HOME="$home" "$SCOUT" due --now "$out_of_range" 2>&1); rc=$?
  expect_code 2 "$rc" "due must reject an out-of-range --now epoch (got: $out)"
  out=$(FM_HOME="$home" "$SCOUT" mark --now "$out_of_range" 2>&1); rc=$?
  expect_code 2 "$rc" "mark must reject an out-of-range --now epoch (got: $out)"
  assert_absent "$home/data/capability-scout/last-sweep" "an out-of-range --now must not create an anchor"
  pass "fm-capability-scout.sh: out-of-range current epochs are refused"
}

test_out_of_range_stored_epoch_is_refused() {
  local home anchor before out rc out_of_range
  home=$(new_home stored-range)
  mkdir -p "$home/data/capability-scout"
  anchor="$home/data/capability-scout/last-sweep"
  out_of_range=999999999999999999999999
  printf 'last_epoch=%s\nlast_date=1970-01-01\ntask=wave-range\n' "$out_of_range" > "$anchor"
  before=$(cat "$anchor")
  out=$(FM_HOME="$home" "$SCOUT" due 2>&1); rc=$?
  expect_code 2 "$rc" "due must reject an out-of-range stored epoch (got: $out)"
  assert_contains "$out" "last_epoch" "stored-epoch refusal must name last_epoch"
  out=$(FM_HOME="$home" "$SCOUT" mark 2>&1); rc=$?
  expect_code 2 "$rc" "mark must reject an out-of-range stored epoch (got: $out)"
  [ "$(cat "$anchor")" = "$before" ] || fail "mark replaced the out-of-range stored anchor"
  pass "fm-capability-scout.sh: out-of-range stored epochs are refused and preserved"
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

test_symlinked_scout_dir_is_refused() {
  local home out rc scout_dir target_dir anchor before
  home=$(new_home symlinked-dir)
  scout_dir="$home/data/capability-scout"
  target_dir="$TMP_ROOT/symlinked-dir-target"
  mkdir -p "$target_dir"
  anchor="$target_dir/last-sweep"
  printf 'last_epoch=1000000000\nlast_date=2001-09-09\ntask=wave-recent\n' > "$anchor"
  before=$(cat "$anchor")
  ln -s "$target_dir" "$scout_dir"

  out=$(FM_HOME="$home" "$SCOUT" due --now 1000000001 2>&1); rc=$?
  expect_code 2 "$rc" "due must reject a symlinked scout directory (got: $out)"
  out=$(FM_HOME="$home" "$SCOUT" mark --now 1000000001 --task wave-rejected 2>&1); rc=$?
  expect_code 2 "$rc" "mark must reject a symlinked scout directory (got: $out)"
  [ "$(cat "$anchor")" = "$before" ] || fail "mark changed the symlink target anchor"
  pass "fm-capability-scout.sh: a symlinked scout directory is refused"
}

test_non_directory_scout_path_is_refused() {
  local home out rc scout_dir before
  home=$(new_home non-directory)
  scout_dir="$home/data/capability-scout"
  printf 'scout-directory-sentinel\n' > "$scout_dir"
  before=$(cat "$scout_dir")

  out=$(FM_HOME="$home" "$SCOUT" due 2>&1); rc=$?
  expect_code 2 "$rc" "due must reject a non-directory scout path (got: $out)"
  out=$(FM_HOME="$home" "$SCOUT" mark --now 1000000000 --task wave-rejected 2>&1); rc=$?
  expect_code 2 "$rc" "mark must reject a non-directory scout path (got: $out)"
  [ "$(cat "$scout_dir")" = "$before" ] || fail "mark changed the non-directory scout path"
  pass "fm-capability-scout.sh: a non-directory scout path is refused"
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
test_same_month_is_not_due_and_next_month_is_due
test_leading_zero_epoch_is_normalized
test_december_to_january_is_due
test_weekly_checks_across_several_months
test_out_of_range_now_is_refused
test_out_of_range_stored_epoch_is_refused
test_corrupt_anchor_fails_loud
test_symlinked_anchor_is_refused
test_symlinked_scout_dir_is_refused
test_non_directory_scout_path_is_refused
test_empty_anchor_is_refused
test_missing_epoch_anchor_is_refused
test_invalid_last_date_is_refused
test_argument_validation

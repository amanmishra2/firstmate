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

test_claim_records_metadata_and_closes_due() {
  local home out rc claim_meta
  home=$(new_home claim-metadata)
  FM_HOME="$home" "$SCOUT" claim --task monthly-review --now 1705276800 >/dev/null 2>&1 \
    || fail "claim should reserve an absent-anchor month"
  claim_meta="$home/data/capability-scout/claim/metadata"
  assert_grep "claim_epoch=1705276800" "$claim_meta" "claim must record its epoch"
  assert_grep "claim_date=2024-01-15" "$claim_meta" "claim must record its UTC date"
  assert_grep "task=monthly-review" "$claim_meta" "claim must record its task identity"
  assert_grep "dispatch_started=false" "$claim_meta" \
    "a reservation must remain unstarted until the dispatch handoff"

  out=$(FM_HOME="$home" "$SCOUT" due --now 1705276800 2>&1); rc=$?
  expect_code 1 "$rc" "a fresh claim must close due (got: $out)"
  assert_contains "$out" "CAPABILITY_SCOUT_DUE: false" "fresh claim must make due false"
  assert_contains "$out" "claim_state=fresh" "due must report a fresh claim"
  assert_contains "$out" "claim_epoch=1705276800" "due must report the claim epoch"
  assert_contains "$out" "claim_date=2024-01-15" "due must report the claim date"
  assert_contains "$out" "claim_task=monthly-review" "due must report the claim task"
  pass "fm-capability-scout.sh: claim metadata is recorded and a fresh claim closes due"
}

test_second_fresh_claim_is_refused() {
  local home out rc
  home=$(new_home duplicate-claim)
  FM_HOME="$home" "$SCOUT" claim --task first-review --now 1705276800 >/dev/null 2>&1 \
    || fail "first claim should succeed"
  out=$(FM_HOME="$home" "$SCOUT" claim --task second-review --now 1705276801 2>&1); rc=$?
  expect_code 2 "$rc" "a second fresh claim must be refused (got: $out)"
  assert_contains "$out" "fresh capability scout claim" "duplicate claim refusal must identify the fresh claim"
  assert_grep "task=first-review" "$home/data/capability-scout/claim/metadata" \
    "a duplicate claim must not replace the first task"
  pass "fm-capability-scout.sh: a second fresh claim is refused"
}

test_simultaneous_first_claims_have_one_winner() {
  local home now out_a out_b rc_a rc_b successes
  home=$(new_home simultaneous-claim)
  now=1705276800
  (
    set +e
    FM_HOME="$home" "$SCOUT" claim --task race-a --now "$now" >"$home/race-a.out" 2>&1
    printf '%s\n' "$?" >"$home/race-a.rc"
  ) &
  local pid_a=$!
  (
    set +e
    FM_HOME="$home" "$SCOUT" claim --task race-b --now "$now" >"$home/race-b.out" 2>&1
    printf '%s\n' "$?" >"$home/race-b.rc"
  ) &
  local pid_b=$!
  wait "$pid_a" || true
  wait "$pid_b" || true
  rc_a=$(cat "$home/race-a.rc")
  rc_b=$(cat "$home/race-b.rc")
  successes=0
  [ "$rc_a" = 0 ] && successes=$((successes + 1))
  [ "$rc_b" = 0 ] && successes=$((successes + 1))
  assert_equals 1 "$successes" "simultaneous first claims must have exactly one winner"
  out_a=$(cat "$home/race-a.out")
  out_b=$(cat "$home/race-b.out")
  if [ "$rc_a" = 0 ]; then
    assert_contains "$out_a" "claimed capability scout dispatch" "winning race claim must report success"
    expect_code 2 "$rc_b" "losing race claim must refuse the fresh claim"
  else
    expect_code 2 "$rc_a" "losing race claim must refuse the fresh claim"
    assert_contains "$out_b" "claimed capability scout dispatch" "winning race claim must report success"
  fi
  pass "fm-capability-scout.sh: simultaneous first claims have one winner"
}

test_stale_claim_is_due_and_can_be_retaken() {
  local home out rc claim_meta
  home=$(new_home stale-claim)
  FM_HOME="$home" "$SCOUT" claim --task old-review --now 1705276800 >/dev/null 2>&1 \
    || fail "initial claim should succeed"
  out=$(FM_HOME="$home" "$SCOUT" due --now 1705363200 2>&1); rc=$?
  expect_code 0 "$rc" "a claim at least 24 hours old must become due (got: $out)"
  assert_contains "$out" "CAPABILITY_SCOUT_DUE: true" "stale claim must not close due"
  assert_contains "$out" "claim_state=stale" "due must report a stale claim"
  FM_HOME="$home" "$SCOUT" claim --task replacement-review --now 1705363200 >/dev/null 2>&1 \
    || fail "stale claim should be retaken"
  claim_meta="$home/data/capability-scout/claim/metadata"
  assert_grep "claim_epoch=1705363200" "$claim_meta" "retaken claim must record the new epoch"
  assert_grep "claim_date=2024-01-16" "$claim_meta" "retaken claim must record its UTC date"
  assert_grep "task=replacement-review" "$claim_meta" "retaken claim must record the new task"
  assert_absent "$home/data/capability-scout/.claim-stale" "stale claim recovery must not leave a fixed quarantine path"
  pass "fm-capability-scout.sh: stale claims become due and can be retaken"
}

test_started_claim_consumes_its_month_and_rolls_forward() {
  local home out rc metadata
  home=$(new_home started-claim)
  FM_HOME="$home" "$SCOUT" claim --task started-review --now 1705276800 >/dev/null 2>&1 \
    || fail "claim should succeed before dispatch start"

  out=$(FM_HOME="$home" "$SCOUT" start --task foreign-review --now 1705276800 2>&1); rc=$?
  expect_code 2 "$rc" "a foreign task must not start another task's claim (got: $out)"
  metadata="$home/data/capability-scout/claim/metadata"
  assert_grep "dispatch_started=false" "$metadata" \
    "a foreign start must not change the claim's started state"

  out=$(FM_HOME="$home" "$SCOUT" start --task started-review --now 1705276800 2>&1); rc=$?
  expect_code 0 "$rc" "the claim owner should be able to start dispatch (got: $out)"
  assert_grep "dispatch_started=true" "$metadata" "dispatch start must be durable"
  assert_grep "dispatch_started_epoch=1705276800" "$metadata" \
    "dispatch start must record its epoch"
  assert_grep "dispatch_started_date=2024-01-15" "$metadata" \
    "dispatch start must record its UTC date"

  out=$(FM_HOME="$home" "$SCOUT" due --now 1705363200 2>&1); rc=$?
  expect_code 1 "$rc" "a started claim must keep due false after 24 hours in its month (got: $out)"
  assert_contains "$out" "CAPABILITY_SCOUT_DUE: false" \
    "a started claim must consume the rest of its UTC month"
  assert_contains "$out" "claim_state=started" "due must identify the started claim"

  out=$(FM_HOME="$home" "$SCOUT" claim --task retry-review --now 1705363200 2>&1); rc=$?
  expect_code 2 "$rc" "a started claim must not be stale-retaken (got: $out)"
  assert_grep "task=started-review" "$metadata" \
    "a stale-retake attempt must preserve the started claim owner"
  out=$(FM_HOME="$home" "$SCOUT" release --task started-review --now 1705363200 2>&1); rc=$?
  expect_code 2 "$rc" "a started claim must not be released (got: $out)"
  assert_grep "dispatch_started=true" "$metadata" \
    "a release attempt must preserve the started marker"

  out=$(FM_HOME="$home" "$SCOUT" due --now 1706745600 2>&1); rc=$?
  expect_code 0 "$rc" "a started claim from the previous month must not close this month (got: $out)"
  assert_contains "$out" "CAPABILITY_SCOUT_DUE: true" \
    "a new UTC month must become due after the prior started month"
  FM_HOME="$home" "$SCOUT" claim --task february-review --now 1706745600 >/dev/null 2>&1 \
    || fail "a new month should retire the previous started claim and reserve its own"
  assert_grep "last_date=2024-01-15" "$home/data/capability-scout/last-sweep" \
    "retiring the prior started claim must preserve its consumed month"
  assert_grep "task=february-review" "$metadata" \
    "the new month must receive a distinct unstarted claim"
  assert_grep "dispatch_started=false" "$metadata" \
    "a new month's claim must begin unstarted"
  pass "fm-capability-scout.sh: started claims consume one month and roll forward"
}

test_pending_claim_mtime_controls_expiry_and_recovery() {
  local home out rc claim_dir claim_meta
  home=$(new_home stale-pending-claim)
  claim_dir="$home/data/capability-scout/claim"
  mkdir -p "$claim_dir"
  touch -t 202401140000 "$claim_dir"
  out=$(FM_HOME="$home" "$SCOUT" due --now 1705363200 2>&1); rc=$?
  expect_code 0 "$rc" "an empty claim directory older than 24 hours must be due (got: $out)"
  assert_contains "$out" "CAPABILITY_SCOUT_DUE: true" "a stale pending claim must not block due"
  assert_contains "$out" "claim_state=stale" "due must report a stale pending claim"
  FM_HOME="$home" "$SCOUT" claim --task recovered-review --now 1705363200 >/dev/null 2>&1 \
    || fail "a stale pending claim should be recoverable"
  claim_meta="$home/data/capability-scout/claim/metadata"
  assert_grep "claim_epoch=1705363200" "$claim_meta" "pending claim recovery must write the new epoch"
  assert_grep "task=recovered-review" "$claim_meta" "pending claim recovery must write the new task"

  home=$(new_home fresh-pending-claim)
  claim_dir="$home/data/capability-scout/claim"
  mkdir -p "$claim_dir"
  touch -t 202401152359 "$claim_dir"
  out=$(FM_HOME="$home" "$SCOUT" due --now 1705363200 2>&1); rc=$?
  expect_code 1 "$rc" "a fresh pending claim must block due (got: $out)"
  assert_contains "$out" "CAPABILITY_SCOUT_DUE: false" "a fresh pending claim must make due false"
  assert_contains "$out" "claim_state=pending" "due must report a fresh pending claim"
  out=$(FM_HOME="$home" "$SCOUT" claim --task blocked-review --now 1705363200 2>&1); rc=$?
  expect_code 2 "$rc" "a fresh pending claim must refuse a duplicate (got: $out)"
  pass "fm-capability-scout.sh: pending claim mtime controls expiry and recovery"
}

test_mark_converts_and_clears_claim() {
  local home out rc
  home=$(new_home mark-claim)
  FM_HOME="$home" "$SCOUT" claim --task completed-review --now 1705276800 >/dev/null 2>&1 \
    || fail "claim should succeed before mark"
  out=$(FM_HOME="$home" "$SCOUT" mark --task completed-review --now 1705276800 2>&1); rc=$?
  expect_code 0 "$rc" "mark should convert a claim into an anchor (got: $out)"
  assert_absent "$home/data/capability-scout/claim" "mark must clear the claim"
  assert_grep "last_epoch=1705276800" "$home/data/capability-scout/last-sweep" \
    "mark must write the anchor after a claim"
  out=$(FM_HOME="$home" "$SCOUT" due --now 1705276800 2>&1); rc=$?
  expect_code 1 "$rc" "the marked month must no longer be due (got: $out)"
  assert_contains "$out" "claim_state=none" "mark must leave no claim state"
  pass "fm-capability-scout.sh: mark converts a claim into an anchor and clears it"
}

test_mark_requires_the_claim_owner_and_a_task() {
  local home anchor_before claim_before out rc
  home=$(new_home mark-owner)
  out=$(FM_HOME="$home" "$SCOUT" mark --now 1705276800 2>&1); rc=$?
  expect_code 2 "$rc" "mark without a task must be refused (got: $out)"
  assert_absent "$home/data/capability-scout/last-sweep" \
    "mark without a task must not create an anchor"

  FM_HOME="$home" "$SCOUT" mark --task prior-review --now 1705276800 >/dev/null 2>&1 \
    || fail "the prior-month mark should succeed"
  FM_HOME="$home" "$SCOUT" claim --task owner-review --now 1706745600 >/dev/null 2>&1 \
    || fail "the next-month claim should succeed"
  anchor_before=$(cat "$home/data/capability-scout/last-sweep")
  claim_before=$(cat "$home/data/capability-scout/claim/metadata")

  out=$(FM_HOME="$home" "$SCOUT" mark --now 1706745600 2>&1); rc=$?
  expect_code 2 "$rc" "mark without the live claim task must be refused (got: $out)"
  [ "$(cat "$home/data/capability-scout/last-sweep")" = "$anchor_before" ] \
    || fail "mark without the live claim task changed the anchor"
  [ "$(cat "$home/data/capability-scout/claim/metadata")" = "$claim_before" ] \
    || fail "mark without the live claim task changed the claim"

  out=$(FM_HOME="$home" "$SCOUT" mark --task other-review --now 1706745600 2>&1); rc=$?
  expect_code 2 "$rc" "mark by a foreign task must be refused (got: $out)"
  [ "$(cat "$home/data/capability-scout/last-sweep")" = "$anchor_before" ] \
    || fail "foreign mark changed the anchor"
  [ "$(cat "$home/data/capability-scout/claim/metadata")" = "$claim_before" ] \
    || fail "foreign mark changed the claim"
  pass "fm-capability-scout.sh: mark requires its task owner and preserves foreign state"
}

test_release_requires_the_claim_owner() {
  local home claim_before out rc
  home=$(new_home release-owner)
  FM_HOME="$home" "$SCOUT" claim --task owner-review --now 1705276800 >/dev/null 2>&1 \
    || fail "claim should succeed before owner checks"
  claim_before=$(cat "$home/data/capability-scout/claim/metadata")

  out=$(FM_HOME="$home" "$SCOUT" release --now 1705276801 2>&1); rc=$?
  expect_code 2 "$rc" "release without the live claim task must be refused (got: $out)"
  [ "$(cat "$home/data/capability-scout/claim/metadata")" = "$claim_before" ] \
    || fail "release without the live claim task changed the claim"
  out=$(FM_HOME="$home" "$SCOUT" release --task other-review --now 1705276801 2>&1); rc=$?
  expect_code 2 "$rc" "release by a foreign task must be refused (got: $out)"
  [ "$(cat "$home/data/capability-scout/claim/metadata")" = "$claim_before" ] \
    || fail "foreign release changed the claim"

  out=$(FM_HOME="$home" "$SCOUT" release --now 1705276802 2>&1); rc=$?
  expect_code 2 "$rc" "release without a task must fail while a claim exists (got: $out)"
  pass "fm-capability-scout.sh: release requires its task owner"
}

test_marked_month_refuses_a_late_claim() {
  local home out rc anchor wrapper_dir pause resume real_mkdir claim_pid waited claim_rc claim_out
  home=$(new_home mark-before-claim)
  wrapper_dir="$TMP_ROOT/mark-before-claim-mkdir"
  mkdir -p "$wrapper_dir"
  pause="$home/claim-mkdir-paused"
  resume="$home/claim-mkdir-resume"
  real_mkdir=$(command -v mkdir)
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'target=${!#}' \
    'case "$target" in' \
    '  */claim)' \
    '    : > "$FM_TEST_CLAIM_PAUSE"' \
    '    while [ ! -e "$FM_TEST_CLAIM_RESUME" ]; do sleep 0.01; done' \
    '    ;;' \
    'esac' \
    'exec "$FM_TEST_REAL_MKDIR" "$@"' > "$wrapper_dir/mkdir"
  chmod 700 "$wrapper_dir/mkdir"

  (
    set +e
    PATH="$wrapper_dir:$PATH" FM_HOME="$home" \
      FM_TEST_CLAIM_PAUSE="$pause" FM_TEST_CLAIM_RESUME="$resume" \
      FM_TEST_REAL_MKDIR="$real_mkdir" \
      "$SCOUT" claim --task competing-review --now 1705276800 >"$home/claim.out" 2>&1
    printf '%s\n' "$?" > "$home/claim.rc"
  ) &
  claim_pid=$!
  waited=0
  while [ ! -e "$pause" ] && [ "$waited" -lt 500 ]; do
    sleep 0.01
    waited=$((waited + 1))
  done
  [ -e "$pause" ] || {
    : > "$resume"
    wait "$claim_pid" || true
    fail "claim did not reach the pre-reservation pause"
  }

  out=$(FM_HOME="$home" "$SCOUT" mark --task manual-review --now 1705276800 2>&1); rc=$?
  expect_code 0 "$rc" "manual mark should complete before the paused claim resumes (got: $out)"
  anchor=$(cat "$home/data/capability-scout/last-sweep")
  : > "$resume"
  wait "$claim_pid" || true
  claim_rc=$(cat "$home/claim.rc")
  claim_out=$(cat "$home/claim.out")
  expect_code 2 "$claim_rc" "a claim losing to the completed manual mark must be refused (got: $claim_out)"
  assert_contains "$claim_out" "no longer due" "late claim refusal must identify the consumed month"
  [ "$(cat "$home/data/capability-scout/last-sweep")" = "$anchor" ] \
    || fail "a refused late claim changed the anchor"
  assert_absent "$home/data/capability-scout/claim" \
    "a refused late claim must not leave a reservation"
  pass "fm-capability-scout.sh: a completed manual mark wins over a paused competing claim"
}

test_release_does_not_delete_a_replacement_claim() {
  local home wrapper_dir pause resume real_mv release_pid waited release_rc release_out metadata out rc
  home=$(new_home release-replacement-race)
  FM_HOME="$home" "$SCOUT" claim --task original-review --now 1705276800 >/dev/null 2>&1 \
    || fail "initial stale claim should succeed"
  wrapper_dir="$TMP_ROOT/release-replacement-mv"
  mkdir -p "$wrapper_dir"
  pause="$home/release-mv-paused"
  resume="$home/release-mv-resume"
  real_mv=$(command -v mv)
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'target=${!#}' \
    'case "$target" in' \
    '  */.claim-clear.*/claim)' \
    '    : > "$FM_TEST_RELEASE_PAUSE"' \
    '    while [ ! -e "$FM_TEST_RELEASE_RESUME" ]; do sleep 0.01; done' \
    '    ;;' \
    'esac' \
    'exec "$FM_TEST_REAL_MV" "$@"' > "$wrapper_dir/mv"
  chmod 700 "$wrapper_dir/mv"

  (
    set +e
    PATH="$wrapper_dir:$PATH" FM_HOME="$home" \
      FM_TEST_RELEASE_PAUSE="$pause" FM_TEST_RELEASE_RESUME="$resume" \
      FM_TEST_REAL_MV="$real_mv" \
      "$SCOUT" release --task original-review --now 1705363200 >"$home/release.out" 2>&1
    printf '%s\n' "$?" > "$home/release.rc"
  ) &
  release_pid=$!
  waited=0
  while [ ! -e "$pause" ] && [ "$waited" -lt 500 ]; do
    sleep 0.01
    waited=$((waited + 1))
  done
  [ -e "$pause" ] || {
    : > "$resume"
    wait "$release_pid" || true
    fail "release did not reach the claim removal boundary"
  }

  FM_HOME="$home" "$SCOUT" claim --task replacement-review --now 1705363200 >/dev/null 2>&1 \
    || fail "the stale claim should be retaken before release verifies its moved copy"
  : > "$resume"
  wait "$release_pid" || true
  release_rc=$(cat "$home/release.rc")
  release_out=$(cat "$home/release.out")
  expect_code 2 "$release_rc" "release must refuse a replacement claim (got: $release_out)"
  assert_contains "$release_out" "restored the current claim" \
    "release should restore the claim it moved without verifying"
  metadata="$home/data/capability-scout/claim/metadata"
  assert_grep "task=replacement-review" "$metadata" \
    "release must preserve a replacement claim owned by another task"
  out=$(FM_HOME="$home" "$SCOUT" due --now 1705363200 2>&1); rc=$?
  expect_code 1 "$rc" "a replacement claim must continue to close due (got: $out)"
  assert_contains "$out" "CAPABILITY_SCOUT_DUE: false" \
    "the replacement claim must remain visible to due"
  out=$(FM_HOME="$home" "$SCOUT" claim --task third-review --now 1705363200 2>&1); rc=$?
  expect_code 2 "$rc" "the removed claim must not open a second reservation (got: $out)"
  pass "fm-capability-scout.sh: release removes only the claim it verified"
}

test_claim_cleanup_preflights_unexpected_contents() {
  local home out rc claim_dir
  home=$(new_home claim-cleanup)
  FM_HOME="$home" "$SCOUT" claim --task cleanup-review --now 1705276800 >/dev/null 2>&1 \
    || fail "claim should succeed before cleanup preflight"
  claim_dir="$home/data/capability-scout/claim"
  printf 'unexpected\n' > "$claim_dir/unexpected"
  out=$(FM_HOME="$home" "$SCOUT" mark --task cleanup-review --now 1705276800 2>&1); rc=$?
  expect_code 2 "$rc" "mark must refuse unexpected claim contents (got: $out)"
  assert_grep "claim_epoch=1705276800" "$claim_dir/metadata" \
    "cleanup refusal must preserve claim metadata"
  assert_grep "unexpected" "$claim_dir/unexpected" \
    "cleanup refusal must preserve unexpected claim contents"
  assert_grep "last_epoch=1705276800" "$home/data/capability-scout/last-sweep" \
    "mark must write the anchor before cleanup refusal"
  pass "fm-capability-scout.sh: claim cleanup preflights unexpected contents"
}

test_release_clears_unstarted_dispatch_claim_and_is_noop_without_one() {
  local home out rc
  home=$(new_home release-claim)
  FM_HOME="$home" "$SCOUT" claim --task unstarted-review --now 1705276800 >/dev/null 2>&1 \
    || fail "claim should succeed before release"
  out=$(FM_HOME="$home" "$SCOUT" release --task unstarted-review --now 1705276801 2>&1); rc=$?
  expect_code 0 "$rc" "release should clear a claim whose dispatch never started (got: $out)"
  assert_absent "$home/data/capability-scout/claim" "release must clear the claim"
  out=$(FM_HOME="$home" "$SCOUT" release --task unstarted-review --now 1705276802 2>&1); rc=$?
  expect_code 0 "$rc" "release without a claim must be a no-op (got: $out)"
  [ -z "$out" ] || fail "release without a claim must be silent (got: $out)"

  home=$(new_home release-empty)
  out=$(FM_HOME="$home" "$SCOUT" release --now 1705276802 2>&1); rc=$?
  expect_code 0 "$rc" "release without a claim must remain a no-op on an empty home (got: $out)"
  [ -z "$out" ] || fail "release without a claim on an empty home must be silent (got: $out)"
  assert_absent "$home/data/capability-scout" \
    "release without a claim must not create cadence state"

  home=$(new_home release-corrupt-anchor)
  mkdir -p "$home/data/capability-scout"
  printf 'last_epoch=corrupt\n' > "$home/data/capability-scout/last-sweep"
  out=$(FM_HOME="$home" "$SCOUT" release --task unstarted-review --now 1705276802 2>&1); rc=$?
  expect_code 0 "$rc" "release without a claim must ignore corrupt anchor contents (got: $out)"
  [ -z "$out" ] || fail "release with a corrupt anchor and no claim must be silent (got: $out)"
  pass "fm-capability-scout.sh: release clears an unstarted dispatch claim and is a no-op without one"
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

test_epoch_conversion_ignores_numeric_filename() {
  local home anchor
  home=$(new_home numeric-filename)
  touch "$home/1705276800"
  (
    cd "$home"
    FM_HOME="$home" "$SCOUT" mark --now 1705276800 --task filename-review >/dev/null 2>&1
  ) || fail "mark should interpret --now as an epoch when a same-named file exists"
  anchor="$home/data/capability-scout/last-sweep"
  assert_grep "last_date=2024-01-15" "$anchor" \
    "epoch conversion must not use the numeric filename's mtime"
  pass "fm-capability-scout.sh: epoch conversion ignores numeric filenames"
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
  out=$(FM_HOME="$home" "$SCOUT" claim --now 1000000001 --task wave-rejected 2>&1); rc=$?
  expect_code 2 "$rc" "claim must reject a symlinked scout directory (got: $out)"
  out=$(FM_HOME="$home" "$SCOUT" release --now 1000000001 --task wave-rejected 2>&1); rc=$?
  expect_code 2 "$rc" "release must reject a symlinked scout directory (got: $out)"
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
  out=$(FM_HOME="$home" "$SCOUT" claim --now 1000000000 --task wave-rejected 2>&1); rc=$?
  expect_code 2 "$rc" "claim must reject a non-directory scout path (got: $out)"
  out=$(FM_HOME="$home" "$SCOUT" release --now 1000000000 --task wave-rejected 2>&1); rc=$?
  expect_code 2 "$rc" "release must reject a non-directory scout path (got: $out)"
  [ "$(cat "$scout_dir")" = "$before" ] || fail "mark changed the non-directory scout path"
  pass "fm-capability-scout.sh: a non-directory scout path is refused"
}

test_claim_path_symlink_and_non_directory_are_refused() {
  local variant home out rc claim_dir target
  for variant in symlink non-directory; do
    home=$(new_home "claim-path-$variant")
    mkdir -p "$home/data/capability-scout"
    claim_dir="$home/data/capability-scout/claim"
    if [ "$variant" = symlink ]; then
      target="$TMP_ROOT/claim-path-target"
      mkdir -p "$target"
      ln -s "$target" "$claim_dir"
    else
      printf 'claim-path-sentinel\n' > "$claim_dir"
    fi
    out=$(FM_HOME="$home" "$SCOUT" due --now 1705276800 2>&1); rc=$?
    expect_code 2 "$rc" "due must reject a $variant claim path (got: $out)"
    out=$(FM_HOME="$home" "$SCOUT" claim --task rejected --now 1705276800 2>&1); rc=$?
    expect_code 2 "$rc" "claim must reject a $variant claim path (got: $out)"
    out=$(FM_HOME="$home" "$SCOUT" mark --task rejected --now 1705276800 2>&1); rc=$?
    expect_code 2 "$rc" "mark must reject a $variant claim path (got: $out)"
    out=$(FM_HOME="$home" "$SCOUT" release --task rejected --now 1705276800 2>&1); rc=$?
    expect_code 2 "$rc" "release must reject a $variant claim path (got: $out)"
  done
  pass "fm-capability-scout.sh: symlinked and non-directory claim paths are refused"
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

test_anchor_task_is_required_and_validated() {
  local home anchor out rc
  home=$(new_home anchor-task)
  anchor="$home/data/capability-scout/last-sweep"
  mkdir -p "$(dirname "$anchor")"
  printf 'last_epoch=1705276800\nlast_date=2024-01-15\n' > "$anchor"
  out=$(FM_HOME="$home" "$SCOUT" due --now 1705276801 2>&1); rc=$?
  expect_code 2 "$rc" "an anchor without a task must be refused (got: $out)"
  assert_contains "$out" "task" "missing anchor task refusal must identify the task"

  printf 'last_epoch=1705276800\nlast_date=2024-01-15\ntask=bad task\n' > "$anchor"
  out=$(FM_HOME="$home" "$SCOUT" due --now 1705276801 2>&1); rc=$?
  expect_code 2 "$rc" "an anchor with an invalid task must be refused (got: $out)"
  assert_contains "$out" "task" "invalid anchor task refusal must identify the task"
  pass "fm-capability-scout.sh: anchor tasks are required and validated"
}

test_argument_validation() {
  local home out rc
  home=$(new_home args)
  out=$(FM_HOME="$home" "$SCOUT" due --now later 2>&1); rc=$?
  expect_code 2 "$rc" "--now must reject a non-numeric epoch (got: $out)"
  out=$(FM_HOME="$home" "$SCOUT" mark --task 'bad id' 2>&1); rc=$?
  expect_code 2 "$rc" "--task must reject a non-id value (got: $out)"
  out=$(FM_HOME="$home" "$SCOUT" claim --now 1705276800 2>&1); rc=$?
  expect_code 2 "$rc" "claim must require --task (got: $out)"
  out=$(FM_HOME="$home" "$SCOUT" start --now 1705276800 2>&1); rc=$?
  expect_code 2 "$rc" "start must require --task (got: $out)"
  out=$(FM_HOME="$home" "$SCOUT" release --task 'bad id' 2>&1); rc=$?
  expect_code 2 "$rc" "release --task must reject a non-id value (got: $out)"
  out=$(FM_HOME="$home" "$SCOUT" bogus 2>&1); rc=$?
  expect_code 2 "$rc" "an unknown command must exit 2 (got: $out)"
  out=$(FM_HOME="$home" "$SCOUT" --help 2>&1); rc=$?
  expect_code 0 "$rc" "--help must exit 0 (got: $out)"
  assert_contains "$out" "claim --task <id>" "help must document claim syntax"
  assert_contains "$out" "start --task <id>" "help must document start syntax"
  assert_contains "$out" "mark --task <id>" "help must document mark syntax"
  assert_contains "$out" "release [--task <id>]" "help must document release syntax"
  assert_contains "$out" "claim --task <review-id> -> start --task <review-id> -> dispatch" \
    "help must document the dispatch-start transition"
  pass "fm-capability-scout.sh: arguments are validated"
}

test_absent_anchor_is_due
test_same_month_is_not_due_and_next_month_is_due
test_claim_records_metadata_and_closes_due
test_second_fresh_claim_is_refused
test_simultaneous_first_claims_have_one_winner
test_stale_claim_is_due_and_can_be_retaken
test_started_claim_consumes_its_month_and_rolls_forward
test_pending_claim_mtime_controls_expiry_and_recovery
test_mark_converts_and_clears_claim
test_mark_requires_the_claim_owner_and_a_task
test_release_requires_the_claim_owner
test_marked_month_refuses_a_late_claim
test_release_does_not_delete_a_replacement_claim
test_claim_cleanup_preflights_unexpected_contents
test_release_clears_unstarted_dispatch_claim_and_is_noop_without_one
test_leading_zero_epoch_is_normalized
test_epoch_conversion_ignores_numeric_filename
test_december_to_january_is_due
test_weekly_checks_across_several_months
test_out_of_range_now_is_refused
test_out_of_range_stored_epoch_is_refused
test_corrupt_anchor_fails_loud
test_symlinked_anchor_is_refused
test_symlinked_scout_dir_is_refused
test_non_directory_scout_path_is_refused
test_claim_path_symlink_and_non_directory_are_refused
test_empty_anchor_is_refused
test_missing_epoch_anchor_is_refused
test_invalid_last_date_is_refused
test_anchor_task_is_required_and_validated
test_argument_validation

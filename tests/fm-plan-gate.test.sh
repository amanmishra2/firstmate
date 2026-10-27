#!/usr/bin/env bash
# Behavior tests for the default-off plan definition-of-ready gate.
#
# Three surfaces are covered, in the order a dispatch reaches them:
#   1. bin/fm-plan-gate.sh decides on/off from FM_PLAN_GATE and config/plan-gate;
#   2. the gate refuses an incomplete plan with the linter's exact rule id,
#      file, and line, and accepts a complete one;
#   3. bin/fm-spawn.sh refuses a ship whose brief points at an incomplete plan,
#      before any worktree or endpoint is created, and still records the
#      resolved plan reference when the gate is off.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

ROOT=${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
GATE="$ROOT/bin/fm-plan-gate.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
FIXTURES="$ROOT/tests/fixtures/plan-lint"
TMP_ROOT=$(fm_test_tmproot fm-plan-gate)

make_home() {
  local home=$1
  mkdir -p "$home/config" "$home/data" "$home/state" "$home/projects"
  cp "$FIXTURES/registry.yaml" "$home/data/plan-contracts.yaml"
  cp "$FIXTURES/ledger.jsonl" "$home/data/ledger.jsonl"
  mkdir -p "$home/data/prevention-ledger"
  cp "$FIXTURES/ledger.jsonl" "$home/data/prevention-ledger/runs.jsonl"
  cp -R "$FIXTURES/repo" "$home/projects/fixture-repo"
}

write_plan() { # <home> <task> <source>
  local home=$1 id=$2 source=$3
  mkdir -p "$home/data/$id"
  cp "$source" "$home/data/$id/PLAN.md"
}

write_brief() { # <home> <task> <plan-line>
  local home=$1 id=$2 plan_line=$3
  mkdir -p "$home/data/$id"
  cat >"$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise the plan gate.

## Firstmate spec
Ship the fixture plan.

# Setup
Plan: $plan_line

# Rules
1. Fixture rule.
EOF
}

run_gate() { # <home> <task> [extra env assignments...]
  local home=$1 id=$2
  shift 2
  env FM_HOME="$home" "$@" "$GATE" --brief "$home/data/$id/brief.md" --task "$id" 2>&1
}

# --- flag resolution -------------------------------------------------------

test_status_default_off() {
  local home rc out
  home="$TMP_ROOT/home-status"
  make_home "$home"
  out=$(FM_HOME="$home" "$GATE" --status)
  rc=$?
  [ "$rc" -eq 0 ] || fail "status should exit 0"
  [ "$out" = off ] || fail "status should be off by default, got '$out'"
  printf 'on\n' >"$home/config/plan-gate"
  out=$(FM_HOME="$home" "$GATE" --status)
  [ "$out" = on ] || fail "config/plan-gate=on should enable the gate, got '$out'"
  out=$(FM_HOME="$home" FM_PLAN_GATE=0 "$GATE" --status)
  [ "$out" = off ] || fail "FM_PLAN_GATE=0 should override config/plan-gate, got '$out'"
  printf 'maybe\n' >"$home/config/plan-gate"
  out=$(FM_HOME="$home" "$GATE" --status 2>&1)
  [ $? -eq 2 ] || fail "a malformed config/plan-gate must exit 2, got: $out"
  printf '%s\n' "$out" | grep -F "unrecognized value 'maybe'" >/dev/null \
    || fail "malformed config must name the bad value, got: $out"
  pass "the gate is off by default, on via config/plan-gate or FM_PLAN_GATE, and refuses a malformed value"
}

# --- gate decisions --------------------------------------------------------

test_gate_refuses_incomplete_plan() {
  local home out rc
  home="$TMP_ROOT/home-refuse"
  make_home "$home"
  write_plan "$home" gate-refuse "$FIXTURES/good-slice.md"
  write_brief "$home" gate-refuse "data/gate-refuse/PLAN.md"
  # Seeded gap 1: no runnable acceptance bullet for A2.
  sed -i.bak '/^- \*\*A2\*\*/d' "$home/data/gate-refuse/PLAN.md"
  rm -f "$home/data/gate-refuse/PLAN.md.bak"
  out=$(run_gate "$home" gate-refuse FM_PLAN_GATE=1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "the gate must exit 1 for an incomplete plan, got $rc: $out"
  printf '%s\n' "$out" | grep -F 'PL003' >/dev/null || fail "refusal must name PL003: $out"
  printf '%s\n' "$out" | grep -F 'A2' >/dev/null || fail "refusal must name the missing acceptance A2: $out"
  printf '%s\n' "$out" | grep -F 'PLAN.md:' >/dev/null || fail "refusal must name the file and line: $out"
  pass "the gate refuses a plan whose acceptance command is missing, naming PL003, the id, and the location"
}

test_gate_refuses_missing_section_and_draft() {
  local home out rc
  home="$TMP_ROOT/home-sections"
  make_home "$home"
  write_plan "$home" gate-sections "$FIXTURES/good-slice.md"
  write_brief "$home" gate-sections "data/gate-sections/PLAN.md"
  sed -i.bak 's/^status: ready$/status: draft/' "$home/data/gate-sections/PLAN.md"
  rm -f "$home/data/gate-sections/PLAN.md.bak"
  out=$(run_gate "$home" gate-sections FM_PLAN_GATE=1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "a draft plan must be refused, got $rc: $out"
  printf '%s\n' "$out" | grep -F 'PL011' >/dev/null || fail "draft refusal must name PL011: $out"
  pass "the gate refuses a draft plan with PL011"
}

test_gate_accepts_complete_plan() {
  local home out rc
  home="$TMP_ROOT/home-accept"
  make_home "$home"
  write_plan "$home" gate-accept "$FIXTURES/good-slice.md"
  write_brief "$home" gate-accept "data/gate-accept/PLAN.md"
  out=$(run_gate "$home" gate-accept FM_PLAN_GATE=1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "a complete plan must pass the gate, got $rc: $out"
  case "$out" in
    */data/gate-accept/PLAN.md) ;;
    *) fail "the gate must print the resolved plan path, got: $out" ;;
  esac
  pass "the gate accepts a complete plan and prints the reference it gated"
}

test_gate_off_records_reference_without_linting() {
  local home out rc
  home="$TMP_ROOT/home-off"
  make_home "$home"
  write_plan "$home" gate-off "$FIXTURES/good-slice.md"
  write_brief "$home" gate-off "data/gate-off/PLAN.md"
  sed -i.bak 's/^status: ready$/status: draft/' "$home/data/gate-off/PLAN.md"
  rm -f "$home/data/gate-off/PLAN.md.bak"
  out=$(run_gate "$home" gate-off)
  rc=$?
  [ "$rc" -eq 0 ] || fail "the gate must not refuse while it is off, got $rc: $out"
  case "$out" in
    */data/gate-off/PLAN.md) ;;
    *) fail "off must still resolve the reference for the record, got: $out" ;;
  esac
  pass "an off gate resolves the plan reference and does not lint it"
}

test_gate_refuses_brief_without_plan() {
  local home out rc
  home="$TMP_ROOT/home-noplan"
  make_home "$home"
  write_brief "$home" gate-noplan "none"
  out=$(run_gate "$home" gate-noplan FM_PLAN_GATE=1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "an enabled gate must refuse a brief with no plan, got $rc: $out"
  printf '%s\n' "$out" | grep -F 'no plan reference' >/dev/null || fail "refusal must say the brief has no plan: $out"
  out=$(run_gate "$home" gate-noplan)
  rc=$?
  [ "$rc" -eq 0 ] || fail "an off gate must accept a brief with no plan, got $rc: $out"
  pass "an enabled gate refuses a brief with no plan reference; an off gate accepts it"
}

test_gate_refuses_missing_plan_file() {
  local home out rc
  home="$TMP_ROOT/home-missing"
  make_home "$home"
  write_brief "$home" gate-missing "data/gate-missing/PLAN.md"
  out=$(run_gate "$home" gate-missing FM_PLAN_GATE=1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "a missing plan file must be refused, got $rc: $out"
  printf '%s\n' "$out" | grep -F 'does not exist' >/dev/null || fail "refusal must say the plan is missing: $out"
  pass "an enabled gate refuses a plan path that does not exist"
}

# --- the real dispatch path ------------------------------------------------

test_spawn_refuses_incomplete_plan() {
  local home proj fakebin out rc id
  id=plan-gate-spawn-refuse
  home="$TMP_ROOT/home-spawn-refuse"
  make_home "$home"
  proj="$home/projects/fixture-repo"
  git -C "$proj" init -q
  git -C "$proj" config user.email fixture@example.test
  git -C "$proj" config user.name fixture
  git -C "$proj" add -A
  git -C "$proj" commit -qm init
  write_plan "$home" "$id" "$FIXTURES/good-slice.md"
  write_brief "$home" "$id" "data/$id/PLAN.md"
  sed -i.bak '/^- \*\*A1\*\*/d' "$home/data/$id/PLAN.md"
  rm -f "$home/data/$id/PLAN.md.bak"
  fakebin=$(fm_test_make_spawn_fakebin "$TMP_ROOT/fake-refuse")
  out=$(FM_PLAN_GATE=1 fm_test_run_spawn "$home" "$proj" "$fakebin" "$id" "$proj" --mode direct-PR --yolo off)
  rc=$?
  [ "$rc" -ne 0 ] || fail "the spawn must fail on an incomplete plan, got: $out"
  printf '%s\n' "$out" | grep -F 'plan-gate: refused' >/dev/null \
    || fail "the spawn refusal must come from the plan gate: $out"
  printf '%s\n' "$out" | grep -F 'PL003' >/dev/null || fail "the refusal must name PL003: $out"
  printf '%s\n' "$out" | grep -F 'A1' >/dev/null || fail "the refusal must name the missing A1: $out"
  [ ! -e "$home/state/$id.meta" ] || fail "a refused spawn must not write a task record"
  pass "fm-spawn refuses an incomplete plan before any worktree or record exists, naming PL003 and A1"
}

test_spawn_accepts_complete_plan_and_records_it() {
  local home proj wt fakebin out rc id
  id=plan-gate-spawn-accept
  home="$TMP_ROOT/home-spawn-accept"
  make_home "$home"
  proj="$home/projects/fixture-repo"
  wt="$TMP_ROOT/wt-spawn-accept"
  fm_git_worktree "$proj" "$wt" "wt-plan-gate-accept"
  fakebin=$(fm_test_make_spawn_fakebin "$TMP_ROOT/fake-accept" pi)
  printf 'pi\n' >"$home/config/crew-harness"
  write_plan "$home" "$id" "$FIXTURES/good-slice.md"
  write_brief "$home" "$id" "data/$id/PLAN.md"
  out=$(FM_PLAN_GATE=1 fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode direct-PR --yolo off)
  rc=$?
  printf '%s\n' "$out" | grep -F 'plan-gate: refused' >/dev/null \
    && fail "a complete plan must not be refused by the gate: $out"
  [ "$rc" -eq 0 ] || fail "a complete plan must let the spawn proceed (exit $rc): $out"
  grep -qx "plan_ref=$home/data/$id/PLAN.md" "$home/state/$id.meta" \
    || fail "the task record must carry the gated plan reference: $(cat "$home/state/$id.meta" 2>/dev/null)"
  pass "fm-spawn passes a complete plan through the gate and records plan_ref in the task record"
}

test_spawn_calls_the_gate_before_creating_anything() {
  local gate_line worktree_line
  gate_line=$(grep -n 'fm-plan-gate.sh' "$SPAWN" | head -n 1 | cut -d: -f1)
  worktree_line=$(grep -n 'treehouse get' "$SPAWN" | head -n 1 | cut -d: -f1)
  [ -n "$gate_line" ] || fail "fm-spawn must call the plan gate"
  [ -n "$worktree_line" ] || fail "fixture drifted: no treehouse lease line in fm-spawn.sh"
  [ "$gate_line" -lt "$worktree_line" ] \
    || fail "the plan gate must run before the worktree lease ($gate_line vs $worktree_line)"
  pass "fm-spawn calls the plan gate before it leases a worktree"
}


test_promote_records_the_plan_reference() {
  local home id brief out rc
  id=plan-gate-promote
  home="$TMP_ROOT/home-promote"
  make_home "$home"
  printf 'window=fmses:fm-%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nharness=claude\nkind=scout\n' \
    "$id" "$id" "$TMP_ROOT/wt-promote" "$home/projects/fixture-repo" >"$home/state/$id.meta"
  mkdir -p "$home/data/$id"
  cat >"$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
[Captain] Promote the scout to the plan's slice.

## Firstmate spec
Promote the fixture task.

# Setup
This is a SCOUT task: the deliverable is a written report, not a PR.
EOF
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-promote.sh" "$id" \
    --mode direct-PR --yolo off --plan-ref data/$id/PLAN.md 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "a scout promotion with --plan-ref must succeed: $out"
  brief="$home/data/$id/brief.md"
  grep -qx "Plan: data/$id/PLAN.md" "$brief" \
    || fail "the promoted brief must carry the plan reference: $(grep '^Plan: ' "$brief")"
  grep -qx "plan_ref=data/$id/PLAN.md" "$home/state/$id.meta" \
    || fail "the promoted task record must carry plan_ref: $(cat "$home/state/$id.meta")"
  grep -qx 'Plan: none' "$home/data/$id/brief.md" \
    && fail "the promoted brief must not also render Plan: none"
  pass "fm-promote records the plan reference in the promoted brief and task record"
}

fm_test_run \
  test_status_default_off \
  test_gate_refuses_incomplete_plan \
  test_gate_refuses_missing_section_and_draft \
  test_gate_accepts_complete_plan \
  test_gate_off_records_reference_without_linting \
  test_gate_refuses_brief_without_plan \
  test_gate_refuses_missing_plan_file \
  test_spawn_calls_the_gate_before_creating_anything \
  test_spawn_refuses_incomplete_plan \
  test_spawn_accepts_complete_plan_and_records_it \
  test_promote_records_the_plan_reference

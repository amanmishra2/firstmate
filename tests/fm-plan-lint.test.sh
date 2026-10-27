#!/usr/bin/env bash
# Behavior tests for bin/fm-plan-lint.py.
#
# The rule matrix lives in tests/test_plan_lint.py (stdlib unittest, one seeded
# failure and one fixed plan per rule). This wrapper is what the repo's test
# runner discovers, and it adds the shell-level contract the Python suite cannot
# see: the CLI's exit codes, its JSON envelope, and the fact that the linter
# stays dependency-free and never writes to the plan it reads.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LINTER="$ROOT/bin/fm-plan-lint.py"
FIXTURES="$ROOT/tests/fixtures/plan-lint"
TMP_ROOT=$(fm_test_tmproot fm-plan-lint)

test_python_suite() {
  local out
  out=$(cd "$ROOT" && python3 tests/test_plan_lint.py 2>&1)
  local rc=$?
  printf '%s\n' "$out" | tail -n 3
  [ "$rc" -eq 0 ] || fail "tests/test_plan_lint.py failed:
$out"
  pass "every rule fails on its seeded gap and passes on the fixed plan"
}

test_cli_contract() {
  local out rc before after
  before=$(cksum "$FIXTURES/good-slice.md")
  out=$("$LINTER" "$FIXTURES/good-slice.md" \
    --contracts "$FIXTURES/registry.yaml" \
    --ledger "$FIXTURES/ledger.jsonl" \
    --home "$FIXTURES" 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "a good plan must lint clean, got $rc: $out"
  printf '%s\n' "$out" | grep -F 'plan-lint: plans=1 errors=0 warnings=0' >/dev/null \
    || fail "text output must end with the summary line: $out"

  out=$("$LINTER" "$FIXTURES/good-slice.md" \
    --contracts "$FIXTURES/registry.yaml" \
    --ledger "$FIXTURES/ledger.jsonl" \
    --home "$FIXTURES" --json)
  printf '%s\n' "$out" | python3 -c '
import json, sys
doc = json.load(sys.stdin)
assert doc["schema"] == "fm-plan-lint.v1", doc["schema"]
assert doc["ok"] is True
assert doc["findings"] == []
assert doc["summary"]["plans"] == 1
' || fail "the JSON envelope is not stable: $out"

  out=$("$LINTER" "$TMP_ROOT/absent.md" 2>&1)
  rc=$?
  [ "$rc" -eq 2 ] || fail "a missing path must exit 2, got $rc: $out"

  out=$("$LINTER" --rules)
  rc=$?
  [ "$rc" -eq 0 ] || fail "--rules must exit 0, got $rc"
  for rule in PL001 PL002 PL003 PL004 PL005 PL006 PL007 PL008 PL009 PL010 PL011 PL012; do
    printf '%s\n' "$out" | grep -F "$rule " >/dev/null || fail "--rules must list $rule"
  done
  after=$(cksum "$FIXTURES/good-slice.md")
  [ "$before" = "$after" ] || fail "the linter must never write to a plan"
  pass "CLI exit codes, JSON envelope, and rule listing are stable, and the plan is untouched"
}

test_stdlib_only() {
  local imports
  imports=$(sed -n 's/^import \([a-z_]*\)$/\1/p; s/^from \([a-z_]*\) import.*$/\1/p' "$LINTER")
  local module stdlib
  stdlib=$(python3 - <<'PY'
import sys
print(" ".join(sorted(sys.stdlib_module_names)))
PY
)
  for module in $imports; do
    case " $stdlib " in
      *" $module "*) ;;
      *) fail "bin/fm-plan-lint.py imports non-stdlib module '$module'" ;;
    esac
  done
  pass "the linter imports only the standard library"
}

fm_test_run test_python_suite test_cli_contract test_stdlib_only

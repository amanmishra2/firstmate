#!/usr/bin/env bash
# Definition-of-ready gate for a dispatch: resolve the plan a brief names and,
# when the gate is enabled, refuse the dispatch unless that plan lints clean.
#
# Usage: fm-plan-gate.sh --brief <brief-path> [--task <task-id>]
#        fm-plan-gate.sh --plan <plan-path>
#        fm-plan-gate.sh --status
#
#   --brief is how bin/fm-spawn.sh calls it: the plan reference comes from the
#   brief's `Plan: <ref>` line, which bin/fm-brief.sh --plan-ref writes. On
#   success this prints the resolved reference on stdout - empty when the brief
#   records `Plan: none` - so the caller records the same value it gated.
#   --task is used only for the refusal message.
#
#   --plan lints one plan file directly with the same readiness requirement, for
#   an author checking a draft before dispatch. It lints whether or not this
#   home has the dispatch gate switched on, because an explicit --plan is a
#   request for the check.
#
#   --status prints `on` or `off` and exits 0; it never lints.
#
# The gate is DEFAULT OFF. `bin/fm-spawn.sh` reads config/plan-gate, or the
# FM_PLAN_GATE override, and this script owns that resolution:
#   FM_PLAN_GATE=1|on|true   on for this call
#   FM_PLAN_GATE=0|off|false off for this call
#   else                     config/plan-gate: `on` or `off`
#   no file and no override  off
# A malformed value is an error (exit 2), never a silent fallback: a gate that
# quietly turns itself off is worse than no gate.
#
# What a refusal means: the plan is missing a required section, has an
# unspecified instruction, has an acceptance criterion that is not a runnable
# command with an expected result, names a table/field/flag/command that is not
# in data/plan-contracts.yaml, cites no prevention-ledger finding, disagrees
# with itself about effort or dependencies, points at a stale path or line, has
# no actionable rollback, or is still `draft`. Every refusal prints the linter's
# own rule id, file, line, and message, so the fix is in the refusal text.
#
# Ownership: bin/fm-plan-lint.py owns the rules; docs/plan-lifecycle.md owns who
# fixes what at each handoff; bin/fm-brief.sh owns the brief line.

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
LINTER="$SCRIPT_DIR/fm-plan-lint.py"

die() {
  echo "error: $*" >&2
  exit 2
}

usage() {
  # Print the header comment only: every leading comment line after line 1.
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}" >&2
}

BRIEF=
TASK=
PLAN=
MODE=brief

while [ $# -gt 0 ]; do
  case $1 in
    --brief)
      [ $# -ge 2 ] || die "--brief needs a path"
      BRIEF=$2
      shift 2
      ;;
    --task)
      [ $# -ge 2 ] || die "--task needs an id"
      TASK=$2
      shift 2
      ;;
    --plan)
      [ $# -ge 2 ] || die "--plan needs a path"
      PLAN=$2
      MODE=plan
      shift 2
      ;;
    --status)
      MODE=status
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      die "unknown argument: $1"
      ;;
  esac
done

[ -n "${FM_HOME:-}" ] && HOME_DIR=$FM_HOME || HOME_DIR=$(cd "$SCRIPT_DIR/.." && pwd -P)
CONFIG="$HOME_DIR/config"

# fm_plan_gate_enabled: 0 on, 1 off, 2 malformed configuration.
fm_plan_gate_enabled() {
  local value=${FM_PLAN_GATE:-} source=FM_PLAN_GATE
  if [ -z "$value" ]; then
    if [ ! -e "$CONFIG/plan-gate" ]; then
      return 1
    fi
    source=$CONFIG/plan-gate
    value=$(tr -d '[:space:]' <"$CONFIG/plan-gate" 2>/dev/null) || die "cannot read $CONFIG/plan-gate"
  fi
  case $value in
    1 | on | true | yes) return 0 ;;
    0 | off | false | no | '') return 1 ;;
  esac
  echo "error: plan gate is configured with an unrecognized value '${value}' (from $source); use 'on' or 'off'" >&2
  return 2
}

if [ "$MODE" = status ]; then
  rc=0
  fm_plan_gate_enabled || rc=$?
  case $rc in
    0) echo on ;;
    1) echo off ;;
    *) exit 2 ;;
  esac
  exit 0
fi

# Resolve the plan reference. Absolute paths are used as-is; a relative one is
# tried against the firstmate home first and then the caller's directory, which
# is the two places a brief can reasonably mean.
resolve_plan() {
  local ref=$1 candidate
  case $ref in
    /*) printf '%s\n' "$ref"; return 0 ;;
  esac
  for candidate in "$HOME_DIR/$ref" "$PWD/$ref"; do
    if [ -e "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  printf '%s\n' "$HOME_DIR/$ref"
}

if [ "$MODE" = plan ]; then
  [ -n "$PLAN" ] || die "--plan needs a path"
  [ -e "$PLAN" ] || die "plan $PLAN does not exist"
  PLAN_ABS=$(cd "$(dirname "$PLAN")" && pwd -P)/$(basename "$PLAN")
  LABEL=${TASK:-$PLAN_ABS}
else
  [ -n "$BRIEF" ] || { usage; die "--brief is required"; }
  [ -f "$BRIEF" ] || die "brief $BRIEF does not exist"
  BRIEF_REF=$(sed -n 's/^Plan: \(.*\)$/\1/p' "$BRIEF" | head -n 1)
  case ${BRIEF_REF:-none} in
    '' | none | -) BRIEF_REF= ;;
  esac
  LABEL=${TASK:-$(basename "$(dirname "$BRIEF")")}
  if [ -z "$BRIEF_REF" ]; then
    rc=0
    fm_plan_gate_enabled || rc=$?
    case $rc in
      0)
        echo "plan-gate: refused ${LABEL}: the brief records no plan reference" >&2
        echo "plan-gate: add 'Plan: <path to plan>' under '# Setup' (bin/fm-brief.sh --plan-ref), or set config/plan-gate off to dispatch without the gate" >&2
        exit 1
        ;;
      1) exit 0 ;;
      *) exit 2 ;;
    esac
  fi
  PLAN_ABS=$(resolve_plan "$BRIEF_REF")
fi

if [ "$MODE" = plan ]; then
  # An explicit --plan is an author asking for the check, so it lint
  # regardless of whether this home gates dispatches yet.
  GATE_ON=1
else
  rc=0
  fm_plan_gate_enabled || rc=$?
  case $rc in
    0) GATE_ON=1 ;;
    1) GATE_ON=0 ;;
    *) exit 2 ;;
  esac
fi

if [ "$GATE_ON" = 0 ]; then
  # Off means off: the reference is still resolved and printed so the task
  # record can carry it, and the plan itself is not read.
  [ "$MODE" = plan ] && exit 0
  printf '%s\n' "$PLAN_ABS"
  exit 0
fi

if [ ! -f "$PLAN_ABS" ]; then
  echo "plan-gate: refused ${LABEL}: plan ${PLAN_ABS} does not exist" >&2
  echo "plan-gate: correct the brief's 'Plan:' line, or write the plan first (templates/implementation-plan/PLAN_TEMPLATE.md)" >&2
  exit 1
fi

[ -f "$LINTER" ] || die "linter $LINTER is missing"
PY=python3
command -v "$PY" >/dev/null 2>&1 || die "python3 is required to lint a plan"

LINT_ARGS=("$PLAN_ABS" --home "$HOME_DIR" --require-ready --quiet)

if ! LINT_OUT=$("$PY" "$LINTER" "${LINT_ARGS[@]}" 2>&1); then
  echo "plan-gate: refused ${LABEL}: plan ${PLAN_ABS} is not ready to dispatch" >&2
  printf '%s\n' "$LINT_OUT" | sed '/^$/d; s/^/plan-gate: /' >&2
  echo "plan-gate: fix every finding above, then run: ${SCRIPT_DIR}/fm-plan-lint.py ${PLAN_ABS} --home ${HOME_DIR} --require-ready" >&2
  exit 1
fi

[ "$MODE" = plan ] && exit 0
printf '%s\n' "$PLAN_ABS"
exit 0

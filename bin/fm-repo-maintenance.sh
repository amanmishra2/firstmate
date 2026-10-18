#!/usr/bin/env bash
# fm-repo-maintenance.sh - aggregate session metrics, rank token heat, audit
# repository structure, and compose a weekly maintenance report.
#
# Usage:
#   fm-repo-maintenance.sh mine [--now EPOCH]
#   fm-repo-maintenance.sh rank [--metrics PATH] [--project NAME] [--top N] [--json]
#   fm-repo-maintenance.sh structure <root-dir> [--max-findings N] [--json]
#   fm-repo-maintenance.sh sweep <project> [--date YYYY-MM-DD] [--max-findings N] [--force]
#   fm-repo-maintenance.sh --help
#
# mine always scans the fixed seven-day window and both structured sources and
# writes aggregate-only metrics to data/repo-maintenance/metrics/<UTC-date>.json.
# OpenCode contributes named tool read events; Codex and shell-mediated reads
# have no file attribution and are excluded. Paths are stable labels or a
# placeholder, and session identifiers stay transient join keys.
#
# Exit codes: 0 ok, 2 usage or refusal, 1 runtime failure.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LIB_DIR="$SCRIPT_DIR/lib"

# shellcheck source=bin/lib/fm-repo-maintenance-common.sh
. "$LIB_DIR/fm-repo-maintenance-common.sh"
# shellcheck source=bin/lib/fm-repo-maintenance-mine.sh
. "$LIB_DIR/fm-repo-maintenance-mine.sh"
# shellcheck source=bin/lib/fm-repo-maintenance-rank.sh
. "$LIB_DIR/fm-repo-maintenance-rank.sh"
# shellcheck source=bin/lib/fm-repo-maintenance-structure.sh
. "$LIB_DIR/fm-repo-maintenance-structure.sh"
# shellcheck source=bin/lib/fm-repo-maintenance-sweep.sh
. "$LIB_DIR/fm-repo-maintenance-sweep.sh"

rm_usage() {
  cat <<'EOF'
Usage:
  fm-repo-maintenance.sh mine [--now EPOCH]
  fm-repo-maintenance.sh rank [--metrics PATH] [--project NAME] [--top N] [--json]
  fm-repo-maintenance.sh structure <root-dir> [--max-findings N] [--json]
  fm-repo-maintenance.sh sweep <project> [--date YYYY-MM-DD] [--max-findings N] [--force]
  fm-repo-maintenance.sh --help

mine writes aggregate session metrics for the fixed seven-day, all-source window.
rank prints the repeat-read Token Heat Index from the newest metrics.
structure audits a git work tree against the structure standard (read-only).
sweep composes data/repo-maintenance/<project>/<date>/report.md.
EOF
}

case "${1:-}" in
  mine) shift; rm_run_mine "$@" ;;
  rank) shift; rm_run_rank "$@" ;;
  structure) shift; rm_run_structure "$@" ;;
  sweep) shift; rm_run_sweep "$@" ;;
  --help|-h|"") rm_usage ;;
  *) rm_die_usage "unknown command '${1:-}'" ;;
esac

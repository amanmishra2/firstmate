#!/usr/bin/env bash
# Compose the bounded instrument sections of a dated maintenance report.

SWEEP_PROJECT=""
SWEEP_DATE=""
SWEEP_MAX=$DEFAULT_MAX_FINDINGS

rm_parse_sweep_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --date)
        [ "$#" -ge 2 ] || rm_die_usage "--date requires YYYY-MM-DD"
        SWEEP_DATE=$2
        shift 2
        ;;
      --max-findings)
        [ "$#" -ge 2 ] || rm_die_usage "--max-findings requires a count"
        case "$2" in ''|*[!0-9]*) rm_die_usage "--max-findings must be a count" ;; esac
        SWEEP_MAX=$2
        shift 2
        ;;
      -* ) rm_die_usage "unknown argument '$1'" ;;
      *)
        [ -z "$SWEEP_PROJECT" ] || rm_die_usage "sweep takes exactly one project"
        SWEEP_PROJECT=$1
        shift
        ;;
    esac
  done
  [ -n "$SWEEP_PROJECT" ] || rm_die_usage "sweep requires a project name"
  case "$SWEEP_PROJECT" in
    /*|*/*|.|..|*..*|*[!A-Za-z0-9_-]*) rm_die_usage "invalid project name" ;;
  esac
  case "$SWEEP_DATE" in
    "") ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) rm_die_usage "--date must be YYYY-MM-DD" ;;
  esac
}

rm_registered_project_root() {
  local name=$1 registry="$DATA/projects.md" line rest entry found=0
  if [ "$name" = firstmate ]; then
    printf '%s\n' "$FM_ROOT"
    return 0
  fi
  [ -f "$registry" ] || return 1
  while IFS= read -r line; do
    case "$line" in -* ) ;; *) continue ;; esac
    rest=${line#- }
    case "$rest" in
      *" ["*) entry=${rest%% \[*} ;;
      *" - "*) entry=${rest%% - *} ;;
      *) continue ;;
    esac
    if [ "$entry" = "$name" ]; then found=1; break; fi
  done < "$registry"
  [ "$found" -eq 1 ] || return 1
  printf '%s\n' "$PROJECTS/$name"
}

rm_render_rank_report() {
  local rank_json=$1
  printf '%s' "$rank_json" | jq -r '
    "| # | file | reads | tasks | re-reads | tokens | lines | THI | flags |",
    "|---|------|-------|-------|----------|--------|-------|-----|-------|",
    (.files | to_entries[] |
      [ (.key + 1 | tostring), ("`" + .value.scope + "/" + .value.path + "`"),
        (.value.reads | tostring), (.value.tasks | tostring), (.value.reread_reads | tostring),
        (.value.tokens | tostring), (if .value.lines == null then "-" else (.value.lines | tostring) end),
        (.value.thi | tostring),
        ([ (if .value.prioritized then "prioritized" else empty end),
           (if .value.nav then empty else "no-nav" end),
           (if .value.size_source == "observed" then "stale" else empty end) ] | join(", "))
      ] | "| " + join(" | ") + " |")'
}

rm_run_sweep() {
  rm_parse_sweep_args "$@"
  rm_require_jq
  rm_init_roots
  rm_init_tmp_root || rm_die_fail "cannot create a temp dir"
  local root date outdir report metrics rank_json structure_json tmp_report fix
  root=$(rm_registered_project_root "$SWEEP_PROJECT" 2>/dev/null || true)
  [ -n "$root" ] || rm_die_refuse "unknown project (not in $(rm_sanitize_path "$DATA/projects.md") and not 'firstmate')"
  root=$(rm_physical_dir "$root" 2>/dev/null || true)
  [ -n "$root" ] || rm_die_refuse "project root missing"
  if [ "$SWEEP_PROJECT" != firstmate ]; then
    if [ -z "$RM_APPROVED_HOME" ] || ! rm_path_under "$root" "$RM_APPROVED_HOME"; then
      rm_die_refuse "project root outside approved home"
    fi
  fi
  date=${SWEEP_DATE:-$(date -u +%Y-%m-%d)}
  outdir="$RM_DATA/$SWEEP_PROJECT/$date"
  report="$outdir/report.md"
  if [ -e "$report" ] || [ -L "$report" ]; then
    rm_die_refuse "report already exists: $(rm_sanitize_path "$report")"
  fi

  metrics=$(rm_latest_metrics 2>/dev/null || true)
  rank_json=""
  if [ -n "$metrics" ]; then
    rank_json=$(rm_run_rank_json "$metrics" "$SWEEP_PROJECT" 15 2>/dev/null || true)
  fi
  structure_json=$(rm_structure_json "$root" "$SWEEP_MAX" "$SWEEP_PROJECT") || exit $?

  if ! mkdir -p -- "$outdir"; then rm_die_fail "cannot create report directory"; fi
  tmp_report=$(mktemp "$outdir/.report.XXXXXX") || rm_die_fail "cannot create report temp file"
  if ! (
    set -e
    {
      printf '# Repo maintenance sweep - %s - %s\n\n' "$SWEEP_PROJECT" "$date"
    cat <<'EOF'
Instrument: `bin/fm-repo-maintenance.sh` (schema `fm-repo-maintenance-report.v1`).
Report shape: `.agents/skills/repo-maintenance/references/audit-playbook.md` owns the section contract;
complete the pending sections through the maintenance pass before acting on this report.

## Coverage

EOF
    printf -- "- Structure root: \`%s\`\n" "$(rm_sanitize_path "$root")"
    if [ -n "$metrics" ]; then
      printf -- "- Metrics: \`%s\`\n" "$(rm_sanitize_path "$metrics")"
      jq -r '"  - Window: \(.window.start) to \(.window.end) (\(.window.days) days); tasks mined: \(.tasks | length)"' "$metrics" 2>/dev/null
      jq -r '.coverage[] | "  - \(.source): \(.status), sessions mined \(.sessions_mined) of \(.sessions_seen) seen (cap \(.skipped_cap), empty \(.skipped_empty), error \(.skipped_error), out of scope \(.skipped_scope // 0))"' "$metrics" 2>/dev/null
    else
      printf -- "- Metrics: none; run \`bin/fm-repo-maintenance.sh mine\` before the next sweep.\n"
    fi
    cat <<'EOF'
- File coverage includes only tool-attributed named `read` events. Codex and shell-mediated reads are excluded, so absent or zero file rows do not measure inactivity for those paths.
- First edit timing includes only named edit tools (`edit`, `write`, `patch`, `apply_patch` for OpenCode; `apply_patch`, `write` for Codex). Shell-mediated edits are excluded.
EOF
    jq -r --argjson lines "$SOFT_CEILING_LINES" '
      "- Structure totals: files over \($lines) lines \(.files_over_ceiling.total) (exempt \(.files_over_ceiling.exempt)); depth violations \(.depth_violations.total); dirs missing SUMMARY.md \(.dirs_missing_summary.total) of \(.dirs_missing_summary.dirs); summary gaps \(.summary_gaps.total); invalid summaries \(.summary_invalid.total); over-long summaries \(.summary_over_limit.total); entrypoints ok=\(.entrypoints.ok)"' <<<"$structure_json" 2>/dev/null
    printf '\n'

    printf '## Token heat ranking (instrument)\n\n'
    if [ -n "$rank_json" ]; then
      rm_render_rank_report "$rank_json"
      printf '\nFix next (top prioritized):\n'
      jq -r 'if (.fix_next | length) == 0 then "- none this window" else ([.fix_next[] | "- `\(.scope)/\(.path)` (THI \(.thi), repeat reads \(.reread_reads), lines \(.lines // "?"))"] | join("\n")) end' <<<"$rank_json"
      printf '\nHottest folders:\n'
      jq -r '.folders[] | "- `\(.scope)/\(.folder)` (THI \(.thi), files \(.files))"' <<<"$rank_json"
      printf '\n'
    else
      printf "No metrics available; run \`bin/fm-repo-maintenance.sh mine\` first.\n\n"
    fi

    printf '## Structure audit (instrument)\n\n'
    printf '%s' "$structure_json" | jq -r '
      "- Files over \(.ceiling_lines) lines: \(.files_over_ceiling.total) (exempt: \(.files_over_ceiling.exempt))",
      (.files_over_ceiling.listed[] | "  - `\(.path)` (\(.lines) lines)"),
      "- src depth violations (> \(.depth_violations.max_below_src) below src/): \(.depth_violations.total)",
      (.depth_violations.listed[] | "  - `\(.path)`"),
      "- Directories missing SUMMARY.md: \(.dirs_missing_summary.total) of \(.dirs_missing_summary.dirs)",
      (.dirs_missing_summary.listed[] | "  - `\(.dir)`"),
      "- Files unlisted by their folder SUMMARY.md: \(.summary_gaps.total)",
      (.summary_gaps.listed[] | "  - `\(.file)` not in `\(.summary)`"),
      "- Invalid SUMMARY.md shapes: \(.summary_invalid.total)",
      (.summary_invalid.listed[] | "  - `\(.summary)` (\(.reasons | join(", ")))"),
      "- Summaries over \(.summary_over_limit.max_lines) lines: \(.summary_over_limit.total)",
      (.summary_over_limit.listed[] | "  - `\(.summary)` (\(.lines) lines)"),
      "- Entrypoints: README.md=\(.entrypoints.readme) AGENTS.md=\(.entrypoints.agents) routing_ok=\(.entrypoints.routing_ok) ok=\(.entrypoints.ok)"'
    printf '\n'

    cat <<'EOF'
## Evidence-backed findings (pending qualitative audit)

Pending. Run the audit playbook (`references/audit-playbook.md`) over this project and replace
this section with the evidence-backed findings list (category, anchor, why it matters).

## Phased slice plan (pending)

Phase 1 remains pending until its three receipts are recorded: a green test suite, zero broken
imports, and a measured token-consumption drop on subsequent tasks. Phase 2 requires those receipts
and the remaining domain packages to meet the four-level depth, per-folder SUMMARY.md, and
unexempted 500-line standards.

## Summary: DO FIRST / DO LATER / DO NOT DO (pending)

Pending. Classify the findings per the audit playbook tri-state rules.
EOF
    } > "$tmp_report"
  ); then
    rm -f -- "$tmp_report"
    rm_die_fail "cannot write report"
  fi
  if ! ln "$tmp_report" "$report"; then
    rm -f -- "$tmp_report"
    if [ -e "$report" ] || [ -L "$report" ]; then
      rm_die_refuse "report already exists: $(rm_sanitize_path "$report")"
    fi
    rm_die_fail "cannot publish report"
  fi
  rm -f -- "$tmp_report"

  printf 'report: %s\n' "$(rm_sanitize_path "$report")"
  if [ -n "$rank_json" ]; then
    fix=$(printf '%s' "$rank_json" | jq -r 'if (.fix_next | length) == 0 then "none" else ([.fix_next[] | "\(.scope)/\(.path) (THI \(.thi))"] | join("; ")) end')
    printf 'fix next: %s\n' "$fix"
  else
    printf 'fix next: none (no metrics)\n'
  fi
}

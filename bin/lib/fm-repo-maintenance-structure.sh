#!/usr/bin/env bash
# Audit tracked files, navigation summaries, and repository entrypoints.

STRUCTURE_ROOT=""
STRUCTURE_JSON=0
STRUCTURE_LOGICAL_NAME=""

rm_parse_structure_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) STRUCTURE_JSON=1; shift ;;
      -* ) rm_die_usage "unknown argument '$1'" ;;
      *)
        [ -z "$STRUCTURE_ROOT" ] || rm_die_usage "structure takes exactly one root directory"
        STRUCTURE_ROOT=$1
        shift
        ;;
    esac
  done
  [ -n "$STRUCTURE_ROOT" ] || rm_die_usage "structure requires a root directory"
  [ -d "$STRUCTURE_ROOT" ] || rm_die_refuse "not a directory: $(rm_sanitize_path "$STRUCTURE_ROOT")"
}

RM_SUMMARY_REASON=""
rm_validate_summary() {
  local summary=$1 role_lines valid_role header separator reasons="" first
  first=$(awk 'NF { print; exit }' "$summary" 2>/dev/null || true)
  case "$first" in \#\ *) ;; *) reasons="heading" ;; esac
  role_lines=$(grep -c '^Role:' "$summary" 2>/dev/null || true)
  valid_role=$(awk '
    /^Role:/ {
      text=$0
      sub(/^Role:[[:space:]]+/, "", text)
      if (text ~ /^[^.!?]+[.!?][[:space:]]*$/) count++
    }
    END { print count + 0 }
  ' "$summary" 2>/dev/null || true)
  [ "$role_lines" -eq 1 ] && [ "$valid_role" -eq 1 ] || reasons="${reasons:+$reasons,}role"
  header=$(grep -Ec '^\|[[:space:]]*File[[:space:]]*\|[[:space:]]*Responsibility[[:space:]]*\|[[:space:]]*Key Exported Symbols[[:space:]]*\|[[:space:]]*$' "$summary" 2>/dev/null || true)
  separator=$(grep -Ec '^\|[[:space:]]*:?-{3,}:?[[:space:]]*\|[[:space:]]*:?-{3,}:?[[:space:]]*\|[[:space:]]*:?-{3,}:?[[:space:]]*\|[[:space:]]*$' "$summary" 2>/dev/null || true)
  [ "$header" -eq 1 ] && [ "$separator" -ge 1 ] || reasons="${reasons:+$reasons,}table"
  RM_SUMMARY_REASON=$reasons
  [ -z "$reasons" ]
}

rm_summary_lists_file() {
  local summary=$1 target=$2
  awk -F'|' -v target="$target" '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    {
      cell=trim($2)
      if (cell == target) found=1
      rest=cell
      while (match(rest, /`[^`]+`/)) {
        token=substr(rest, RSTART + 1, RLENGTH - 2)
        if (token == target) found=1
        rest=substr(rest, RSTART + RLENGTH)
      }
    }
    END { exit(found ? 0 : 1) }
  ' "$summary"
}

rm_agents_routing_ok() {
  awk -F'|' '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    function name(s) { s=tolower(trim(s)); gsub(/`/, "", s); return s }
    BEGIN { task=domain=files=tests=0; header=0; row=0 }
    /^\|/ {
      if (!header) {
        for (i=2; i<NF; i++) {
          cell=name($i)
          if (cell == "task") task=i
          else if (cell == "domain") domain=i
          else if (cell == "files") files=i
          else if (cell == "tests") tests=i
        }
        if (task && domain && files && tests) { header=1; next }
      } else {
        concrete=1
        for (i=2; i<NF; i++) {
          if (i == task || i == domain || i == files || i == tests) {
            cell=trim($i)
            lower=tolower(cell)
            if (cell == "" || cell ~ /^[-:]+$/ || lower == "task" || lower == "domain" || lower == "files" || lower == "tests") concrete=0
          }
        }
        if (concrete) row=1
      }
    }
    END {
      exit(header && row ? 0 : 1)
    }
  ' "$1"
}

rm_structure_json() {
  local root=$1 logical=${2:-} name exemptions tmp f n d base slines
  local over_total=0 exempt_total=0 depth_total=0 dir_total=0 missing_total=0 gap_total=0 overlong_total=0 invalid_total=0 summaries_seen=0
  name=${logical:-$(basename -- "$root")}
  exemptions="$RM_DATA/$name/exemptions.txt"
  rm_new_tmp structure tmp || rm_die_fail "cannot create a temp dir"
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || rm_die_refuse "not a git work tree: $(rm_sanitize_path "$root")"
  if ! git -C "$root" ls-files -z > "$tmp/files0"; then
    rm_die_fail "cannot enumerate tracked files"
  fi
  tr '\0' '\n' < "$tmp/files0" > "$tmp/files.txt" || rm_die_fail "cannot enumerate tracked files"

  : > "$tmp/exempt.txt"
  if [ -f "$exemptions" ]; then
    awk '
      function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
      /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
      { pos=index($0, "::"); if (pos > 1) { p=trim(substr($0, 1, pos-1)); r=trim(substr($0, pos+2)); if (p != "" && r != "") print p } }
    ' "$exemptions" > "$tmp/exempt.txt"
  fi

  : > "$tmp/over.ndjson"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rm_is_code_file "$f" || continue
    grep -Fxq -- "$f" "$tmp/exempt.txt" && continue
    n=$(wc -l < "$root/$f" 2>/dev/null | tr -d ' ') || n=0
    if [ "$n" -gt "$SOFT_CEILING_LINES" ]; then
      over_total=$((over_total + 1))
      jq -cn --arg path "$f" --argjson lines "$n" '{path: $path, lines: $lines}' >> "$tmp/over.ndjson"
    fi
  done < "$tmp/files.txt"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -Fxq -- "$f" "$tmp/exempt.txt" && exempt_total=$((exempt_total + 1))
  done < "$tmp/files.txt"

  : > "$tmp/depth.ndjson"
  while IFS= read -r f; do
    case "$f" in
      src/*)
        n=$(printf '%s' "$f" | awk -F/ '{ print NF - 2 }')
        if [ "$n" -gt "$DEPTH_MAX_BELOW_SRC" ]; then
          depth_total=$((depth_total + 1))
          jq -cn --arg path "$f" '{path: $path}' >> "$tmp/depth.ndjson"
        fi
        ;;
    esac
  done < "$tmp/files.txt"

  awk -F/ 'NF > 1 { p=""; for (i=1; i<NF; i++) { if (i>1) p=p "/"; p=p $i; print p } }' "$tmp/files.txt" \
    | LC_ALL=C sort -u > "$tmp/dirs.txt"
  awk -F/ 'NF > 1 { p=""; for (i=1; i<NF; i++) { if (i>1) p=p "/"; p=p $i } ; print p "\t" $0 }' "$tmp/files.txt" \
    | LC_ALL=C sort -t$'\t' -k1,1 > "$tmp/dirfiles.tsv"

  : > "$tmp/missing.ndjson"
  : > "$tmp/gaps.ndjson"
  : > "$tmp/overlong.ndjson"
  : > "$tmp/invalid.ndjson"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    dir_total=$((dir_total + 1))
    if [ -f "$root/$d/SUMMARY.md" ]; then
      summaries_seen=$((summaries_seen + 1))
      slines=$(wc -l < "$root/$d/SUMMARY.md" 2>/dev/null | tr -d ' ') || slines=0
      if [ "$slines" -gt "$SUMMARY_MAX_LINES" ]; then
        overlong_total=$((overlong_total + 1))
        jq -cn --arg summary "$d/SUMMARY.md" --argjson lines "$slines" \
          '{summary: $summary, lines: $lines}' >> "$tmp/overlong.ndjson"
      fi
      if ! rm_validate_summary "$root/$d/SUMMARY.md"; then
        invalid_total=$((invalid_total + 1))
        jq -cn --arg summary "$d/SUMMARY.md" --arg reasons "$RM_SUMMARY_REASON" \
          '{summary: $summary, reasons: ($reasons | split(",") | map(select(length > 0)))}' >> "$tmp/invalid.ndjson"
      fi
    else
      missing_total=$((missing_total + 1))
      jq -cn --arg dir "$d" '{dir: $dir}' >> "$tmp/missing.ndjson"
    fi
  done < "$tmp/dirs.txt"

  while IFS=$'\t' read -r d f; do
    [ -n "$d" ] || continue
    [ -f "$root/$d/SUMMARY.md" ] || continue
    rm_validate_summary "$root/$d/SUMMARY.md" || continue
    [ "$f" = "$d/SUMMARY.md" ] && continue
    base=${f##*/}
    if ! rm_summary_lists_file "$root/$d/SUMMARY.md" "$base"; then
      gap_total=$((gap_total + 1))
      jq -cn --arg summary "$d/SUMMARY.md" --arg file "$f" \
        '{summary: $summary, file: $file}' >> "$tmp/gaps.ndjson"
    fi
  done < "$tmp/dirfiles.tsv"

  local readme=0 agents=0 readme_valid=0 agents_valid=0 routing_ok=0
  [ -f "$root/README.md" ] && readme=1
  [ -f "$root/AGENTS.md" ] && agents=1
  [ -s "$root/README.md" ] && readme_valid=1
  [ -s "$root/AGENTS.md" ] && agents_valid=1
  [ "$agents_valid" -eq 1 ] && rm_agents_routing_ok "$root/AGENTS.md" && routing_ok=1

  jq -n --arg root "$(rm_sanitize_path "$root")" \
    --argjson ceiling "$SOFT_CEILING_LINES" --argjson depth_max "$DEPTH_MAX_BELOW_SRC" --argjson summary_max "$SUMMARY_MAX_LINES" \
    --argjson over_total "$over_total" --slurpfile over "$tmp/over.ndjson" --argjson exempt_total "$exempt_total" \
    --argjson depth_total "$depth_total" --slurpfile depth "$tmp/depth.ndjson" \
    --argjson dir_total "$dir_total" --argjson missing_total "$missing_total" --slurpfile missing "$tmp/missing.ndjson" \
    --argjson summaries_seen "$summaries_seen" --argjson gap_total "$gap_total" --slurpfile gaps "$tmp/gaps.ndjson" \
    --argjson overlong_total "$overlong_total" --slurpfile overlong "$tmp/overlong.ndjson" \
    --argjson invalid_total "$invalid_total" --slurpfile invalid "$tmp/invalid.ndjson" \
    --argjson readme "$readme" --argjson agents "$agents" --argjson readme_valid "$readme_valid" \
    --argjson agents_valid "$agents_valid" --argjson routing_ok "$routing_ok" \
    '{schema: "fm-repo-maintenance-structure.v1", root: $root,
      ceiling_lines: $ceiling,
      files_over_ceiling: {total: $over_total, exempt: $exempt_total, listed: $over},
      depth_violations: {total: $depth_total, max_below_src: $depth_max, listed: $depth},
      dirs_missing_summary: {total: $missing_total, dirs: $dir_total, listed: $missing},
      summary_gaps: {total: $gap_total, summaries_seen: $summaries_seen, listed: $gaps},
      summary_over_limit: {total: $overlong_total, max_lines: $summary_max, listed: $overlong},
      summary_invalid: {total: $invalid_total, listed: $invalid},
      entrypoints: {readme: ($readme == 1), agents: ($agents == 1),
                    readme_valid: ($readme_valid == 1), agents_valid: ($agents_valid == 1),
                    routing_ok: ($routing_ok == 1), ok: (($readme_valid == 1) and ($agents_valid == 1) and ($routing_ok == 1))}}'
}

rm_run_structure() {
  rm_parse_structure_args "$@"
  rm_require_jq
  rm_init_tmp_root || rm_die_fail "cannot create a temp dir"
  local json
  json=$(rm_structure_json "$STRUCTURE_ROOT" "$STRUCTURE_LOGICAL_NAME") || exit $?
  if [ "$STRUCTURE_JSON" -eq 1 ]; then
    printf '%s\n' "$json"
    return 0
  fi
  printf 'structure: %s\n' "$(rm_sanitize_path "$STRUCTURE_ROOT")"
  printf '%s' "$json" | jq -r '
    "files over \(.ceiling_lines) lines: \(.files_over_ceiling.total) (exempt: \(.files_over_ceiling.exempt))",
    (.files_over_ceiling.listed[] | "  \(.lines)  \(.path)"),
    "src depth violations (> \(.depth_violations.max_below_src) below src/): \(.depth_violations.total)",
    (.depth_violations.listed[] | "  \(.path)"),
    "directories missing SUMMARY.md: \(.dirs_missing_summary.total) of \(.dirs_missing_summary.dirs)",
    (.dirs_missing_summary.listed[] | "  \(.dir)"),
    "files unlisted by their folder SUMMARY.md: \(.summary_gaps.total) (summaries seen: \(.summary_gaps.summaries_seen))",
    (.summary_gaps.listed[] | "  \(.file) not in \(.summary)"),
    "summaries over \(.summary_over_limit.max_lines) lines: \(.summary_over_limit.total)",
    (.summary_over_limit.listed[] | "  \(.lines)  \(.summary)"),
    "invalid summaries: \(.summary_invalid.total)",
    (.summary_invalid.listed[] | "  \(.summary): \(.reasons | join(", "))"),
    "entrypoints: README.md=\(.entrypoints.readme) AGENTS.md=\(.entrypoints.agents) routing_ok=\(.entrypoints.routing_ok) ok=\(.entrypoints.ok)"'
}

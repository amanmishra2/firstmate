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

rm_structure_text_is_meaningful() {
  local text=$1 compact
  compact=$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]' | sed 's/[[:space:]`*_#|:.-]//g')
  [ -n "$compact" ] || return 1
  if printf '%s\n' "$text" | grep -Eiq '(^|[^[:alnum:]])(todo|tbd|tba|n/?a|none|placeholder|pending|unknown|fill[[:space:]_-]*me|change[[:space:]_-]*me|fill[[:space:]]+this[[:space:]]+in)([^[:alnum:]]|$)'; then
    return 1
  fi
  case "$compact" in
    todo|tbd|tba|na|none|placeholder|pending|unknown|fillme|changeme) return 1 ;;
  esac
  case "$compact" in *[[:alnum:]]*) return 0 ;; esac
  return 1
}

rm_entrypoint_valid() {
  local file=$1
  [ -s "$file" ] || return 1
  awk '
    function placeholder(line) {
      line=tolower(line)
      return line ~ /(^|[^[:alnum:]])(todo|tbd|tba|n[\/]?a|none|placeholder|pending|unknown|fill[[:space:]_-]*me|change[[:space:]_-]*me|fill[[:space:]]+this[[:space:]]+in)([^[:alnum:]]|$)/
    }
    function meaningful(line, compact) {
      compact=tolower(line)
      gsub(/[[:space:]`*_#|:.-]/, "", compact)
      return compact != "" && compact !~ /^(todo|tbd|tba|na|none|placeholder|pending|unknown|fillme|changeme)$/ && compact ~ /[[:alnum:]]/ && !placeholder(line)
    }
    NF { if (lines == 0) first=$0; lines++; meaningful_lines += meaningful($0) }
    END { exit(lines >= 2 && meaningful_lines >= 2 && first ~ /^#[[:space:]]/ ? 0 : 1) }
  ' "$file" 2>/dev/null
}

rm_route_rows() {
  local agents=$1
  awk -F'|' '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    function name(s) { s=tolower(trim(s)); gsub(/`/, "", s); return s }
    function separator(s) { s=trim(s); return s ~ /^:?-{3,}:?$/ }
    BEGIN { task=domain=files=tests=0; header=0 }
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
      } else if (separator($task) && separator($domain) && separator($files) && separator($tests)) {
        next
      } else {
        print trim($task) "\t" trim($domain) "\t" trim($files) "\t" trim($tests)
      }
    }
    END { exit(header ? 0 : 1) }
  ' "$agents"
}

rm_route_cell_targets() {
  local cell=$1 rest prefix token found=0
  cell=$(printf '%s' "$cell" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  [ -n "$cell" ] || return 1
  if [[ "$cell" != *'`'* ]]; then
    case "$cell" in *[[:space:]]*) return 1 ;; esac
    printf '%s\n' "$cell"
    return 0
  fi
  rest=$cell
  while [[ "$rest" == *'`'* ]]; do
    prefix=${rest%%\`*}
    case "$prefix" in *[![:space:],]*) return 1 ;; esac
    rest=${rest#*\`}
    token=${rest%%\`*}
    [ "$rest" != "$token" ] || return 1
    [ -n "$token" ] || return 1
    printf '%s\n' "$token"
    found=1
    rest=${rest#*\`}
  done
  case "$rest" in *[![:space:],]*) return 1 ;; esac
  [ "$found" -eq 1 ]
}

rm_tracked_target_ok() {
  local root=$1 target=$2
  case "$target" in
    ''|/*|.|./*|../*|*/../*|*/..|..|*'*'*|*'?'*|*'['*) return 1 ;;
  esac
  [ -f "$root/$target" ] || return 1
  git -C "$root" ls-files -- "$target" 2>/dev/null | grep -Fxq -- "$target"
}

rm_route_cell_ok() {
  local cell=$1 lower
  cell=$(printf '%s' "$cell" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  [ -n "$cell" ] || return 1
  rm_structure_text_is_meaningful "$cell" || return 1
  lower=$(printf '%s' "$cell" | tr '[:upper:]' '[:lower:]' | sed 's/[[:space:]`*_#|:.-]//g')
  case "$lower" in
    ''|task|domain|files|tests|todo|tbd|tba|na|none|placeholder|pending|unknown|fillme|changeme) return 1 ;;
  esac
  case "$cell" in *[[:alnum:]]*) return 0 ;; esac
  return 1
}

rm_route_targets_ok() {
  local root=$1 cell=$2 targets target found=0
  targets=$(rm_route_cell_targets "$cell" 2>/dev/null) || return 1
  [ -n "$targets" ] || return 1
  while IFS= read -r target; do
    [ -n "$target" ] || return 1
    rm_tracked_target_ok "$root" "$target" || return 1
    found=1
  done <<<"$targets"
  [ "$found" -eq 1 ]
}

rm_agents_routing_ok() {
  local agents=$1 root=${2:-} rows task domain files tests row_count=0
  [ -f "$agents" ] || return 1
  [ -n "$root" ] || root=$(cd -- "$(dirname -- "$agents")" 2>/dev/null && pwd -P) || return 1
  rows=$(rm_route_rows "$agents" 2>/dev/null) || return 1
  [ -n "$rows" ] || return 1
  while IFS=$'\t' read -r task domain files tests; do
    [ -n "$task$domain$files$tests" ] || continue
    rm_route_cell_ok "$task" || return 1
    rm_route_cell_ok "$domain" || return 1
    rm_route_targets_ok "$root" "$files" || return 1
    rm_route_targets_ok "$root" "$tests" || return 1
    row_count=$((row_count + 1))
  done <<<"$rows"
  [ "$row_count" -gt 0 ]
}

rm_agents_route_targets() {
  local agents=$1 rows task domain files tests targets
  rows=$(rm_route_rows "$agents" 2>/dev/null) || return 1
  while IFS=$'\t' read -r task domain files tests; do
    [ -n "$task$domain$files$tests" ] || continue
    targets=$(rm_route_cell_targets "$files" 2>/dev/null) || return 1
    printf '%s\n' "$targets"
    targets=$(rm_route_cell_targets "$tests" 2>/dev/null) || return 1
    printf '%s\n' "$targets"
  done <<<"$rows"
}

rm_summary_lists_file() {
  local summary=$1 target=$2
  rm_validate_summary "$summary" || return 1
  awk -F'|' -v target="$target" '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    BEGIN { header=separator=found=invalid=0 }
    /^\|/ {
      if (!header && trim($2) == "File" && trim($3) == "Responsibility" && trim($4) == "Key Exported Symbols") {
        header=1
        next
      }
      if (header && !separator && trim($2) ~ /^:?-{3,}:?$/ && trim($3) ~ /^:?-{3,}:?$/ && trim($4) ~ /^:?-{3,}:?$/) {
        separator=1
        next
      }
      if (header && separator) {
        if (NF != 5) { invalid=1; next }
        for (i=2; i<=4; i++) if (trim($i) == "") invalid=1
        cell=trim($2)
        if (cell == target) found=1
        rest=cell
        while (match(rest, /`[^`]+`/)) {
          token=substr(rest, RSTART + 1, RLENGTH - 2)
          if (token == target) found=1
          rest=substr(rest, RSTART + RLENGTH)
        }
      }
    }
    END { exit(header && separator && !invalid && found ? 0 : 1) }
  ' "$summary"
}

rm_validate_summary() {
  local summary=$1 role_lines valid_role header separator rows invalid_cells reasons="" first
  first=$(awk 'NF { print; exit }' "$summary" 2>/dev/null || true)
  case "$first" in
    \#\ *)
      rm_structure_text_is_meaningful "${first#\# }" || reasons="heading"
      ;;
    *) reasons="heading" ;;
  esac
  role_lines=$(grep -c '^Role:' "$summary" 2>/dev/null || true)
  valid_role=$(awk '
    function placeholder(line) {
      line=tolower(line)
      return line ~ /(^|[^[:alnum:]])(todo|tbd|tba|n[\/]?a|none|placeholder|pending|unknown|fill[[:space:]_-]*me|change[[:space:]_-]*me|fill[[:space:]]+this[[:space:]]+in)([^[:alnum:]]|$)/
    }
    /^Role:/ {
      text=$0
      sub(/^Role:[[:space:]]+/, "", text)
      compact=tolower(text)
      gsub(/[[:space:]`*_#|:.-]/, "", compact)
      if (text ~ /^[^.!?]+[.!?][[:space:]]*$/ && compact != "" && compact !~ /^(todo|tbd|tba|na|none|placeholder|pending|unknown|fillme|changeme)$/ && !placeholder(text)) count++
    }
    END { print count + 0 }
  ' "$summary" 2>/dev/null || true)
  [ "$role_lines" -eq 1 ] && [ "$valid_role" -eq 1 ] || reasons="${reasons:+$reasons,}role"
  header=$(grep -Ec '^\|[[:space:]]*File[[:space:]]*\|[[:space:]]*Responsibility[[:space:]]*\|[[:space:]]*Key Exported Symbols[[:space:]]*\|[[:space:]]*$' "$summary" 2>/dev/null || true)
  separator=$(grep -Ec '^\|[[:space:]]*:?-{3,}:?[[:space:]]*\|[[:space:]]*:?-{3,}:?[[:space:]]*\|[[:space:]]*:?-{3,}:?[[:space:]]*\|[[:space:]]*$' "$summary" 2>/dev/null || true)
  rows=$(awk -F'|' '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    function placeholder(s, t) {
      t=tolower(s); gsub(/[[:space:]`*_#|:.-]/, "", t)
      return t == "" || t ~ /^(todo|tbd|tba|na|none|placeholder|pending|unknown|fillme|changeme)$/ || s ~ /(^|[^[:alnum:]])(todo|tbd|tba|n[\/]?a|none|placeholder|pending|unknown|fill[[:space:]_-]*me|change[[:space:]_-]*me|fill[[:space:]]+this[[:space:]]+in)([^[:alnum:]]|$)/
    }
    /^\|/ && trim($2) == "File" && trim($3) == "Responsibility" && trim($4) == "Key Exported Symbols" { header_seen=1; next }
    header_seen && !separator_seen && trim($2) ~ /^:?-{3,}:?$/ && trim($3) ~ /^:?-{3,}:?$/ && trim($4) ~ /^:?-{3,}:?$/ { separator_seen=1; next }
    header_seen && separator_seen {
      row_count++
      if (NF != 5) invalid++
      for (i=2; i<=4; i++) if (trim($i) == "") invalid++
      if (placeholder($2) || placeholder($3) || (trim($4) != "-" && placeholder($4))) invalid++
    }
    END { print row_count ":" invalid }
  ' "$summary" 2>/dev/null || true)
  invalid_cells=${rows#*:}
  [ -n "$invalid_cells" ] || invalid_cells=0
  [ "$header" -eq 1 ] && [ "$separator" -ge 1 ] && [ "$invalid_cells" -eq 0 ] || reasons="${reasons:+$reasons,}table"
  RM_SUMMARY_REASON=$reasons
  [ -z "$reasons" ]
}

rm_navigation_path_ok() {
  local root=$1 path=$2 folder base agents targets
  rm_tracked_target_ok "$root" "$path" || return 1
  if [[ "$path" != */* ]]; then
    case "$path" in
      README.md) rm_entrypoint_valid "$root/README.md"; return $? ;;
      AGENTS.md) rm_entrypoint_valid "$root/AGENTS.md" && rm_agents_routing_ok "$root/AGENTS.md" "$root"; return $? ;;
    esac
    agents="$root/AGENTS.md"
    if rm_entrypoint_valid "$agents" && rm_agents_routing_ok "$agents" "$root"; then
      targets=$(rm_agents_route_targets "$agents" 2>/dev/null || true)
      printf '%s\n' "$targets" | grep -Fxq -- "$path" && return 0
    fi
    return 1
  fi
  folder=${path%/*}
  base=${path##*/}
  if rm_tracked_target_ok "$root" "$folder/SUMMARY.md"; then
    rm_validate_summary "$root/$folder/SUMMARY.md" || return 1
    [ "$base" = SUMMARY.md ] && return 0
    rm_summary_lists_file "$root/$folder/SUMMARY.md" "$base"
    return $?
  fi
  return 1
}

rm_structure_json() {
  local root=$1 logical=${2:-} name exemptions tmp f n d base slines root_target route_targets layer import_line
  local over_total=0 exempt_total=0 depth_total=0 import_total=0 dir_total=0 missing_total=0 gap_total=0 overlong_total=0 invalid_total=0 summaries_seen=0 root_orphan_total=0
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
  : > "$tmp/import-direction.ndjson"
  while IFS= read -r f; do
    case "$f" in
      src/*)
        n=$(printf '%s' "$f" | awk -F/ '{ print NF - 2 }')
        if [ "$n" -gt "$DEPTH_MAX_BELOW_SRC" ]; then
          depth_total=$((depth_total + 1))
          jq -cn --arg path "$f" '{path: $path}' >> "$tmp/depth.ndjson"
        fi
        case "$f" in src/cli/*|src/web/*) continue ;; esac
        rm_is_code_file "$f" || continue
        for layer in cli web; do
          while IFS=: read -r import_line _; do
            [ -n "$import_line" ] || continue
            import_total=$((import_total + 1))
            jq -cn --arg path "$f" --argjson line "$import_line" --arg layer "$layer" \
              '{path: $path, line: $line, layer: $layer}' >> "$tmp/import-direction.ndjson"
          done < <(grep -nE -- "(^|[[:space:]])(from|import|use|require|include)([[:space:]]+|[[:space:]]*\\()[^[:space:]]*(/|\\.|::)?${layer}(/|\\.|::|[[:space:]]|\\)|[\"']|$)" "$root/$f" 2>/dev/null \
            | grep -vE '^[0-9]+:[[:space:]]*(#|//|/\*|\*)' || true)
        done
        ;;
    esac
  done < "$tmp/files.txt"

  awk -F/ 'NF > 1 { p=""; for (i=1; i<NF; i++) { if (i>1) p=p "/"; p=p $i; print p } }' "$tmp/files.txt" \
    | LC_ALL=C sort -u > "$tmp/dirs.txt"
  awk -F/ 'NF > 1 { d=$0; sub(/\/[^\/]*$/, "", d); print d "\t" $0 }' "$tmp/files.txt" \
    | LC_ALL=C sort -t$'\t' -k1,1 > "$tmp/dirfiles.tsv"
  awk -F/ 'NF == 1 { print }' "$tmp/files.txt" | LC_ALL=C sort > "$tmp/rootfiles.txt"

  : > "$tmp/missing.ndjson"
  : > "$tmp/gaps.ndjson"
  : > "$tmp/overlong.ndjson"
  : > "$tmp/invalid.ndjson"
  : > "$tmp/root-orphans.ndjson"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    dir_total=$((dir_total + 1))
    if rm_tracked_target_ok "$root" "$d/SUMMARY.md"; then
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
    rm_tracked_target_ok "$root" "$d/SUMMARY.md" || continue
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
  rm_entrypoint_valid "$root/README.md" && readme_valid=1
  rm_entrypoint_valid "$root/AGENTS.md" && agents_valid=1
  [ "$agents_valid" -eq 1 ] && rm_agents_routing_ok "$root/AGENTS.md" "$root" && routing_ok=1

  route_targets=""
  [ "$routing_ok" -eq 1 ] && route_targets=$(rm_agents_route_targets "$root/AGENTS.md" 2>/dev/null || true)
  while IFS= read -r root_target; do
    [ -n "$root_target" ] || continue
    case "$root_target" in
      README.md|AGENTS.md) continue ;;
    esac
    if ! { [ "$routing_ok" -eq 1 ] && printf '%s\n' "$route_targets" | grep -Fxq -- "$root_target"; }; then
      root_orphan_total=$((root_orphan_total + 1))
      jq -cn --arg file "$root_target" '{file: $file}' >> "$tmp/root-orphans.ndjson"
    fi
  done < "$tmp/rootfiles.txt"

  jq -n --arg root "$(rm_sanitize_path "$root")" \
    --argjson ceiling "$SOFT_CEILING_LINES" --argjson depth_max "$DEPTH_MAX_BELOW_SRC" --argjson summary_max "$SUMMARY_MAX_LINES" \
    --argjson over_total "$over_total" --slurpfile over "$tmp/over.ndjson" --argjson exempt_total "$exempt_total" \
    --argjson depth_total "$depth_total" --slurpfile depth "$tmp/depth.ndjson" \
    --argjson import_total "$import_total" --slurpfile imports "$tmp/import-direction.ndjson" \
    --argjson dir_total "$dir_total" --argjson missing_total "$missing_total" --slurpfile missing "$tmp/missing.ndjson" \
    --argjson summaries_seen "$summaries_seen" --argjson gap_total "$gap_total" --slurpfile gaps "$tmp/gaps.ndjson" \
    --argjson overlong_total "$overlong_total" --slurpfile overlong "$tmp/overlong.ndjson" \
    --argjson invalid_total "$invalid_total" --slurpfile invalid "$tmp/invalid.ndjson" \
    --argjson root_orphan_total "$root_orphan_total" --slurpfile root_orphans "$tmp/root-orphans.ndjson" \
    --argjson readme "$readme" --argjson agents "$agents" --argjson readme_valid "$readme_valid" \
    --argjson agents_valid "$agents_valid" --argjson routing_ok "$routing_ok" \
    '{schema: "fm-repo-maintenance-structure.v1", root: $root,
      ceiling_lines: $ceiling,
      files_over_ceiling: {total: $over_total, exempt: $exempt_total, listed: $over},
      depth_violations: {total: $depth_total, max_below_src: $depth_max, listed: $depth},
      import_direction: {total: $import_total, listed: $imports},
      dirs_missing_summary: {total: $missing_total, dirs: $dir_total, listed: $missing},
      summary_gaps: {total: $gap_total, summaries_seen: $summaries_seen, listed: $gaps},
      summary_over_limit: {total: $overlong_total, max_lines: $summary_max, listed: $overlong},
      summary_invalid: {total: $invalid_total, listed: $invalid},
      root_orphans: {total: $root_orphan_total, listed: $root_orphans},
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
    "domain imports of cli/ or web/: \(.import_direction.total)",
    (.import_direction.listed[] | "  \(.path):\(.line) imports \(.layer)/"),
    "directories missing SUMMARY.md: \(.dirs_missing_summary.total) of \(.dirs_missing_summary.dirs)",
    (.dirs_missing_summary.listed[] | "  \(.dir)"),
    "files unlisted by their folder SUMMARY.md: \(.summary_gaps.total) (summaries seen: \(.summary_gaps.summaries_seen))",
    (.summary_gaps.listed[] | "  \(.file) not in \(.summary)"),
    "summaries over \(.summary_over_limit.max_lines) lines: \(.summary_over_limit.total)",
    (.summary_over_limit.listed[] | "  \(.lines)  \(.summary)"),
    "invalid summaries: \(.summary_invalid.total)",
    (.summary_invalid.listed[] | "  \(.summary): \(.reasons | join(", "))"),
    "root orphan files: \(.root_orphans.total)",
    (.root_orphans.listed[] | "  \(.file)"),
    "entrypoints: README.md=\(.entrypoints.readme) AGENTS.md=\(.entrypoints.agents) routing_ok=\(.entrypoints.routing_ok) ok=\(.entrypoints.ok)"'
}

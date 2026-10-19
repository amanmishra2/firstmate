#!/usr/bin/env bash
# Resolve aggregate file rows and rank them by repeat-read token heat.

RANK_METRICS=""
RANK_PROJECT=""
RANK_TOP=$DEFAULT_TOP
RANK_JSON=0

rm_parse_rank_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --metrics)
        [ "$#" -ge 2 ] || rm_die_usage "--metrics requires a path"
        RANK_METRICS=$2
        shift 2
        ;;
      --project)
        [ "$#" -ge 2 ] || rm_die_usage "--project requires a name"
        RANK_PROJECT=$2
        shift 2
        ;;
      --top)
        [ "$#" -ge 2 ] || rm_die_usage "--top requires a count"
        case "$2" in ''|*[!0-9]*) rm_die_usage "--top must be a count" ;; esac
        RANK_TOP=$2
        shift 2
        ;;
      --json)
        RANK_JSON=1
        shift
        ;;
      *) rm_die_usage "unknown argument '$1'" ;;
    esac
  done
}

rm_latest_metrics() {
  local f newest=""
  [ -d "$METRICS_DIR" ] || return 1
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    newest=$f
  done < <(find "$METRICS_DIR" -maxdepth 1 -type f -name '*.json' -print 2>/dev/null | LC_ALL=C sort)
  [ -n "$newest" ] || return 1
  printf '%s\n' "$newest"
}

rm_run_rank_json() {
  local metrics=$1 project=$2 top=$3
  local tmp scope path reads tasks rereads maxb root abs lines bytes tokens size_src nav prioritized
  local unresolved=0
  rm_new_tmp rank tmp || rm_die_fail "cannot create a temp dir"
  : > "$tmp/rows.ndjson"
  if ! jq -r '.files[]? | [.scope, .path, (.reads|tostring), (.tasks|tostring), (.reread_reads // 0 | tostring), (.max_payload_bytes // 0 | tostring)] | @tsv' \
    "$metrics" > "$tmp/input.tsv" 2>/dev/null; then
    rm_die_fail "cannot read metrics JSON"
  fi
  while IFS=$'\t' read -r scope path reads tasks rereads maxb; do
    [ -n "$scope" ] || continue
    [ "$scope" != home ] || continue
    if [ -n "$project" ]; then
      case "$scope" in
        "projects/$project") ;;
        firstmate) [ "$project" = firstmate ] || continue ;;
        *) continue ;;
      esac
    fi
    case "$reads:$tasks:$rereads:$maxb" in
      *[!0-9:]* ) unresolved=$((unresolved + 1)); continue ;;
    esac
    root=$(rm_scope_root "$scope" 2>/dev/null || true)
    [ -n "$root" ] || { unresolved=$((unresolved + 1)); continue; }
    abs=$(rm_resolve_scoped_file "$root" "$path" 2>/dev/null || true)
    [ -n "$abs" ] || { unresolved=$((unresolved + 1)); continue; }
    if [ -f "$abs" ]; then
      lines=$(wc -l < "$abs" 2>/dev/null | tr -d ' ') || lines=0
      bytes=$(wc -c < "$abs" 2>/dev/null | tr -d ' ') || bytes=0
      [ -n "$lines" ] || lines=0
      [ -n "$bytes" ] || bytes=0
      tokens=$(( (bytes + 3) / 4 ))
      size_src=tree
    else
      lines=null
      tokens=$(( (maxb + 3) / 4 ))
      size_src=observed
    fi
    if rm_navigation_path_ok "$root" "$path"; then nav=1; else nav=0; fi
    prioritized=0
    if [ "$lines" != null ] && [ "$lines" -gt "$SOFT_CEILING_LINES" ]; then prioritized=1; fi
    [ "$nav" -eq 0 ] && prioritized=1
    jq -cn --arg scope "$scope" --arg path "$path" \
      --argjson reads "$reads" --argjson tasks "$tasks" --argjson rereads "$rereads" \
      --argjson tokens "$tokens" --argjson lines "$lines" --arg size_source "$size_src" \
      --argjson nav "$nav" --argjson prioritized "$prioritized" \
      '{scope: $scope, path: $path, reads: $reads, tasks: $tasks,
        reread_reads: $rereads, tokens: $tokens, lines: $lines,
        size_source: $size_source, nav: ($nav == 1),
        thi: ($tasks * $rereads * $tokens), prioritized: ($prioritized == 1)}' \
      >> "$tmp/rows.ndjson"
  done < "$tmp/input.tsv"

  jq -n --arg metrics "$(rm_sanitize_path "$metrics")" --argjson top "$top" --argjson unresolved "$unresolved" \
    --slurpfile rows "$tmp/rows.ndjson" \
    '($rows | sort_by(-.thi, .scope, .path)) as $sorted
     | {schema: "fm-repo-maintenance-rank.v1", metrics: $metrics,
        files: ($sorted | .[0:$top]),
        fix_next: ([ $sorted[] | select(.prioritized) ] | .[0:3]),
        folders: ([ $sorted[]
          | . + {folder: (if (.path | contains("/")) then (.path | split("/")[0:-1] | join("/")) else "." end)} ]
          | group_by(.scope + "::" + .folder)
          | map({scope: .[0].scope, folder: .[0].folder,
                 thi: ([.[].thi] | add), files: length})
          | sort_by(-.thi, .scope, .folder) | .[0:10]),
        unresolved: $unresolved}'
}

rm_run_rank() {
  rm_parse_rank_args "$@"
  rm_require_jq
  rm_init_roots
  rm_init_tmp_root || rm_die_fail "cannot create a temp dir"
  local metrics rank_json unresolved fix
  metrics=${RANK_METRICS:-$(rm_latest_metrics || true)}
  [ -n "$metrics" ] || rm_die_fail "no metrics file found under $(rm_sanitize_path "$METRICS_DIR") (run mine first)"
  [ -f "$metrics" ] || rm_die_fail "metrics file not found: $(rm_sanitize_path "$metrics")"
  rank_json=$(rm_run_rank_json "$metrics" "$RANK_PROJECT" "$RANK_TOP") || exit 1
  if [ "$RANK_JSON" -eq 1 ]; then
    printf '%s\n' "$rank_json"
    return 0
  fi

  printf 'Token heat - %s\n' "$(rm_sanitize_path "$metrics")"
  printf '%-3s %-46s %5s %5s %8s %6s %10s %8s %s\n' \
    '#' file reads tasks tokens lines THI re-reads flags
  printf '%s' "$rank_json" | jq -r '
    .files | to_entries[] |
    [ (.key + 1 | tostring),
      (.value.scope + "/" + .value.path), (.value.reads | tostring),
      (.value.tasks | tostring), (.value.tokens | tostring),
      (if .value.lines == null then "-" else (.value.lines | tostring) end),
      (.value.thi | tostring), (.value.reread_reads | tostring),
      ([ (if .value.prioritized then "PRIORITIZED" else empty end),
         (if .value.nav then empty else "no-nav" end),
         (if .value.size_source == "observed" then "stale" else empty end) ] | join(","))
    ] | @tsv' | while IFS=$'\t' read -r n f r t tk ln thi rereads flags; do
      printf '%-3s %-46s %5s %5s %8s %6s %10s %8s %s\n' "$n" "$f" "$r" "$t" "$tk" "$ln" "$thi" "$rereads" "$flags"
    done
  printf 'folders:\n'
  printf '%s' "$rank_json" | jq -r '.folders[] | "  \(.scope)/\(.folder)  thi=\(.thi) files=\(.files)"'
  fix=$(printf '%s' "$rank_json" | jq -r 'if (.fix_next | length) == 0 then "none" else ([.fix_next[] | "\(.scope)/\(.path) (THI \(.thi))"] | join("; ")) end')
  printf 'fix next: %s\n' "$fix"
  unresolved=$(printf '%s' "$rank_json" | jq -r '.unresolved')
  [ "$unresolved" -gt 0 ] && printf 'unresolved: %s recorded files have no resolvable root\n' "$unresolved"
}

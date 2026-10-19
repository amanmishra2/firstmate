#!/usr/bin/env bash
# Aggregate the structured OpenCode and Codex session stores.

MINE_NOW=""

rm_parse_mine_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --now)
        [ "$#" -ge 2 ] || rm_die_usage "--now requires an epoch"
        case "$2" in ''|*[!0-9]*) rm_die_usage "--now must be an epoch in seconds" ;; esac
        MINE_NOW=$2
        shift 2
        ;;
      *) rm_die_usage "unknown argument '$1'" ;;
    esac
  done
}

rm_coverage_json() {
  local source=$1 path=$2 status=$3 seen=$4 mined=$5 empty=$6 error=$7 scope=${8:-0}
  path=$(rm_sanitize_home_area "$path")
  jq -cn --arg source "$source" --arg path "$path" --arg status "$status" \
    --argjson seen "$seen" --argjson mined "$mined" \
    --argjson empty "$empty" --argjson error "$error" --argjson scope "$scope" \
    '{source: $source, path: $path, status: $status,
      sessions_seen: $seen, sessions_mined: $mined,
      skipped_empty: $empty, skipped_error: $error, skipped_scope: $scope}'
}

OPENCODE_SESSION_DEFS='
def total_tokens:
  ((.ti // 0) + (.to_ // 0) + (.tr // 0) + (.tcr // 0) + (.tcw // 0));
def input_tokens: (.ti // 0);
def is_edit:
  (.ptype == "tool" and .tool_status == "completed" and
   (.pname == "edit" or .pname == "write" or .pname == "patch" or .pname == "apply_patch"));
'

# shellcheck disable=SC2016
OPENCODE_SESSION_BODY='
(reduce .[] as $r ({ };
   ($r.seq | tostring) as $k
   | (.[$k] // {tokens: ($r | total_tokens), input: ($r | input_tokens), edit: false, reads: {}}) as $cur
   | .[$k] = ($cur
       | .edit = (.edit or ($r | is_edit))
       | if ($r.ptype == "tool" and $r.tool_status == "completed" and $r.pname == "read" and ($r.fpath // "") != "") then
           .reads[$r.fpath] = ((.reads[$r.fpath] // 0) + 1)
         else . end)
 ))
| to_entries
| sort_by(.key | tonumber)
| . as $turns
| ([ $turns[].value.edit ] | index(true)) as $ei
| {task: {
     turns: ($turns | length),
     first_edit_turn: (if $ei == null then null else $ei + 1 end),
     tokens_total: ([ $turns[].value.tokens ] | add // 0),
     tokens_exploration: ([ $turns[0:($ei // ($turns | length))][].value.input ] | add // 0),
     files_read: ([ $turns[].value.reads[] ] | add // 0),
     unique_files: ([ $turns[].value.reads | keys[] ] | unique | length),
     reread_reads: ([ $turns[].value.reads | to_entries[] ] | group_by(.key)
       | map([.[].value] | add) | map(. - 1) | map(if . > 0 then . else 0 end) | add // 0),
     three_plus_read_files: ([ $turns[].value.reads | to_entries[] ] | group_by(.key)
       | map([.[].value] | add) | map(select(. >= 3)) | length)
   },
   reads: [ $turns[].value.reads | to_entries[] | {path: .key, count: .value} ]}
'

rm_record_opencode_reads() {
  local rows=$1 task_key=$2 cwd=$3 read_path read_bytes classified scope rel
  while IFS=$'\t' read -r read_path read_bytes; do
    [ -n "$read_path" ] || continue
    classified=$(rm_classify_file "$read_path" "$cwd" 2>/dev/null || true)
    if [ -n "$classified" ]; then
      IFS=$'\t' read -r scope rel <<EOF
$classified
EOF
      jq -cn --arg scope "$scope" --arg path "$rel" --argjson join "$task_key" \
        --argjson bytes "${read_bytes:-0}" \
        '{scope: $scope, path: $path, join: $join, bytes: $bytes}' >> "$RM_MINE_TMP/reads.ndjson"
    else
      jq -cn --argjson join "$task_key" '{external: true, join: $join}' >> "$RM_MINE_TMP/reads.ndjson"
    fi
  done < <(printf '%s' "$rows" | jq -r '.[] | select(.ptype == "tool" and .tool_status == "completed" and .pname == "read" and (.fpath // "") != "") | [.fpath, (.outlen // 0)] | @tsv' 2>/dev/null)
}

rm_mine_opencode() {
  local tmp=$1 start=$2 end=$3
  local db=${FM_RM_OPENCODE_DB:-$FM_HOME/.local/share/opencode/opencode.db} physical
  local status=mined seen=0 mined=0 empty_skips=0 error_skips=0 scope_skips=0
  local session_rows row id dir outcome idle rows task_json dir_label id_sql start_ms end_ms task_key=0 next_task_key
  local invalid_candidates=0
  start_ms=$((start * 1000))
  end_ms=$((end * 1000))

  physical=$(rm_resolve_source_path "$db" 2>/dev/null || true)
  if [ -z "$physical" ]; then
    rm_coverage_json opencode '<EXTERNAL>' unreadable 0 0 0 1 0
    return 0
  fi
  if ! rm_path_in_home "$physical"; then
    rm_coverage_json opencode '<EXTERNAL>' outside-home 0 0 0 0 0 0
    return 0
  fi
  db=$physical

  if [ ! -f "$db" ]; then
    rm_coverage_json opencode "$(rm_sanitize_path "$db")" absent 0 0 0 0 0 0
    return 0
  fi
  if ! command -v sqlite3 >/dev/null 2>&1; then
    rm_coverage_json opencode "$(rm_sanitize_path "$db")" sqlite3-missing 0 0 0 0 0 0
    return 0
  fi
  if ! sqlite3 -readonly "$db" 'SELECT 1' >/dev/null 2>&1; then
    rm_coverage_json opencode "$(rm_sanitize_path "$db")" unreadable 0 0 0 0 0 0
    return 0
  fi

  if ! session_rows=$(sqlite3 -readonly -json "$db" \
      "SELECT id, slug, directory, idle_outcome, time_idle
         FROM session_v2
        WHERE idle_outcome IN ('succeeded', 'failed', 'interrupted')
          AND time_idle >= $start_ms AND time_idle <= $end_ms
        ORDER BY time_idle DESC;" 2>/dev/null); then
    rm_coverage_json opencode "$(rm_sanitize_path "$db")" unreadable 0 0 0 1 0
    return 0
  fi
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    id=$(printf '%s' "$row" | jq -r '.id // empty' 2>/dev/null || true)
    dir=$(printf '%s' "$row" | jq -r '.directory // empty' 2>/dev/null || true)
    outcome=$(printf '%s' "$row" | jq -r '.idle_outcome // empty' 2>/dev/null || true)
    idle=$(printf '%s' "$row" | jq -r '.time_idle // empty' 2>/dev/null || true)
    if [ -z "$id" ] || [ -z "$dir" ]; then
      invalid_candidates=$((invalid_candidates + 1)); error_skips=$((error_skips + 1)); continue
    fi
    case "$dir" in
      /*) ;;
      *) invalid_candidates=$((invalid_candidates + 1)); error_skips=$((error_skips + 1)); continue ;;
    esac
    case "$outcome" in succeeded|failed|interrupted) ;; *) invalid_candidates=$((invalid_candidates + 1)); error_skips=$((error_skips + 1)); continue ;; esac
    case "$idle" in ''|*[!0-9]*) invalid_candidates=$((invalid_candidates + 1)); error_skips=$((error_skips + 1)); continue ;; esac
    case "$(rm_root_matches "$dir")" in
      1) ;;
      *) scope_skips=$((scope_skips + 1)); continue ;;
    esac
    seen=$((seen + 1))

    id_sql=${id//\'/\'\'}

    if ! rows=$(sqlite3 -readonly -json "$db" \
      "SELECT m.seq AS seq,
              json_extract(m.data,'\$.tokens.input') AS ti,
              json_extract(m.data,'\$.tokens.output') AS to_,
              json_extract(m.data,'\$.tokens.reasoning') AS tr,
              json_extract(m.data,'\$.tokens.cache.read') AS tcr,
              json_extract(m.data,'\$.tokens.cache.write') AS tcw,
              json_extract(p.value,'\$.type') AS ptype,
              json_extract(p.value,'\$.name') AS pname,
              json_extract(p.value,'\$.state.status') AS tool_status,
              json_extract(p.value,'\$.state.input.path') AS fpath,
              CASE WHEN json_extract(p.value,'\$.state.status') = 'completed'
                THEN length(CAST(json_extract(p.value,'\$.state.content[0].text') AS BLOB))
                ELSE 0 END AS outlen
       FROM session_message m
       LEFT JOIN json_each(m.data,'\$.content') p ON true
       WHERE m.session_id = '$id_sql' AND m.type = 'assistant'
       ORDER BY m.seq;" 2>/dev/null); then
      error_skips=$((error_skips + 1))
      continue
    fi
    [ -n "$rows" ] && [ "$rows" != "[]" ] || { empty_skips=$((empty_skips + 1)); continue; }
    dir_label=$(rm_sanitize_home_area "$dir")
    next_task_key=$((task_key + 1))
    if ! task_json=$(printf '%s' "$rows" | jq -c \
      --argjson join "$next_task_key" --arg dir "$dir_label" \
      "$OPENCODE_SESSION_DEFS $OPENCODE_SESSION_BODY | .task + {join: \$join, source: \"opencode\", dir: \$dir}" 2>/dev/null); then
      error_skips=$((error_skips + 1))
      continue
    fi
    [ -n "$task_json" ] || { error_skips=$((error_skips + 1)); continue; }
    task_key=$next_task_key
    printf '%s\n' "$task_json" >> "$tmp/tasks.ndjson"
    RM_MINE_TMP=$tmp rm_record_opencode_reads "$rows" "$task_key" "$dir"
    mined=$((mined + 1))
  done < <(printf '%s' "$session_rows" | jq -c '.[]' 2>/dev/null)

  if [ "$mined" -eq 0 ]; then
    if [ "$invalid_candidates" -gt 0 ] || [ "$error_skips" -gt 0 ]; then status=unreadable; else status=empty; fi
  fi
  rm_coverage_json opencode "$(rm_sanitize_path "$db")" "$status" "$seen" "$mined" \
    "$empty_skips" "$error_skips" "$scope_skips"
}

rm_run_mine() {
  rm_parse_mine_args "$@"
  rm_require_jq
  rm_init_roots
  local now=${MINE_NOW:-${FM_RM_NOW:-$(date +%s)}} start end out tmp coverage cov roots_json tmp_out
  now=${now:-0}
  start=$((now - DEFAULT_WINDOW_DAYS * 86400))
  end=$now
  out="$METRICS_DIR/$(rm_epoch_to_date "$now").json"

  rm_init_tmp_root || rm_die_fail "cannot create a temp dir"
  rm_new_tmp mine tmp || rm_die_fail "cannot create a temp dir"
  : > "$tmp/tasks.ndjson"
  : > "$tmp/reads.ndjson"
  : > "$tmp/coverage.ndjson"

  cov=$(rm_mine_opencode "$tmp" "$start" "$end") || rm_die_fail "opencode mining failed"
  printf '%s\n' "$cov" >> "$tmp/coverage.ndjson"
  cov=$(rm_mine_codex "$tmp" "$start" "$end") || rm_die_fail "codex mining failed"
  printf '%s\n' "$cov" >> "$tmp/coverage.ndjson"
  coverage=$(jq -sc '.' "$tmp/coverage.ndjson") || rm_die_fail "cannot compose source coverage"
  roots_json=$(jq -cn --arg home "$RM_APPROVED_HOME" --arg code "$RM_CODE_ROOT" \
    --argjson pools "$(printf '%s\n' "${RM_EXTRA_ROOTS[@]+${RM_EXTRA_ROOTS[@]}}" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
    '["<HOME>"] + (if $code != "" and $code != $home then ["<FIRSTMATE>"] else [] end) +
     ([$pools[] | select(. != $code and . != $home)] | map("<POOL>"))') \
    || rm_die_fail "cannot compose root labels"

  if ! mkdir -p -- "$(dirname -- "$out")"; then
    rm_die_fail "cannot create metrics directory"
  fi
  tmp_out=$(mktemp "$METRICS_DIR/.metrics.XXXXXX") || rm_die_fail "cannot create metrics temp file"
  if ! jq -n \
    --argjson now "$now" --argjson start "$start" --argjson end "$end" --argjson days "$DEFAULT_WINDOW_DAYS" \
    --argjson roots "$roots_json" --argjson coverage "$coverage" \
    --slurpfile tasks "$tmp/tasks.ndjson" --slurpfile reads "$tmp/reads.ndjson" \
    '{schema: "fm-repo-maintenance-metrics.v1",
      generated_at: $now,
      window: {start: $start, end: $end, days: $days},
      roots: $roots,
      coverage: $coverage,
      tasks: ($tasks | map(del(.join, .id, .slug)) | sort_by(.source, .dir, (.first_edit_turn // 999999), .turns)),
      files: (
        reduce ($reads[] as $r | select(($r.external // false) | not and ($r.scope // "") != "" and ($r.path // "") != "")
                | $r) as $e
          ({ };
           (($e.scope) + "::" + ($e.path)) as $k
           | .[$k] = ((.[$k] // {scope: $e.scope, path: $e.path, reads: 0, by: {}, max_payload_bytes: 0})
                      | .reads += 1
                      | .by[($e.join | tostring)] = ((.by[($e.join | tostring)] // 0) + 1)
                      | .max_payload_bytes = ([.max_payload_bytes, ($e.bytes // 0)] | max)))
        | [to_entries[].value
           | {scope, path, reads,
              tasks: (.by | length),
              reread_reads: ([.by[] | (. - 1) as $n | if $n > 0 then $n else 0 end] | add // 0),
              reread_tasks: ([.by[] | select(. >= 2)] | length),
              three_plus_read_tasks: ([.by[] | select(. >= 3)] | length),
              max_payload_bytes}]
        | sort_by(.scope, .path)
      ),
      external: {
        reads: ([$reads[] | select(.external == true)] | length),
        tasks: ([$reads[] | select(.external == true) | .join] | unique | length)
      }}' > "$tmp_out"; then
    rm -f -- "$tmp_out"
    rm_die_fail "cannot compose metrics JSON"
  fi
  if ! mv -f -- "$tmp_out" "$out"; then
    rm -f -- "$tmp_out"
    rm_die_fail "cannot publish metrics JSON"
  fi

  printf 'mine: wrote %s\n' "$(rm_sanitize_path "$out")"
  jq -sr '.[] | if .status == "outside-home" then "mine: \(.source) skipped: source store is outside firstmate home" else "mine: \(.source) \(.status) sessions_seen=\(.sessions_seen) sessions_mined=\(.sessions_mined) skipped_empty=\(.skipped_empty) skipped_error=\(.skipped_error)" end' "$tmp/coverage.ndjson"
}

#!/usr/bin/env bash
# Aggregate the structured OpenCode and Codex session stores.

MINE_NOW=""
MINE_MAX=${FM_RM_MAX_SESSIONS:-$DEFAULT_MAX_SESSIONS}
case "$MINE_MAX" in ''|*[!0-9]*) MINE_MAX=$DEFAULT_MAX_SESSIONS ;; esac

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
  local source=$1 path=$2 status=$3 seen=$4 mined=$5 cap=$6 empty=$7 error=$8 scope=${9:-0}
  jq -cn --arg source "$source" --arg path "$path" --arg status "$status" \
    --argjson seen "$seen" --argjson mined "$mined" --argjson cap "$cap" \
    --argjson empty "$empty" --argjson error "$error" --argjson scope "$scope" \
    '{source: $source, path: $path, status: $status,
      sessions_seen: $seen, sessions_mined: $mined, skipped_cap: $cap,
      skipped_empty: $empty, skipped_error: $error, skipped_scope: $scope}'
}

OPENCODE_SESSION_DEFS='
def total_tokens:
  ((.ti // 0) + (.to_ // 0) + (.tr // 0) + (.tcr // 0) + (.tcw // 0));
def input_tokens: (.ti // 0);
def is_edit:
  (.ptype == "tool" and
   (.pname == "edit" or .pname == "write" or .pname == "patch" or .pname == "apply_patch"));
'

# shellcheck disable=SC2016
OPENCODE_SESSION_BODY='
(reduce .[] as $r ({ };
   ($r.seq | tostring) as $k
   | (.[$k] // {tokens: ($r | total_tokens), input: ($r | input_tokens), edit: false, reads: {}}) as $cur
   | .[$k] = ($cur
       | .edit = (.edit or ($r | is_edit))
       | if ($r.ptype == "tool" and $r.pname == "read" and ($r.fpath // "") != "") then
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
  done < <(printf '%s' "$rows" | jq -r '.[] | select(.ptype == "tool" and .pname == "read" and (.fpath // "") != "") | [.fpath, (.outlen // 0)] | @tsv' 2>/dev/null)
}

rm_mine_opencode() {
  local tmp=$1 start=$2 end=$3 cap=$4
  local db=${FM_RM_OPENCODE_DB:-${XDG_DATA_HOME:-$HOME/.local/share}/opencode/opencode.db}
  local status=mined seen=0 mined=0 cap_skips=0 empty_skips=0 error_skips=0 scope_skips=0
  local session_rows row id dir updated rows task_json dir_label id_sql start_ms end_ms task_key=0 next_task_key
  local invalid_candidates=0
  start_ms=$((start * 1000))
  end_ms=$((end * 1000))

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
      'SELECT id, slug, directory, time_updated FROM session_v2 ORDER BY time_updated DESC;' 2>/dev/null); then
    rm_coverage_json opencode "$(rm_sanitize_path "$db")" unreadable 0 0 0 0 1 0
    return 0
  fi
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    id=$(printf '%s' "$row" | jq -r '.id // empty' 2>/dev/null || true)
    dir=$(printf '%s' "$row" | jq -r '.directory // empty' 2>/dev/null || true)
    updated=$(printf '%s' "$row" | jq -r '.time_updated // empty' 2>/dev/null || true)
    if [ -z "$id" ] || [ -z "$dir" ]; then
      invalid_candidates=$((invalid_candidates + 1)); error_skips=$((error_skips + 1)); continue
    fi
    case "$dir" in
      /*) ;;
      *) invalid_candidates=$((invalid_candidates + 1)); error_skips=$((error_skips + 1)); continue ;;
    esac
    case "$updated" in ''|*[!0-9]*) invalid_candidates=$((invalid_candidates + 1)); error_skips=$((error_skips + 1)); continue ;; esac
    if [ "$updated" -lt "$start_ms" ] || [ "$updated" -gt "$end_ms" ]; then
      continue
    fi
    case "$(rm_root_matches "$dir")" in
      1) ;;
      *) scope_skips=$((scope_skips + 1)); continue ;;
    esac
    seen=$((seen + 1))
    if [ "$seen" -gt "$cap" ]; then
      cap_skips=$((cap_skips + 1))
      continue
    fi

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
              json_extract(p.value,'\$.state.input.path') AS fpath,
              length(CAST(json_extract(p.value,'\$.state.content[0].text') AS BLOB)) AS outlen
       FROM session_message m
       LEFT JOIN json_each(m.data,'\$.content') p ON true
       WHERE m.session_id = '$id_sql' AND m.type = 'assistant'
         AND m.time_created >= $start_ms AND m.time_created <= $end_ms
       ORDER BY m.seq;" 2>/dev/null); then
      error_skips=$((error_skips + 1))
      continue
    fi
    [ -n "$rows" ] && [ "$rows" != "[]" ] || { empty_skips=$((empty_skips + 1)); continue; }
    dir_label=$(rm_sanitize_path "$dir")
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
    if [ "$invalid_candidates" -gt 0 ]; then status=unreadable; else status=empty; fi
  fi
  rm_coverage_json opencode "$(rm_sanitize_path "$db")" "$status" "$seen" "$mined" \
    "$cap_skips" "$empty_skips" "$error_skips" "$scope_skips"
}

rm_mine_codex_reduced() {
  jq -c '
    if .type == "session_meta" then {t: "meta"}
    elif .type == "turn_context" then {t: "turn"}
    elif (.type == "event_msg" and .payload.type == "token_count") then
      {t: "tok",
       total: (.payload.info.total_token_usage.total_tokens // null),
       input: (.payload.info.total_token_usage.input_tokens
               // .payload.info.total_token_usage.prompt_tokens
               // .payload.info.last_token_usage.input_tokens
               // .payload.info.last_token_usage.prompt_tokens
               // null)}
    elif (.type == "response_item" and .payload.type == "function_call") then
      {t: "call", name: (.payload.name // "")}
    else empty end'
}

rm_mine_codex_metrics() {
  jq -s '
    (reduce .[] as $e ({turns: 0, edit_at: null, total_last: 0, input_before: 0};
       if $e.t == "turn" then .turns += 1
       elif ($e.t == "call" and ($e.name == "apply_patch" or $e.name == "write") and .edit_at == null) then
         .edit_at = (if .turns > 0 then .turns else 1 end)
       elif $e.t == "tok" then
         .total_last = ($e.total // .total_last)
         | if .edit_at == null and $e.input != null then .input_before = $e.input else . end
       else . end)) as $r
    | {turns: $r.turns,
       first_edit_turn: $r.edit_at,
       tokens_total: $r.total_last,
       tokens_exploration: $r.input_before,
       files_read: 0,
       unique_files: 0,
       reread_reads: 0,
       three_plus_read_files: 0}'
}

rm_mine_codex() {
  local tmp=$1 start=$2 end=$3 cap=$4
  local root=${FM_RM_CODEX_SESSIONS:-$HOME/.codex/sessions}
  local status=mined seen=0 mined=0 cap_skips=0 empty_skips=0 error_skips=0 scope_skips=0
  local filelist="$tmp/codex-files" eligible="$tmp/codex-eligible" file mtime meta cwd sid ts reduced metrics task_json dir_label
  local invalid_candidates=0

  if [ ! -d "$root" ]; then
    rm_coverage_json codex "$(rm_sanitize_path "$root")" absent 0 0 0 0 0 0
    return 0
  fi
  root=$(rm_physical_dir "$root" 2>/dev/null || true)
  [ -n "$root" ] || { rm_coverage_json codex '<EXTERNAL>' unreadable 0 0 0 0 1 0; return 0; }
  if ! find "$root" -type f -name 'rollout-*.jsonl' -print0 > "$filelist" 2>/dev/null; then
    rm_coverage_json codex "$(rm_sanitize_path "$root")" unreadable 0 0 0 0 1 0
    return 0
  fi
  : > "$eligible"
  while IFS= read -r -d '' file; do
    mtime=$(rm_file_mtime "$file" || true)
    case "$mtime" in ''|*[!0-9]*) invalid_candidates=$((invalid_candidates + 1)); error_skips=$((error_skips + 1)); continue ;; esac
    [ "$mtime" -ge "$start" ] && [ "$mtime" -le "$end" ] || continue
    printf '%s\t%s\n' "$mtime" "$file" >> "$eligible"
  done < "$filelist"
  if [ -s "$eligible" ]; then
    sort -nr -k1,1 "$eligible" -o "$eligible" 2>/dev/null || {
      rm_coverage_json codex "$(rm_sanitize_path "$root")" unreadable 0 0 0 0 1 0
      return 0
    }
  fi

  while IFS=$'\t' read -r mtime file; do
    [ -n "$file" ] || continue
    seen=$((seen + 1))
    if [ "$seen" -gt "$cap" ]; then
      cap_skips=$((cap_skips + 1))
      continue
    fi
    meta=$(sed -n '1p' "$file" 2>/dev/null | jq -ce \
      'select(.type == "session_meta") | {cwd: .payload.cwd, sid: .payload.session_id, ts: (.payload.timestamp // .timestamp)}' \
      2>/dev/null) || { invalid_candidates=$((invalid_candidates + 1)); error_skips=$((error_skips + 1)); continue; }
    cwd=$(printf '%s' "$meta" | jq -r '.cwd // empty')
    sid=$(printf '%s' "$meta" | jq -r '.sid // empty')
    ts=$(printf '%s' "$meta" | jq -r '.ts // empty')
    if [ -z "$cwd" ] || [ -z "$sid" ] || [ -z "$ts" ] || ! rm_iso_to_epoch "$ts" >/dev/null; then
      invalid_candidates=$((invalid_candidates + 1)); error_skips=$((error_skips + 1)); continue
    fi
    case "$(rm_root_matches "$cwd")" in
      1) ;;
      *) scope_skips=$((scope_skips + 1)); continue ;;
    esac
    if ! reduced=$(rm_mine_codex_reduced < "$file" 2>/dev/null); then
      invalid_candidates=$((invalid_candidates + 1)); error_skips=$((error_skips + 1)); continue
    fi
    [ -n "$reduced" ] || { empty_skips=$((empty_skips + 1)); continue; }
    if ! metrics=$(printf '%s\n' "$reduced" | rm_mine_codex_metrics 2>/dev/null); then
      invalid_candidates=$((invalid_candidates + 1)); error_skips=$((error_skips + 1)); continue
    fi
    dir_label=$(rm_sanitize_path "$cwd")
    if ! task_json=$(printf '%s' "$metrics" | jq -c --arg dir "$dir_label" \
      '. + {source: "codex", dir: $dir}' 2>/dev/null); then
      error_skips=$((error_skips + 1))
      continue
    fi
    printf '%s\n' "$task_json" >> "$tmp/tasks.ndjson"
    mined=$((mined + 1))
  done < "$eligible"

  if [ "$mined" -eq 0 ]; then
    if [ "$invalid_candidates" -gt 0 ]; then status=unreadable; else status=empty; fi
  fi
  rm_coverage_json codex "$(rm_sanitize_path "$root")" "$status" "$seen" "$mined" \
    "$cap_skips" "$empty_skips" "$error_skips" "$scope_skips"
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

  tmp=$(rm_new_tmp mine) || rm_die_fail "cannot create a temp dir"
  : > "$tmp/tasks.ndjson"
  : > "$tmp/reads.ndjson"
  : > "$tmp/coverage.ndjson"

  cov=$(rm_mine_opencode "$tmp" "$start" "$end" "$MINE_MAX") || rm_die_fail "opencode mining failed"
  printf '%s\n' "$cov" >> "$tmp/coverage.ndjson"
  cov=$(rm_mine_codex "$tmp" "$start" "$end" "$MINE_MAX") || rm_die_fail "codex mining failed"
  printf '%s\n' "$cov" >> "$tmp/coverage.ndjson"
  coverage=$(jq -sc '.' "$tmp/coverage.ndjson") || rm_die_fail "cannot compose source coverage"
  roots_json=$(jq -cn --argjson pools "$(printf '%s\n' "${RM_EXTRA_ROOTS[@]+${RM_EXTRA_ROOTS[@]}}" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
    '["<HOME>"] + ($pools | map("<POOL>"))') || rm_die_fail "cannot compose root labels"

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
  jq -sr '.[] | "mine: \(.source) \(.status) sessions_seen=\(.sessions_seen) sessions_mined=\(.sessions_mined) skipped_cap=\(.skipped_cap) skipped_empty=\(.skipped_empty) skipped_error=\(.skipped_error)"' "$tmp/coverage.ndjson"
}

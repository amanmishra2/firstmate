# Codex rollout projection and task-span mining.
# Keep rollout projection streaming with `jq inputs`; never slurp historical JSONL rollouts.
# Correlate task events incrementally and emit only completed spans inside the window.

rm_mine_codex_metadata_projection() {
  jq -r '
    def object_or_empty:
      if type == "object" then . else {} end;
    def scalar_id:
      if . == null then ""
      elif type == "string" or type == "number" then tostring
      else "" end;
    def string_or_empty:
      if type == "string" then . else "" end;

    (.payload | object_or_empty) as $payload
    | select(.type == "session_meta")
    | [($payload.cwd | string_or_empty),
       ($payload.session_id | scalar_id)]
    | map(if . == null or . == "" then "__FM_RM_EMPTY__" else . end)
    | @tsv'
}

rm_mine_codex_event_projection() {
  local file=$1
  jq -nr '
    def object_or_empty:
      if type == "object" then . else {} end;
    def scalar_id:
      if . == null then ""
      elif type == "string" or type == "number" then tostring
      else "" end;
    def string_or_empty:
      if type == "string" then . else "" end;
    def output_text:
      if type == "string" then .
      elif type == "array" then
        map(if type == "string" then . elif type == "object" then (.text | string_or_empty) else "" end) | join("\n")
      elif type == "object" then (.text | string_or_empty)
      else "" end;
    def output_has_error:
      output_text | test("(^|[\r\n])[[:space:]]*(error|execution error|failed|failure|patch[[:space:]]+rejected)([[:space:]:]|$)"; "i");
    def number_or_null:
      if type == "number" then . else null end;

    inputs
    | (.payload | object_or_empty) as $payload
    | ($payload.info | object_or_empty) as $info
    | ($info.total_token_usage | object_or_empty) as $total
    | ($info.last_token_usage | object_or_empty) as $last
    | ($payload.item | object_or_empty) as $item
    | if .type == "turn_context" then
      {kind: "turn", cwd: "", sid: "", id: "", name: "",
         total: null, input_cumulative: null, input_last: null, ts: ""}
      elif .type == "response_item" and ($payload.type // "") == "function_call" then
        {kind: "call", cwd: "", sid: "",
         id: ($payload.call_id | scalar_id),
         name: ($payload.name | string_or_empty),
         total: null, input_cumulative: null, input_last: null, ts: ""}
      elif .type == "response_item" and ($payload.type // "") == "function_call_output" then
        {kind: "output", cwd: "", sid: "",
         id: ($payload.call_id | scalar_id),
         item_id: ($payload.id | scalar_id),
         name: "", total: null, input_cumulative: null, input_last: null, ts: ""}
      elif .type == "event_msg" and ($payload.type // "") == "token_count" then
        {kind: "token", cwd: "", sid: "", id: "", name: "",
         total: ($total.total_tokens | number_or_null),
         input_cumulative: (($total.input_tokens | number_or_null)
                            // ($total.prompt_tokens | number_or_null)),
         input_last: (($last.input_tokens | number_or_null)
                      // ($last.prompt_tokens | number_or_null)),
         ts: ""}
      elif .type == "event_msg" and ($payload.type // "") == "task_started" then
        {kind: "start", cwd: "", sid: "",
         id: ($payload.turn_id | scalar_id), name: "",
         total: null, input_cumulative: null, input_last: null, ts: ""}
      elif .type == "event_msg" and ($payload.type // "") == "task_complete" then
        {kind: "complete", cwd: "", sid: "",
         id: ($payload.turn_id | scalar_id), name: "",
         total: null, input_cumulative: null, input_last: null,
         ts: (.timestamp | string_or_empty)}
      elif .type == "event_msg" and ($payload.type // "") == "item_started"
           and ($item.type // "") == "DynamicToolCall"
           and (($item.tool // "") == "write" or ($item.tool // "") == "apply_patch") then
        {kind: "call", cwd: "", sid: "",
         id: ($item.id | scalar_id), name: ($item.tool | string_or_empty),
         total: null, input_cumulative: null, input_last: null, ts: ""}
      elif .type == "event_msg" and ($payload.type // "") == "item_completed"
           and ($item.type // "") == "FileChange" then
        {kind: "edit_outcome", cwd: "", sid: "",
         id: ($item.id | scalar_id), name: "",
         success: (if ($item.status // "") == "completed" then "true" else "false" end),
         total: null, input_cumulative: null, input_last: null, ts: ""}
      elif .type == "event_msg" and ($payload.type // "") == "item_completed"
           and ($item.type // "") == "DynamicToolCall" then
        {kind: "edit_outcome", cwd: "", sid: "",
         id: ($item.id | scalar_id), name: "",
         success: (if ($item.status // "") == "completed" and $item.success == true then "true" else "false" end),
         total: null, input_cumulative: null, input_last: null, ts: ""}
      elif .type == "event_msg" and ($payload.type // "") == "item_completed"
           and ($item.type // "") == "FunctionCallOutput" then
        {kind: "item_completed", cwd: "", sid: "",
         id: ($item.id | scalar_id), name: "",
         success: (if (($item.output // "") | output_has_error) then "false" else "true" end),
         total: null, input_cumulative: null, input_last: null, ts: ""}
      else
        empty
      end
    | [.kind, .cwd, .sid, .id, .name, (.item_id // ""), (.success // ""),
       (if .total == null then "" else (.total | tostring) end),
       (if .input_cumulative == null then "" else (.input_cumulative | tostring) end),
       (if .input_last == null then "" else (.input_last | tostring) end), .ts]
    | map(if . == null or . == "" then "__FM_RM_EMPTY__" else . end)
    | @tsv' "$file"
}

rm_mine_codex_rollout() {
  local file=$1 start=$2 end=$3 tasks_out=$4 events_out=$5 dir_label=$6
  local line event kind cwd sid id name item_id success total input_cum input_last ts empty_field="__FM_RM_EMPTY__"
  local active=0 current_id="" turns=0 edit_at=""
  local rollout_total_last=0 rollout_input_cum_last=0
  local task_total_base=0 task_input_base=0 task_total_last=0
  local task_input_cum_last=0 task_input_cum_seen=0 task_input_fallback_sum=0
  local edit_input_cum=0 edit_input_cum_seen=0 edit_input_fallback_sum=0
  local parse_error=0 rows=0 completion_epoch edit_json=""
  local total_delta=0 input_delta=0
  local pending_ids=() pending_turns=() pending_item_ids=()
  local kept_ids=() kept_turns=() kept_item_ids=()
  local pending_index=0 pending_j=0 completion_kind="" completion_success=""

  : > "$tasks_out" || return 1
  : > "$events_out" || return 1
  if ! rm_mine_codex_event_projection "$file" > "$events_out" 2>/dev/null; then
    printf 'error\t0\t0\t0\t%s\n' "$dir_label"
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    event=$line
    IFS=$'\t' read -r kind cwd sid id name item_id success total input_cum input_last ts <<EOF
$event
EOF
    [ "$cwd" = "$empty_field" ] && cwd=""
    [ "$sid" = "$empty_field" ] && sid=""
    [ "$id" = "$empty_field" ] && id=""
    [ "$name" = "$empty_field" ] && name=""
    [ "$item_id" = "$empty_field" ] && item_id=""
    [ "$success" = "$empty_field" ] && success=""
    [ "$total" = "$empty_field" ] && total=""
    [ "$input_cum" = "$empty_field" ] && input_cum=""
    [ "$input_last" = "$empty_field" ] && input_last=""
    [ "$ts" = "$empty_field" ] && ts=""

    case "$kind" in
      start)
        active=0
        current_id=""
        turns=0
        edit_at=""
        task_total_base=0
        task_input_base=0
        task_total_last=0
        task_input_cum_last=0
        task_input_cum_seen=0
        task_input_fallback_sum=0
        edit_input_cum=0
        edit_input_cum_seen=0
        edit_input_fallback_sum=0
        pending_ids=()
        pending_turns=()
        pending_item_ids=()
        if [ -z "$id" ]; then
          parse_error=1
          continue
        fi
        task_total_base=$rollout_total_last
        task_input_base=$rollout_input_cum_last
        task_total_last=$rollout_total_last
        active=1
        current_id=$id
        ;;
      turn)
        [ "$active" -eq 1 ] || continue
        turns=$((turns + 1))
        ;;
      token)
        case "$total" in
          ''|*[!0-9]*) ;;
          *)
            rollout_total_last=$total
            [ "$active" -eq 1 ] && task_total_last=$total
            ;;
        esac
        case "$input_cum" in
          ''|*[!0-9]*) ;;
          *)
            rollout_input_cum_last=$input_cum
            if [ "$active" -eq 1 ] && [ -z "$edit_at" ]; then
              task_input_cum_last=$input_cum
              task_input_cum_seen=1
            fi
            ;;
        esac
        if [ "$active" -eq 1 ] && [ -z "$edit_at" ]; then
          case "$input_last" in
            ''|*[!0-9]*) ;;
            *) task_input_fallback_sum=$((task_input_fallback_sum + input_last)) ;;
          esac
        fi
        ;;
      call)
        [ "$active" -eq 1 ] || continue
        [ -n "$id" ] || continue
        case "$name" in
          apply_patch|write)
            pending_ids+=("$id")
            if [ "$turns" -gt 0 ]; then
              pending_turns+=("$turns")
            else
              pending_turns+=(1)
            fi
            pending_item_ids+=("")
            ;;
        esac
        ;;
      output)
        [ "$active" -eq 1 ] || continue
        [ -n "$id" ] && [ -n "$item_id" ] || continue
        pending_index=0
        while [ "$pending_index" -lt "${#pending_ids[@]}" ]; do
          if [ "${pending_ids[$pending_index]}" = "$id" ]; then
            pending_item_ids[$pending_index]=$item_id
            break
          fi
          pending_index=$((pending_index + 1))
        done
        ;;
      item_completed|edit_outcome)
        [ "$active" -eq 1 ] || continue
        [ -n "$id" ] || continue
        if [ "$kind" = "item_completed" ]; then
          completion_kind=item
          completion_success=$success
        else
          completion_kind=call
          completion_success=$success
        fi
        pending_index=0
        while [ "$pending_index" -lt "${#pending_ids[@]}" ]; do
          if { [ "$completion_kind" = "item" ] && [ "${pending_item_ids[$pending_index]}" = "$id" ]; } ||
             { [ "$completion_kind" = "call" ] && [ "${pending_ids[$pending_index]}" = "$id" ]; }; then
            if [ "$completion_success" = "true" ] && [ -z "$edit_at" ]; then
              edit_at=${pending_turns[$pending_index]}
              if [ "$task_input_cum_seen" -eq 1 ]; then
                edit_input_cum=$task_input_cum_last
                edit_input_cum_seen=1
              else
                edit_input_fallback_sum=$task_input_fallback_sum
              fi
            fi
            kept_ids=()
            kept_turns=()
            kept_item_ids=()
            pending_j=0
            while [ "$pending_j" -lt "${#pending_ids[@]}" ]; do
              if [ "$pending_j" -ne "$pending_index" ]; then
                kept_ids+=("${pending_ids[$pending_j]}")
                kept_turns+=("${pending_turns[$pending_j]}")
                kept_item_ids+=("${pending_item_ids[$pending_j]}")
              fi
              pending_j=$((pending_j + 1))
            done
            if [ "${#kept_ids[@]}" -gt 0 ]; then
              pending_ids=("${kept_ids[@]}")
              pending_turns=("${kept_turns[@]}")
              pending_item_ids=("${kept_item_ids[@]}")
            else
              pending_ids=()
              pending_turns=()
              pending_item_ids=()
            fi
            break
          fi
          pending_index=$((pending_index + 1))
        done
        ;;
      complete)
        [ -n "$id" ] || { parse_error=1; continue; }
        [ -n "$ts" ] || { parse_error=1; continue; }
        [ "$active" -eq 1 ] || continue
        [ "$id" = "$current_id" ] || continue
        if ! completion_epoch=$(rm_iso_to_epoch "$ts"); then
          parse_error=1
          continue
        fi
        total_delta=$((task_total_last - task_total_base))
        [ "$total_delta" -lt 0 ] && total_delta=0
        if [ -n "$edit_at" ]; then
          if [ "$edit_input_cum_seen" -eq 1 ]; then
            input_delta=$((edit_input_cum - task_input_base))
            [ "$input_delta" -lt 0 ] && input_delta=0
          else
            input_delta=$edit_input_fallback_sum
          fi
        elif [ "$task_input_cum_seen" -eq 1 ]; then
          input_delta=$((task_input_cum_last - task_input_base))
          [ "$input_delta" -lt 0 ] && input_delta=0
        else
          input_delta=$task_input_fallback_sum
        fi
        if [ "$completion_epoch" -ge "$start" ] && [ "$completion_epoch" -le "$end" ]; then
          if [ -n "$edit_at" ]; then edit_json=$edit_at; else edit_json=null; fi
          if ! jq -cn \
            --argjson turns "$turns" --argjson edit "$edit_json" \
            --argjson total "$total_delta" --argjson input "$input_delta" \
            '{turns: $turns,
              first_edit_turn: $edit,
              tokens_total: $total,
              tokens_exploration: $input,
              files_read: 0,
              unique_files: 0,
              reread_reads: 0,
              three_plus_read_files: 0}' >> "$tasks_out"; then
            return 1
          fi
          rows=$((rows + 1))
        fi
        active=0
        current_id=""
        turns=0
        edit_at=""
        task_total_base=0
        task_input_base=0
        task_total_last=0
        task_input_cum_last=0
        task_input_cum_seen=0
        task_input_fallback_sum=0
        edit_input_cum=0
        edit_input_cum_seen=0
        edit_input_fallback_sum=0
        pending_ids=()
        pending_turns=()
        pending_item_ids=()
        ;;
    esac
  done < "$events_out"

  if [ "$parse_error" -eq 1 ]; then
    printf 'error\t0\t0\t0\t%s\n' "$dir_label"
  elif [ "$rows" -gt 0 ]; then
    printf 'ok\t%s\t0\t0\t%s\n' "$rows" "$dir_label"
  else
    printf 'empty\t0\t0\t0\t%s\n' "$dir_label"
  fi
}

rm_mine_codex() {
  local tmp=$1 start=$2 end=$3
  local root=${FM_RM_CODEX_SESSIONS:-$FM_HOME/.codex/sessions} physical
  local status=mined seen=0 mined=0 empty_skips=0 error_skips=0 scope_skips=0
  local filelist="$tmp/codex-files" file result result_status result_rows result_error result_scope dir_label
  local rollout_tasks="$tmp/codex-rollout-tasks.ndjson" rollout_events="$tmp/codex-rollout-events.tsv"
  local rollout_projected="$tmp/codex-rollout-projected.ndjson"
  local meta_line metadata cwd sid empty_field="__FM_RM_EMPTY__"
  local metrics task_json projection_failed
  local invalid_candidates=0

  physical=$(rm_resolve_source_path "$root" 2>/dev/null || true)
  if [ -z "$physical" ]; then
    rm_coverage_json codex '<EXTERNAL>' unreadable 0 0 0 1 0
    return 0
  fi
  if ! rm_path_in_home "$physical"; then
    rm_coverage_json codex '<EXTERNAL>' outside-home 0 0 0 0 0 0
    return 0
  fi
  root=$physical
  if [ ! -d "$root" ]; then
    rm_coverage_json codex "$(rm_sanitize_path "$root")" absent 0 0 0 0 0 0
    return 0
  fi
  if ! find "$root" -type f -name 'rollout-*.jsonl' -print0 > "$filelist" 2>/dev/null; then
    rm_coverage_json codex "$(rm_sanitize_path "$root")" unreadable 0 0 0 1 0
    return 0
  fi
  while IFS= read -r -d '' file; do
    [ -n "$file" ] || continue
    meta_line=""
    if ! IFS= read -r meta_line < "$file"; then
      [ -n "$meta_line" ] || {
        invalid_candidates=$((invalid_candidates + 1))
        error_skips=$((error_skips + 1))
        continue
      }
    fi
    if ! metadata=$(printf '%s\n' "$meta_line" | rm_mine_codex_metadata_projection 2>/dev/null); then
      invalid_candidates=$((invalid_candidates + 1))
      error_skips=$((error_skips + 1))
      continue
    fi
    cwd=""
    sid=""
    IFS=$'\t' read -r cwd sid <<EOF
$metadata
EOF
    [ "$cwd" = "$empty_field" ] && cwd=""
    [ "$sid" = "$empty_field" ] && sid=""
    if [ -z "$cwd" ] || [ -z "$sid" ]; then
      invalid_candidates=$((invalid_candidates + 1))
      error_skips=$((error_skips + 1))
      continue
    fi
    case "$cwd" in
      /*) ;;
      *)
        invalid_candidates=$((invalid_candidates + 1))
        error_skips=$((error_skips + 1))
        continue
        ;;
    esac
    case "$(rm_root_matches "$cwd")" in
      1) dir_label=$(rm_sanitize_home_area "$cwd") ;;
      *)
        scope_skips=$((scope_skips + 1))
        continue
        ;;
    esac
    result=$(rm_mine_codex_rollout "$file" "$start" "$end" "$rollout_tasks" "$rollout_events" "$dir_label" 2>/dev/null) || {
      invalid_candidates=$((invalid_candidates + 1))
      error_skips=$((error_skips + 1))
      continue
    }
    IFS=$'\t' read -r result_status result_rows result_error result_scope dir_label <<EOF
$result
EOF
    case "$result_status" in
      scope)
        scope_skips=$((scope_skips + 1))
        continue
        ;;
      error)
        invalid_candidates=$((invalid_candidates + 1))
        error_skips=$((error_skips + 1))
        continue
        ;;
      empty)
        empty_skips=$((empty_skips + 1))
        continue
        ;;
      ok) ;;
      *)
        invalid_candidates=$((invalid_candidates + 1))
        error_skips=$((error_skips + 1))
        continue
        ;;
    esac
    seen=$((seen + 1))
    : > "$rollout_projected" || {
      error_skips=$((error_skips + 1))
      continue
    }
    projection_failed=0
    while IFS= read -r metrics; do
      [ -n "$metrics" ] || continue
      if ! task_json=$(printf '%s' "$metrics" | jq -c --arg dir "$dir_label" \
        '. + {source: "codex", dir: $dir}' 2>/dev/null); then
        projection_failed=1
        break
      fi
      if ! printf '%s\n' "$task_json" >> "$rollout_projected"; then
        projection_failed=1
        break
      fi
    done < "$rollout_tasks"
    if [ "$projection_failed" -eq 1 ]; then
      error_skips=$((error_skips + 1))
      continue
    fi
    if ! cat "$rollout_projected" >> "$tmp/tasks.ndjson"; then
      error_skips=$((error_skips + 1))
      continue
    fi
    mined=$((mined + 1))
  done < "$filelist"

  if [ "$mined" -eq 0 ]; then
    if [ "$invalid_candidates" -gt 0 ] || [ "$error_skips" -gt 0 ]; then status=unreadable; else status=empty; fi
  fi
  rm_coverage_json codex "$(rm_sanitize_path "$root")" "$status" "$seen" "$mined" \
    "$empty_skips" "$error_skips" "$scope_skips"
}

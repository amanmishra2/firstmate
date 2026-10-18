#!/usr/bin/env bash
# fm-repo-maintenance.sh - the repo-maintenance instrument: mine aggregate
# session read metrics, rank files by Token Heat Index, audit a repository
# against the structure standard, and write a project's weekly maintenance
# report.
#
# Usage:
#   fm-repo-maintenance.sh mine [--window-days N] [--now EPOCH] [--out PATH] [--source NAME]...
#   fm-repo-maintenance.sh rank [--metrics PATH] [--project NAME] [--top N] [--json]
#   fm-repo-maintenance.sh structure <root-dir> [--max-findings N] [--json]
#   fm-repo-maintenance.sh sweep <project> [--date YYYY-MM-DD] [--max-findings N] [--force]
#   fm-repo-maintenance.sh --help
#
# mine scans the structured session stores for work under this home's roots
# inside the window (default 7 days) and writes aggregate read metrics to
# data/repo-maintenance/metrics/<UTC-date>.json (schema
# fm-repo-maintenance-metrics.v1). It records aggregates only: prompts, diffs,
# message text, and tool outputs are never copied into outputs, file paths
# under the home or pool roots are stored as a scope plus repo-relative path,
# and every other path is counted in an external bucket with no path stored.
# The metric definitions, sanitization guard, and Token Heat Index belong to
# .agents/skills/repo-maintenance/references/token-efficiency.md.
#
# Sources, each reported in coverage even when skipped:
#   opencode  the OpenCode v2 store (default
#             $HOME/.local/share/opencode/opencode.db): per-task read, edit,
#             and token metrics from session_v2 and session_message. Needs
#             sqlite3; skipped with a named coverage line when absent,
#             unreadable, or holding no session in the window.
#   codex     Codex rollout JSONL under $HOME/.codex/sessions: session-level
#             metrics only. Codex reads files through the shell, which carries
#             no structured file attribution, so this source contributes no
#             file rows and never guesses paths out of commands.
#
# Session scope: a session counts when its working directory is under the home,
# a project clone, or one of FM_RM_SESSION_ROOTS (default $HOME/.treehouse).
# Environment seams: FM_RM_OPENCODE_DB, FM_RM_CODEX_SESSIONS,
# FM_RM_SESSION_ROOTS (colon-separated extra roots), FM_RM_MAX_SESSIONS
# (default 250, newest first), FM_RM_NOW (frozen epoch).
#
# rank reads the newest metrics file (or --metrics PATH), resolves each
# recorded file against its scope root (firstmate -> the code root;
# projects/<name> -> the projects clone), and prints the Token Heat Index
# ranking: THI = unique task reads x total reads x file token size, with token
# size taken as bytes/4 from the working tree and falling back to the largest
# observed read payload for files that no longer exist. A ranked file is
# prioritized when it exceeds the 500-line soft ceiling or its folder carries
# no SUMMARY.md; the top three prioritized files are the "fix next" set.
#
# structure audits <root-dir> (a git work tree) against the structure standard
# in .agents/skills/repo-maintenance/references/structure-standard.md:
# tracked code files over the 500-line soft ceiling (minus exemptions recorded
# one per line as "<path> :: <reason>" in
# data/repo-maintenance/<root-name>/exemptions.txt), src/ trees deeper than
# four levels, directories missing SUMMARY.md, tracked files not named by
# their folder's SUMMARY.md, summaries over 30 lines, and root entrypoints.
# It is read-only.
#
# sweep resolves <project> (a data/projects.md registry name, or "firstmate"
# for this code root), composes the instrument sections of
# data/repo-maintenance/<project>/<date>/report.md per the report shape owned
# by references/audit-playbook.md, and leaves the qualitative sections pending
# for the maintenance pass. It refuses to overwrite an existing report
# without --force.
#
# Exit codes: 0 ok, 2 usage or refusal, 1 runtime failure.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

RM_DATA="$DATA/repo-maintenance"
METRICS_DIR="$RM_DATA/metrics"
SOFT_CEILING_LINES=500
SUMMARY_MAX_LINES=30
DEPTH_MAX_BELOW_SRC=4

DEFAULT_WINDOW_DAYS=7
DEFAULT_MAX_SESSIONS=250
DEFAULT_TOP=10
DEFAULT_MAX_FINDINGS=30

# One cleanup registry for every temp dir a verb creates, so nested helpers
# never steal each other's EXIT trap.
CLEANUP_DIRS=""
cleanup_all() {
  local d
  [ -n "$CLEANUP_DIRS" ] || return 0
  for d in $CLEANUP_DIRS; do
    [ -n "$d" ] && rm -rf "$d"
  done
  CLEANUP_DIRS=""
}
trap cleanup_all EXIT INT TERM HUP

new_tmp() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/fm-repo-maintenance-$1.XXXXXX") || return 1
  CLEANUP_DIRS="$CLEANUP_DIRS $d"
  printf '%s\n' "$d"
}

usage() {
  cat <<'EOF'
Usage:
  fm-repo-maintenance.sh mine [--window-days N] [--now EPOCH] [--out PATH] [--source NAME]...
  fm-repo-maintenance.sh rank [--metrics PATH] [--project NAME] [--top N] [--json]
  fm-repo-maintenance.sh structure <root-dir> [--max-findings N] [--json]
  fm-repo-maintenance.sh sweep <project> [--date YYYY-MM-DD] [--max-findings N] [--force]
  fm-repo-maintenance.sh --help

mine writes aggregate session read metrics (no prompts, diffs, or tool output).
rank prints the Token Heat Index "fix next" ranking from the newest metrics.
structure audits a git work tree against the structure standard (read-only).
sweep composes data/repo-maintenance/<project>/<date>/report.md.
See the script header for sources, scope, environment seams, and schemas.
EOF
}

die_usage() {
  printf 'fm-repo-maintenance: %s\n' "$1" >&2
  usage >&2
  exit 2
}

die_refuse() {
  printf 'fm-repo-maintenance: %s\n' "$1" >&2
  exit 2
}

die_fail() {
  printf 'fm-repo-maintenance: %s\n' "$1" >&2
  exit 1
}

require_jq() {
  command -v jq >/dev/null 2>&1 || die_fail "jq is required"
}

epoch_to_date() {
  date -u -r "$1" +%Y-%m-%d 2>/dev/null || date -u -d "@$1" +%Y-%m-%d
}

iso_to_epoch() {
  local ts=$1 out
  out=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "${ts%%.*}" +%s 2>/dev/null) \
    || out=$(date -u -d "$ts" +%s 2>/dev/null) \
    || return 1
  printf '%s\n' "$out"
}

# Shared jq prelude: the executable statement of the path classification and
# sanitization rules owned by references/token-efficiency.md.
# shellcheck disable=SC2016  # jq program text: $home and $extras are jq variables.
CLASSIFY_JQ='
def classify_path($home; $extras):
  (if ($home != "" and startswith($home + "/projects/")) then
     (ltrimstr($home + "/projects/") | split("/")) as $p
     | {scope: ("projects/" + $p[0]), path: ($p[1:] | join("/"))}
   elif ($home != "" and startswith($home + "/")) then
     {scope: "firstmate", path: ltrimstr($home + "/")}
   else null end)
  //
  ([ $extras[] as $x
     | if startswith($x + "/") then
         (ltrimstr($x + "/") | split("/")) as $p
         | if ($p | length) >= 3 and $p[2] == "firstmate" then
             {scope: "firstmate", path: ($p[3:] | join("/"))}
           elif ($p | length) >= 3 then
             {scope: ("projects/" + $p[2]), path: ($p[3:] | join("/"))}
           else null end
       else null end ] | map(select(. != null)) | first);
def sdir($home; $extras):
  if ($home != "" and startswith($home)) then "<HOME>" + ltrimstr($home)
  else ([ $extras[] as $x | if startswith($x) then "<POOL>" + ltrimstr($x) else empty end ] | first // "<EXTERNAL>")
  end;
'

# Per-session opencode extraction over the sqlite3 -json rows for one session.
# Token counters repeat once per content part, so every per-seq value is
# counted exactly once; reads count per read tool part. Defs and body stay
# separate because a jq def cannot be wrapped in parentheses by the caller.
# shellcheck disable=SC2016  # jq program text: $r, $k, and friends are jq variables.
OPENCODE_SESSION_DEFS='
def tok: ((.ti // 0) + (.to_ // 0) + (.tr // 0) + (.tcr // 0) + (.tcw // 0));
def is_edit: (.pname == "edit" or .pname == "write" or .pname == "patch" or .pname == "apply_patch");
'
# shellcheck disable=SC2016  # jq program text: $turns and $ei are jq variables.
OPENCODE_SESSION_BODY='
(reduce .[] as $r ({};
   ($r.seq | tostring) as $k
   | (.[$k] // {tokens: ($r | tok), edit: false, reads: {}}) as $cur
   | .[$k] = ($cur
       | .edit = (.edit or ($r | is_edit))
       | if ($r.pname == "read" and $r.fpath != null) then
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
     tokens_exploration: ([ $turns[0:($ei // ($turns | length))][].value.tokens ] | add // 0),
     files_read: ([ $turns[].value.reads[] ] | add // 0),
     unique_files: ([ $turns[].value.reads | keys[] ] | unique | length),
     reread_files: ([ $turns[].value.reads | to_entries[] ] | group_by(.key) | map([.[].value] | add) | map(select(. >= 3)) | length)
   },
   reads: [ $turns[].value.reads | to_entries[] | {path: .key, count: .value} ]}
'

# ---------------------------------------------------------------------------
# mine

MINE_WINDOW_DAYS=$DEFAULT_WINDOW_DAYS
MINE_NOW=""
MINE_OUT=""
MINE_SOURCES=""
MINE_MAX=${FM_RM_MAX_SESSIONS:-$DEFAULT_MAX_SESSIONS}
case "$MINE_MAX" in ''|*[!0-9]*) MINE_MAX=$DEFAULT_MAX_SESSIONS ;; esac
EXTRA_ROOTS=()
EXTRA_ROOTS_JSON="[]"

parse_mine_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --window-days)
        [ "$#" -ge 2 ] || die_usage "--window-days requires a value"
        case "$2" in ''|*[!0-9]*) die_usage "--window-days must be 1..90" ;; esac
        [ "$2" -ge 1 ] && [ "$2" -le 90 ] || die_usage "--window-days must be 1..90"
        MINE_WINDOW_DAYS=$2
        shift 2
        ;;
      --now)
        [ "$#" -ge 2 ] || die_usage "--now requires an epoch"
        case "$2" in ''|*[!0-9]*) die_usage "--now must be an epoch in seconds" ;; esac
        MINE_NOW=$2
        shift 2
        ;;
      --out)
        [ "$#" -ge 2 ] || die_usage "--out requires a path"
        MINE_OUT=$2
        shift 2
        ;;
      --source)
        [ "$#" -ge 2 ] || die_usage "--source requires a name"
        case "$2" in opencode|codex) ;; *) die_usage "unknown source '$2' (opencode, codex)" ;; esac
        MINE_SOURCES="$MINE_SOURCES $2"
        shift 2
        ;;
      *)
        die_usage "unknown argument '$1'"
        ;;
    esac
  done
}

mine_source_enabled() {
  local want=$1 s
  [ -z "$MINE_SOURCES" ] && return 0
  for s in $MINE_SOURCES; do
    [ "$s" = "$want" ] && return 0
  done
  return 1
}

# sanitize_path <path>: map local prefixes to their stable labels for every
# recorded or printed path (<HOME> for the home and the OS home, <POOL> for an
# extra root; anything else is left as-is).
sanitize_path() {
  local p=$1 x
  case "$p" in
    "$FM_HOME"|"$FM_HOME"/*) printf '<HOME>%s\n' "${p#"$FM_HOME"}"; return 0 ;;
    "$HOME"|"$HOME"/*) printf '<HOME>%s\n' "${p#"$HOME"}"; return 0 ;;
  esac
  for x in "${EXTRA_ROOTS[@]}"; do
    case "$p" in
      "$x"|"$x"/*) printf '<POOL>%s\n' "${p#"$x"}"; return 0 ;;
    esac
  done
  printf '%s\n' "$p"
}

# root_matches <dir>: print 1 when <dir> is under the home or an extra root.
root_matches() {
  local dir=$1 x
  case "$dir" in
    "$FM_HOME"|"$FM_HOME"/*) printf '1\n'; return 0 ;;
  esac
  for x in "${EXTRA_ROOTS[@]}"; do
    case "$dir" in
      "$x"|"$x"/*) printf '1\n'; return 0 ;;
    esac
  done
  printf '0\n'
}

# mine_opencode <tmp> <start> <end> <cap>: append task NDJSON to
# <tmp>/tasks.ndjson and read-event NDJSON to <tmp>/reads.ndjson; print one
# coverage JSON object.
mine_opencode() {
  local tmp=$1 start=$2 end=$3 cap=$4
  local db=${FM_RM_OPENCODE_DB:-${XDG_DATA_HOME:-$HOME/.local/share}/opencode/opencode.db}
  local status="mined" seen=0 mined=0 cap_skips=0 empty_skips=0 error_skips=0
  local sid slug dir sid_esc rows task_json
  local start_ms=$((start * 1000)) end_ms=$((end * 1000))

  if [ ! -f "$db" ]; then
    jq -n --arg source opencode --arg path "$(sanitize_path "$db")" --arg status absent \
      '{source: $source, path: $path, status: $status, sessions_seen: 0, sessions_mined: 0, skipped_cap: 0, skipped_empty: 0, skipped_error: 0}'
    return 0
  fi
  if ! command -v sqlite3 >/dev/null 2>&1; then
    jq -n --arg source opencode --arg path "$(sanitize_path "$db")" --arg status "sqlite3-missing" \
      '{source: $source, path: $path, status: $status, sessions_seen: 0, sessions_mined: 0, skipped_cap: 0, skipped_empty: 0, skipped_error: 0}'
    return 0
  fi
  if ! sqlite3 -readonly "$db" 'SELECT 1' >/dev/null 2>&1; then
    jq -n --arg source opencode --arg path "$(sanitize_path "$db")" --arg status "unreadable" \
      '{source: $source, path: $path, status: $status, sessions_seen: 0, sessions_mined: 0, skipped_cap: 0, skipped_empty: 0, skipped_error: 0}'
    return 0
  fi

  while IFS=$'\t' read -r sid slug dir; do
    [ -n "$sid" ] || continue
    case "$(root_matches "$dir")" in
      1) ;;
      *) continue ;;
    esac
    seen=$((seen + 1))
    if [ "$seen" -gt "$cap" ]; then
      cap_skips=$((cap_skips + 1))
      continue
    fi
    sid_esc=${sid//\'/\'\'}
    rows=$(sqlite3 -readonly -json "$db" "
      SELECT m.seq AS seq,
             json_extract(m.data,'\$.tokens.input') AS ti,
             json_extract(m.data,'\$.tokens.output') AS to_,
             json_extract(m.data,'\$.tokens.reasoning') AS tr,
             json_extract(m.data,'\$.tokens.cache.read') AS tcr,
             json_extract(m.data,'\$.tokens.cache.write') AS tcw,
             json_extract(p.value,'\$.type') AS ptype,
             json_extract(p.value,'\$.name') AS pname,
             json_extract(p.value,'\$.state.input.path') AS fpath,
             length(json_extract(p.value,'\$.state.content[0].text')) AS outlen
      FROM session_message m
      LEFT JOIN json_each(m.data,'\$.content') p ON true
      WHERE m.session_id = '$sid_esc' AND m.type = 'assistant'
        AND m.time_created >= $start_ms AND m.time_created <= $end_ms
      ORDER BY m.seq;" 2>/dev/null) || { error_skips=$((error_skips + 1)); continue; }
    [ -n "$rows" ] || { empty_skips=$((empty_skips + 1)); continue; }

    task_json=$(printf '%s' "$rows" | jq -c --arg id "$sid" --arg slug "$slug" --arg dir "$dir" \
      "$( # shellcheck disable=SC2016
        printf '%s\n%s\n(%s) | .task + {id: $id, slug: $slug, source: "opencode", dir: ($dir | sdir($home; $extras))}\n' \
        "$CLASSIFY_JQ" "$OPENCODE_SESSION_DEFS" "$OPENCODE_SESSION_BODY")" \
      --arg home "$FM_HOME" --argjson extras "$EXTRA_ROOTS_JSON" 2>/dev/null) || { error_skips=$((error_skips + 1)); continue; }
    [ -n "$task_json" ] || { error_skips=$((error_skips + 1)); continue; }

    printf '%s\n' "$task_json" >> "$tmp/tasks.ndjson"
    printf '%s' "$rows" | jq -c --arg id "$sid" '
       .[] | select(.pname == "read" and .fpath != null)
       | {s: $id, p: .fpath, b: (.outlen // 0)}' 2>/dev/null >> "$tmp/reads.ndjson" || true
    mined=$((mined + 1))
  done < <(sqlite3 -readonly -separator $'\t' "$db" "
      SELECT id, slug, directory FROM session_v2
      WHERE time_updated >= $start_ms AND time_updated <= $end_ms
      ORDER BY time_updated DESC;" 2>/dev/null)

  jq -n --arg source opencode --arg path "$(sanitize_path "$db")" --arg status "$status" \
    --argjson seen "$seen" --argjson mined "$mined" \
    --argjson cap "$cap_skips" --argjson empty "$empty_skips" --argjson error "$error_skips" \
    '{source: $source, path: $path, status: $status,
      sessions_seen: $seen, sessions_mined: $mined,
      skipped_cap: $cap, skipped_empty: $empty, skipped_error: $error}'
}

# mine_codex <tmp> <start> <end> <cap>: session-level metrics only.
mine_codex() {
  local tmp=$1 start=$2 end=$3 cap=$4
  local root=${FM_RM_CODEX_SESSIONS:-$HOME/.codex/sessions}
  local status="mined" seen=0 mined=0 cap_skips=0 empty_skips=0 error_skips=0
  local file meta cwd sid ts ts_epoch reduced metrics task_json

  if [ ! -d "$root" ]; then
    jq -n --arg source codex --arg path "$(sanitize_path "$root")" --arg status absent \
      '{source: $source, path: $path, status: $status, sessions_seen: 0, sessions_mined: 0, skipped_cap: 0, skipped_empty: 0, skipped_error: 0}'
    return 0
  fi

  while IFS= read -r file; do
    [ -n "$file" ] || continue
    meta=$(head -n 1 "$file" 2>/dev/null | jq -c 'select(.type == "session_meta") | {cwd: .payload.cwd, sid: .payload.session_id, ts: .payload.timestamp}' 2>/dev/null) || continue
    [ -n "$meta" ] || continue
    cwd=$(printf '%s' "$meta" | jq -r '.cwd // empty')
    sid=$(printf '%s' "$meta" | jq -r '.sid // empty')
    ts=$(printf '%s' "$meta" | jq -r '.ts // empty')
    [ -n "$cwd" ] && [ -n "$sid" ] && [ -n "$ts" ] || continue
    case "$(root_matches "$cwd")" in
      1) ;;
      *) continue ;;
    esac
    ts_epoch=$(iso_to_epoch "$ts") || continue
    [ "$ts_epoch" -ge "$start" ] && [ "$ts_epoch" -le "$end" ] || continue
    seen=$((seen + 1))
    if [ "$seen" -gt "$cap" ]; then
      cap_skips=$((cap_skips + 1))
      continue
    fi

    reduced=$(jq -c '
      if .type == "session_meta" then {t: "meta"}
      elif .type == "turn_context" then {t: "turn"}
      elif (.type == "event_msg" and .payload.type == "token_count") then
        {t: "tok", v: (.payload.info.total_token_usage.total_tokens // null)}
      elif (.type == "response_item" and .payload.type == "function_call") then
        {t: "call", name: .payload.name}
      else empty end' "$file" 2>/dev/null) || { error_skips=$((error_skips + 1)); continue; }
    [ -n "$reduced" ] || { empty_skips=$((empty_skips + 1)); continue; }

    metrics=$(printf '%s\n' "$reduced" | jq -s '
      (reduce .[] as $e ({turns: 0, edit_at: null, tok_last: null, tok_at_edit: null};
           if $e.t == "turn" then .turns = (.turns + 1)
           elif ($e.t == "call" and ($e.name == "apply_patch" or $e.name == "write") and .edit_at == null) then
             .edit_at = (if .turns > 0 then .turns else 1 end)
           elif ($e.t == "tok" and $e.v != null) then
             .tok_last = $e.v
             | if .edit_at == null then .tok_at_edit = $e.v else . end
           else . end)) as $r
      | {turns: $r.turns,
         first_edit_turn: $r.edit_at,
         tokens_total: ($r.tok_last // 0),
         tokens_exploration: ($r.tok_at_edit // $r.tok_last // 0)}' 2>/dev/null) || { error_skips=$((error_skips + 1)); continue; }
    [ -n "$metrics" ] || { error_skips=$((error_skips + 1)); continue; }

    task_json=$(printf '%s' "$metrics" | jq -c --arg id "$sid" --arg dir "$cwd" \
      "$CLASSIFY_JQ"'
       . + {id: $id, slug: "", source: "codex", dir: ($dir | sdir($home; $extras)),
            files_read: 0, unique_files: 0, reread_files: 0}
      ' --arg home "$FM_HOME" --argjson extras "$EXTRA_ROOTS_JSON" 2>/dev/null) || { error_skips=$((error_skips + 1)); continue; }
    printf '%s\n' "$task_json" >> "$tmp/tasks.ndjson"
    mined=$((mined + 1))
  done < <(find "$root" -type f -name 'rollout-*.jsonl' -mtime -"$((MINE_WINDOW_DAYS + 1))" 2>/dev/null)

  jq -n --arg source codex --arg path "$(sanitize_path "$root")" --arg status "$status" \
    --argjson seen "$seen" --argjson mined "$mined" \
    --argjson cap "$cap_skips" --argjson empty "$empty_skips" --argjson error "$error_skips" \
    '{source: $source, path: $path, status: $status,
      sessions_seen: $seen, sessions_mined: $mined,
      skipped_cap: $cap, skipped_empty: $empty, skipped_error: $error}'
}

run_mine() {
  parse_mine_args "$@"
  require_jq

  local now start end out tmp
  now=${MINE_NOW:-${FM_RM_NOW:-$(date +%s)}}
  start=$((now - MINE_WINDOW_DAYS * 86400))
  end=$now
  out=${MINE_OUT:-$METRICS_DIR/$(epoch_to_date "$now").json}

  EXTRA_ROOTS=()
  local root_list=${FM_RM_SESSION_ROOTS:-$FM_HOME:$HOME/.treehouse}
  local r
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    [ "$r" = "$FM_HOME" ] && continue
    EXTRA_ROOTS+=("$r")
  done < <(printf '%s\n' "$root_list" | tr ':' '\n')
  EXTRA_ROOTS_JSON=$(printf '%s\n' "${EXTRA_ROOTS[@]+"${EXTRA_ROOTS[@]}"}" | jq -Rsc 'split("\n") | map(select(length > 0))')

  tmp=$(new_tmp mine) || die_fail "cannot create a temp dir"
  : > "$tmp/tasks.ndjson"
  : > "$tmp/reads.ndjson"

  local coverage="[]" cov
  if mine_source_enabled opencode; then
    cov=$(mine_opencode "$tmp" "$start" "$end" "$MINE_MAX")
    coverage=$(printf '%s\n%s' "$coverage" "$cov" | jq -sc '.[0] + [.[1]]')
  fi
  if mine_source_enabled codex; then
    cov=$(mine_codex "$tmp" "$start" "$end" "$MINE_MAX")
    coverage=$(printf '%s\n%s' "$coverage" "$cov" | jq -sc '.[0] + [.[1]]')
  fi

  local roots_json
  roots_json=$(jq -n --argjson extras "$EXTRA_ROOTS_JSON" '["<HOME>"] + ($extras | map("<POOL>"))')

  mkdir -p "$(dirname "$out")"
  local tmp_out="$out.tmp.$$"
  jq -n \
    --argjson now "$now" --argjson start "$start" --argjson end "$end" --argjson days "$MINE_WINDOW_DAYS" \
    --arg home "$FM_HOME" --argjson extras "$EXTRA_ROOTS_JSON" \
    --argjson roots "$roots_json" --argjson coverage "$coverage" \
    --slurpfile tasks "$tmp/tasks.ndjson" --slurpfile reads "$tmp/reads.ndjson" \
    "$CLASSIFY_JQ"'
     {
       schema: "fm-repo-maintenance-metrics.v1",
       generated_at: $now,
       window: {start: $start, end: $end, days: $days},
       roots: $roots,
       coverage: $coverage,
       tasks: ($tasks | sort_by(.id)),
       files: (
         reduce ($reads[] as $r
                 | ($r.p | classify_path($home; $extras)) as $c
                 | select($c != null and $c.path != "")
                 | {scope: $c.scope, path: $c.path, s: $r.s, b: ($r.b // 0)}) as $e
           ({};
            (($e.scope) + "::" + ($e.path)) as $k
            | .[$k] = ((.[$k] // {scope: $e.scope, path: $e.path, reads: 0, by: {}, maxb: 0})
                       | .reads += 1
                       | .by[($e.s)] = ((.by[$e.s] // 0) + 1)
                       | .maxb = ([.maxb, $e.b] | max)))
         | [to_entries[].value
            | {scope, path, reads,
               tasks: (.by | length),
               reread_tasks: ([.by[] | select(. >= 3)] | length),
               max_payload_bytes: .maxb}]
         | sort_by(.scope, .path)
       ),
       external: {
         reads: ([$reads[] | select(.p | classify_path($home; $extras) == null)] | length),
         tasks: ([$reads[] | select(.p | classify_path($home; $extras) == null) | .s] | unique | length)
       }
     }' > "$tmp_out" || { rm -f "$tmp_out"; die_fail "cannot compose metrics JSON"; }
  mv "$tmp_out" "$out"

  printf 'mine: wrote %s\n' "$out"
  printf '%s' "$coverage" | jq -r '.[] | "mine: \(.source) \(.status) sessions_seen=\(.sessions_seen) sessions_mined=\(.sessions_mined) skipped_cap=\(.skipped_cap) skipped_empty=\(.skipped_empty) skipped_error=\(.skipped_error)"'
}

# ---------------------------------------------------------------------------
# rank

RANK_METRICS=""
RANK_PROJECT=""
RANK_TOP=$DEFAULT_TOP
RANK_JSON=0

parse_rank_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --metrics)
        [ "$#" -ge 2 ] || die_usage "--metrics requires a path"
        RANK_METRICS=$2
        shift 2
        ;;
      --project)
        [ "$#" -ge 2 ] || die_usage "--project requires a name"
        RANK_PROJECT=$2
        shift 2
        ;;
      --top)
        [ "$#" -ge 2 ] || die_usage "--top requires a count"
        case "$2" in ''|*[!0-9]*) die_usage "--top must be a count" ;; esac
        RANK_TOP=$2
        shift 2
        ;;
      --json)
        RANK_JSON=1
        shift
        ;;
      *)
        die_usage "unknown argument '$1'"
        ;;
    esac
  done
}

latest_metrics() {
  local f newest=""
  [ -d "$METRICS_DIR" ] || return 1
  for f in "$METRICS_DIR"/*.json; do
    [ -f "$f" ] || continue
    newest=$f
  done
  [ -n "$newest" ] || return 1
  printf '%s\n' "$newest"
}

scope_root() {
  local scope=$1
  case "$scope" in
    firstmate) printf '%s\n' "$FM_ROOT" ;;
    projects/*) printf '%s\n' "$PROJECTS/${scope#projects/}" ;;
    *) return 1 ;;
  esac
}

# run_rank_json <metrics> <project> <top>: print the rank JSON document.
run_rank_json() {
  local metrics=$1 project=$2 top=$3
  local tmp scope path reads tasks reread maxb
  local root abs lines tokens size_src nav prioritized
  tmp=$(new_tmp rank) || die_fail "cannot create a temp dir"
  : > "$tmp/rows.ndjson"
  local unresolved=0

  while IFS=$'\t' read -r scope path reads tasks reread maxb; do
    [ -n "$scope" ] || continue
    if [ -n "$project" ]; then
      case "$scope" in
        "projects/$project") ;;
        firstmate) [ "$project" = "firstmate" ] || continue ;;
        *) continue ;;
      esac
    fi
    root=$(scope_root "$scope") || { unresolved=$((unresolved + 1)); continue; }
    abs="$root/$path"
    if [ -f "$abs" ]; then
      lines=$(wc -l < "$abs" 2>/dev/null | tr -d ' ') || lines=0
      [ -n "$lines" ] || lines=0
      bytes=$(wc -c < "$abs" 2>/dev/null | tr -d ' ') || bytes=0
      [ -n "$bytes" ] || bytes=0
      tokens=$(( (bytes + 3) / 4 ))
      size_src="tree"
    else
      lines="null"
      tokens=$(( (maxb + 3) / 4 ))
      size_src="observed"
    fi
    if [ "$lines" = "null" ]; then
      nav=1
    else
      case "$path" in
        */*)
          dir="${path%/*}"
          if [ -f "$root/$dir/SUMMARY.md" ]; then nav=1; else nav=0; fi
          ;;
        *) nav=1 ;;
      esac
    fi
    prioritized=0
    if [ "$lines" != "null" ] && [ "$lines" -gt "$SOFT_CEILING_LINES" ]; then prioritized=1; fi
    [ "$nav" -eq 0 ] && prioritized=1
    jq -cn --arg scope "$scope" --arg path "$path" \
      --argjson reads "$reads" --argjson tasks "$tasks" --argjson reread "$reread" \
      --argjson tokens "$tokens" --argjson lines "${lines:-null}" \
      --arg size_source "$size_src" --argjson nav "$nav" --argjson prioritized "$prioritized" \
      '{scope: $scope, path: $path, reads: $reads, tasks: $tasks, reread_tasks: $reread,
        tokens: $tokens, lines: $lines, size_source: $size_source, nav: ($nav == 1),
        thi: ($tasks * $reads * $tokens), prioritized: ($prioritized == 1)}' >> "$tmp/rows.ndjson"
  done < <(jq -r '.files[] | [.scope, .path, (.reads|tostring), (.tasks|tostring), (.reread_tasks|tostring), (.max_payload_bytes|tostring)] | @tsv' "$metrics")

  jq -n --arg metrics "$metrics" --argjson top "$top" --argjson unresolved "$unresolved" \
    --slurpfile rows "$tmp/rows.ndjson" \
    '($rows | sort_by(-.thi, .scope, .path)) as $sorted
     | {
         schema: "fm-repo-maintenance-rank.v1",
         metrics: $metrics,
         files: ($sorted | .[0:$top]),
         fix_next: ([ $sorted[] | select(.prioritized) ] | .[0:3]),
         folders: (
           [ $sorted[] | . + {folder: (if (.path | contains("/")) then (.path | split("/")[0:-1] | join("/")) else "." end)} ]
           | group_by(.scope + "::" + .folder)
           | map({scope: .[0].scope, folder: .[0].folder,
                  thi: ([.[].thi] | add), files: length})
           | sort_by(-.thi, .scope, .folder)
           | .[0:10]
         ),
         unresolved: $unresolved
       }'
}

run_rank() {
  parse_rank_args "$@"
  require_jq
  local metrics rank_json unresolved
  metrics=${RANK_METRICS:-$(latest_metrics)} || die_fail "no metrics file found under $METRICS_DIR (run mine first)"
  [ -f "$metrics" ] || die_fail "metrics file not found: $metrics"

  rank_json=$(run_rank_json "$metrics" "$RANK_PROJECT" "$RANK_TOP") || exit 1

  if [ "$RANK_JSON" -eq 1 ]; then
    printf '%s\n' "$rank_json"
    return 0
  fi

  printf 'Token heat - %s\n' "$metrics"
  printf '%-3s %-46s %5s %5s %8s %6s %10s %s\n' "#" "file" "reads" "tasks" "tokens" "lines" "THI" "flags"
  printf '%s' "$rank_json" | jq -r '
    .files | to_entries[] |
    [ (.key + 1 | tostring),
      (.value.scope + "/" + .value.path),
      (.value.reads | tostring),
      (.value.tasks | tostring),
      (.value.tokens | tostring),
      (if .value.lines == null then "-" else (.value.lines | tostring) end),
      (.value.thi | tostring),
      ([ (if .value.prioritized then "PRIORITIZED" else empty end),
         (if .value.nav then empty else "no-nav" end),
         (if .value.size_source == "observed" then "stale" else empty end) ] | join(","))
    ] | @tsv' | while IFS=$'\t' read -r n f r t tk ln thi flags; do
      printf '%-3s %-46s %5s %5s %8s %6s %10s %s\n' "$n" "$f" "$r" "$t" "$tk" "$ln" "$thi" "$flags"
    done
  printf 'folders:\n'
  printf '%s' "$rank_json" | jq -r '.folders[] | "  \(.scope)/\(.folder)  thi=\(.thi) files=\(.files)"'
  local fix
  fix=$(printf '%s' "$rank_json" | jq -r 'if (.fix_next | length) == 0 then "none" else ([.fix_next[] | "\(.scope)/\(.path) (THI \(.thi))"] | join("; ")) end')
  printf 'fix next: %s\n' "$fix"
  unresolved=$(printf '%s' "$rank_json" | jq -r '.unresolved')
  [ "$unresolved" -gt 0 ] && printf 'unresolved: %s recorded files have no resolvable root\n' "$unresolved"
  return 0
}

# ---------------------------------------------------------------------------
# structure

STRUCTURE_ROOT=""
STRUCTURE_JSON=0
STRUCTURE_MAX=$DEFAULT_MAX_FINDINGS

parse_structure_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json)
        STRUCTURE_JSON=1
        shift
        ;;
      --max-findings)
        [ "$#" -ge 2 ] || die_usage "--max-findings requires a count"
        case "$2" in ''|*[!0-9]*) die_usage "--max-findings must be a count" ;; esac
        STRUCTURE_MAX=$2
        shift 2
        ;;
      -*)
        die_usage "unknown argument '$1'"
        ;;
      *)
        [ -z "$STRUCTURE_ROOT" ] || die_usage "structure takes exactly one root directory"
        STRUCTURE_ROOT=$1
        shift
        ;;
    esac
  done
  [ -n "$STRUCTURE_ROOT" ] || die_usage "structure requires a root directory"
  [ -d "$STRUCTURE_ROOT" ] || die_refuse "not a directory: $STRUCTURE_ROOT"
}

is_code_file() {
  case "$1" in
    *.py|*.sh|*.bash|*.zsh|*.js|*.mjs|*.cjs|*.ts|*.tsx|*.jsx|*.rb|*.go|*.rs|*.java|*.kt|*.kts|*.swift|*.c|*.cc|*.cpp|*.h|*.hpp|*.cs|*.php|*.pl|*.lua|*.sql) return 0 ;;
    *) return 1 ;;
  esac
}

# structure_json <root> <max>: print the structure audit JSON document.
structure_json() {
  local root=$1 max=$2
  local name exemptions tmp
  name=$(basename "$root")
  exemptions="$RM_DATA/$name/exemptions.txt"
  tmp=$(new_tmp structure) || die_fail "cannot create a temp dir"

  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die_refuse "not a git work tree: $root"

  git -C "$root" ls-files -z | tr '\0' '\n' > "$tmp/files.txt"

  # Exemptions: "<path> :: <reason>" lines; comments and blanks ignored.
  : > "$tmp/exempt.txt"
  if [ -f "$exemptions" ]; then
    sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$exemptions" \
      | sed -e 's/[[:space:]]*::.*$//' -e 's/[[:space:]]*$//' > "$tmp/exempt.txt"
  fi

  # Size check over tracked code files, minus exemptions.
  : > "$tmp/size_candidates.txt"
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    is_code_file "$f" || continue
    grep -Fxq "$f" "$tmp/exempt.txt" && continue
    printf '%s\n' "$f" >> "$tmp/size_candidates.txt"
  done < "$tmp/files.txt"
  : > "$tmp/over.ndjson"
  local over_total=0
  if [ -s "$tmp/size_candidates.txt" ]; then
    ( cd "$root" && tr '\n' '\0' < "$tmp/size_candidates.txt" | xargs -0 wc -l 2>/dev/null ) \
      | awk '$0 ~ /^[[:space:]]*[0-9]+[[:space:]]+total$/ { next } { n=$1; $1=""; sub(/^ +/, ""); print n "\t" $0 }' > "$tmp/lines.tsv"
    local n p
    while IFS=$'\t' read -r n p; do
      [ -n "$p" ] || continue
      if [ "$n" -gt "$SOFT_CEILING_LINES" ]; then
        over_total=$((over_total + 1))
        if [ "$over_total" -le "$max" ]; then
          jq -cn --arg path "$p" --argjson lines "$n" '{path: $path, lines: $lines}' >> "$tmp/over.ndjson"
        fi
      fi
    done < "$tmp/lines.tsv"
  fi
  local exempt_total=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -Fxq "$f" "$tmp/exempt.txt" && exempt_total=$((exempt_total + 1))
  done < "$tmp/files.txt"

  # src/ depth: more than DEPTH_MAX_BELOW_SRC path segments below src/.
  : > "$tmp/depth.ndjson"
  local depth_total=0 nf
  while IFS= read -r f; do
    case "$f" in
      src/*)
        nf=$(printf '%s' "$f" | awk -F/ '{ print NF }')
        if [ "$nf" -gt $((DEPTH_MAX_BELOW_SRC + 1)) ]; then
          depth_total=$((depth_total + 1))
          if [ "$depth_total" -le "$max" ]; then
            jq -cn --arg path "$f" '{path: $path}' >> "$tmp/depth.ndjson"
          fi
        fi
        ;;
    esac
  done < "$tmp/files.txt"

  # Parent dirs of tracked files, visible only, one per line.
  awk -F/ 'NF > 1 { p=""; for (i=1; i<NF; i++) { if (i>1) p=p "/"; p=p $i } ; print p }' "$tmp/files.txt" \
    | grep -vE '(^|/)\.' | LC_ALL=C sort -u > "$tmp/dirs.txt"

  # Directory listing per dir, built in one pass, for the SUMMARY checks.
  awk -F/ 'NF > 1 { p=""; for (i=1; i<NF; i++) { if (i>1) p=p "/"; p=p $i } ; print p "\t" $0 }' "$tmp/files.txt" \
    | LC_ALL=C sort -t$'\t' -k1,1 > "$tmp/dirfiles.tsv"

  : > "$tmp/missing.ndjson"
  : > "$tmp/gaps.ndjson"
  : > "$tmp/overlong.ndjson"
  local dir_total=0 missing_total=0 gap_total=0 overlong_total=0 summaries_seen=0
  local current_dir="" summary_content="" summary_ok=0 base
  while IFS=$'\t' read -r d f; do
    [ -n "$d" ] || continue
    case "$d" in .*|*/.*) continue ;; esac
    if [ "$d" != "$current_dir" ]; then
      [ -n "$current_dir" ] && :
      current_dir=$d
      dir_total=$((dir_total + 1))
      summary_ok=0
      summary_content=""
      if [ -f "$root/$d/SUMMARY.md" ]; then
        summary_ok=1
        summaries_seen=$((summaries_seen + 1))
        summary_content=$(cat "$root/$d/SUMMARY.md" 2>/dev/null)
        local slines
        slines=$(wc -l < "$root/$d/SUMMARY.md" | tr -d ' ')
        if [ "$slines" -gt "$SUMMARY_MAX_LINES" ]; then
          overlong_total=$((overlong_total + 1))
          if [ "$overlong_total" -le "$max" ]; then
            jq -cn --arg summary "$d/SUMMARY.md" --argjson lines "$slines" '{summary: $summary, lines: $lines}' >> "$tmp/overlong.ndjson"
          fi
        fi
      else
        missing_total=$((missing_total + 1))
        if [ "$missing_total" -le "$max" ]; then
          jq -cn --arg dir "$d" '{dir: $dir}' >> "$tmp/missing.ndjson"
        fi
      fi
    fi
    [ "$summary_ok" -eq 1 ] || continue
    [ "$f" = "$d/SUMMARY.md" ] && continue
    base=${f##*/}
    case "$base" in .*) continue ;; esac
    case "$summary_content" in
      *"$base"*) ;;
      *)
        gap_total=$((gap_total + 1))
        if [ "$gap_total" -le "$max" ]; then
          jq -cn --arg summary "$d/SUMMARY.md" --arg file "$f" '{summary: $summary, file: $file}' >> "$tmp/gaps.ndjson"
        fi
        ;;
    esac
  done < "$tmp/dirfiles.tsv"

  local readme=0 agents=0
  [ -f "$root/README.md" ] && readme=1
  { [ -f "$root/AGENTS.md" ] || [ -f "$root/CLAUDE.md" ]; } && agents=1

  jq -n --arg root "$root" \
    --argjson ceiling "$SOFT_CEILING_LINES" \
    --argjson depth_max "$DEPTH_MAX_BELOW_SRC" \
    --argjson summary_max "$SUMMARY_MAX_LINES" \
    --argjson over_total "$over_total" --slurpfile over "$tmp/over.ndjson" \
    --argjson exempt_total "$exempt_total" \
    --argjson depth_total "$depth_total" --slurpfile depth "$tmp/depth.ndjson" \
    --argjson dir_total "$dir_total" --argjson missing_total "$missing_total" --slurpfile missing "$tmp/missing.ndjson" \
    --argjson summaries_seen "$summaries_seen" --argjson gap_total "$gap_total" --slurpfile gaps "$tmp/gaps.ndjson" \
    --argjson overlong_total "$overlong_total" --slurpfile overlong "$tmp/overlong.ndjson" \
    --argjson readme "$readme" --argjson agents "$agents" \
    '{
       schema: "fm-repo-maintenance-structure.v1",
       root: $root,
       ceiling_lines: $ceiling,
       files_over_ceiling: {total: $over_total, exempt: $exempt_total, listed: $over},
       depth_violations: {total: $depth_total, max_below_src: $depth_max, listed: $depth},
       dirs_missing_summary: {total: $missing_total, dirs: $dir_total, listed: $missing},
       summary_gaps: {total: $gap_total, summaries_seen: $summaries_seen, listed: $gaps},
       summary_over_limit: {total: $overlong_total, max_lines: $summary_max, listed: $overlong},
       entrypoints: {readme: ($readme == 1), agents: ($agents == 1), ok: (($readme == 1) and ($agents == 1))}
     }'
}

run_structure() {
  parse_structure_args "$@"
  require_jq
  local json
  json=$(structure_json "$STRUCTURE_ROOT" "$STRUCTURE_MAX") || exit $?
  if [ "$STRUCTURE_JSON" -eq 1 ]; then
    printf '%s\n' "$json"
    return 0
  fi
  printf 'structure: %s\n' "$STRUCTURE_ROOT"
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
    "entrypoints: README.md=\(.entrypoints.readme) AGENTS.md=\(.entrypoints.agents)"
  '
}

# ---------------------------------------------------------------------------
# sweep

SWEEP_PROJECT=""
SWEEP_DATE=""
SWEEP_FORCE=0
SWEEP_MAX=$DEFAULT_MAX_FINDINGS

parse_sweep_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --date)
        [ "$#" -ge 2 ] || die_usage "--date requires YYYY-MM-DD"
        SWEEP_DATE=$2
        shift 2
        ;;
      --max-findings)
        [ "$#" -ge 2 ] || die_usage "--max-findings requires a count"
        case "$2" in ''|*[!0-9]*) die_usage "--max-findings must be a count" ;; esac
        SWEEP_MAX=$2
        shift 2
        ;;
      --force)
        SWEEP_FORCE=1
        shift
        ;;
      -*)
        die_usage "unknown argument '$1'"
        ;;
      *)
        [ -z "$SWEEP_PROJECT" ] || die_usage "sweep takes exactly one project"
        SWEEP_PROJECT=$1
        shift
        ;;
    esac
  done
  [ -n "$SWEEP_PROJECT" ] || die_usage "sweep requires a project name"
  case "$SWEEP_DATE" in
    "") ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) die_usage "--date must be YYYY-MM-DD" ;;
  esac
}

registered_project_root() {
  local name=$1 registry="$DATA/projects.md" line rest entry found=0
  if [ "$name" = "firstmate" ]; then
    printf '%s\n' "$FM_ROOT"
    return 0
  fi
  [ -f "$registry" ] || return 1
  while IFS= read -r line; do
    case "$line" in
      "- "*) ;;
      *) continue ;;
    esac
    rest=${line#- }
    case "$rest" in
      *" ["*) entry=${rest%% \[*} ;;
      *" - "*) entry=${rest%% - *} ;;
      *) continue ;;
    esac
    if [ "$entry" = "$name" ]; then
      found=1
      break
    fi
  done < "$registry"
  [ "$found" -eq 1 ] || return 1
  printf '%s\n' "$PROJECTS/$name"
}

run_sweep() {
  parse_sweep_args "$@"
  require_jq
  local root date outdir report
  root=$(registered_project_root "$SWEEP_PROJECT") \
    || die_refuse "unknown project '$SWEEP_PROJECT' (not in $DATA/projects.md and not 'firstmate')"
  [ -d "$root" ] || die_refuse "project root missing: $root"
  date=${SWEEP_DATE:-$(date -u +%Y-%m-%d)}
  outdir="$RM_DATA/$SWEEP_PROJECT/$date"
  report="$outdir/report.md"
  if [ -e "$report" ] && [ "$SWEEP_FORCE" -ne 1 ]; then
    die_refuse "report already exists: $report (use --force to regenerate)"
  fi

  local metrics rank_json structure_json
  metrics=$(latest_metrics) || metrics=""
  rank_json=""
  if [ -n "$metrics" ]; then
    rank_json=$(run_rank_json "$metrics" "$SWEEP_PROJECT" 15) || rank_json=""
  fi
  structure_json=$(structure_json "$root" "$SWEEP_MAX") || exit $?

  mkdir -p "$outdir"
  {
    printf '# Repo maintenance sweep - %s - %s\n\n' "$SWEEP_PROJECT" "$date"
    cat <<'EOF'
Instrument: `bin/fm-repo-maintenance.sh` (schema `fm-repo-maintenance-report.v1`).
Report shape: `.agents/skills/repo-maintenance/references/audit-playbook.md` owns the section contract;
complete the pending sections through the maintenance pass before acting on this report.

## Coverage

EOF
    # shellcheck disable=SC2016  # backticks are literal report text, not command substitution.
    printf -- '- Structure root: `%s`\n' "$root"
    if [ -n "$metrics" ]; then
      # shellcheck disable=SC2016  # backticks are literal report text, not command substitution.
      printf -- '- Metrics: `%s`\n' "$metrics"
      jq -r '"  - Window: \(.window.start) to \(.window.end) (\(.window.days) days); tasks mined: \(.tasks | length)"' "$metrics" 2>/dev/null || true
      jq -r '.coverage[] | "  - \(.source): \(.status), sessions mined \(.sessions_mined) of \(.sessions_seen) seen (cap \(.skipped_cap), empty \(.skipped_empty), error \(.skipped_error))"' "$metrics" 2>/dev/null || true
    else
      # shellcheck disable=SC2016  # backticks are literal report text, not command substitution.
      printf -- '- Metrics: none; run `bin/fm-repo-maintenance.sh mine` before the next sweep.\n'
    fi
    jq -r --argjson lines "$SOFT_CEILING_LINES" '
      "- Structure totals: files over \($lines) lines \(.files_over_ceiling.total) (exempt \(.files_over_ceiling.exempt)); depth violations \(.depth_violations.total); dirs missing SUMMARY.md \(.dirs_missing_summary.total) of \(.dirs_missing_summary.dirs); summary gaps \(.summary_gaps.total); over-long summaries \(.summary_over_limit.total); entrypoints ok=\(.entrypoints.ok)"' <<<"$structure_json" 2>/dev/null || true
    printf '\n'

    printf '## Token heat ranking (instrument)\n\n'
    if [ -n "$rank_json" ]; then
      printf '%s' "$rank_json" | jq -r '
        "| # | file | reads | tasks | tokens | lines | THI | flags |",
        "|---|------|-------|-------|--------|-------|-----|-------|",
        (.files | to_entries[] |
         [ (.key + 1 | tostring),
           ("`" + .value.scope + "/" + .value.path + "`"),
           (.value.reads | tostring), (.value.tasks | tostring), (.value.tokens | tostring),
           (if .value.lines == null then "-" else (.value.lines | tostring) end),
           (.value.thi | tostring),
           ([ (if .value.prioritized then "prioritized" else empty end),
              (if .value.nav then empty else "no-nav" end),
              (if .value.size_source == "observed" then "stale" else empty end) ] | join(", "))
         ] | "| " + join(" | ") + " |")'
      printf '\n'
      printf 'Fix next (top prioritized):\n'
      printf '%s' "$rank_json" | jq -r '
        if (.fix_next | length) == 0 then "- none this window"
        else ([.fix_next[] | "- `\(.scope)/\(.path)` (THI \(.thi), lines \(.lines // "?"))"] | join("\n")) end'
      printf '\n'
      printf 'Hottest folders:\n'
      printf '%s' "$rank_json" | jq -r '.folders[] | "- `\(.scope)/\(.folder)` (THI \(.thi), files \(.files))"'
      printf '\n'
    else
      # shellcheck disable=SC2016  # backticks are literal report text, not command substitution.
      printf 'No metrics available; run `bin/fm-repo-maintenance.sh mine` first.\n\n'
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
      "- Summaries over \(.summary_over_limit.max_lines) lines: \(.summary_over_limit.total)",
      (.summary_over_limit.listed[] | "  - `\(.summary)` (\(.lines) lines)"),
      "- Entrypoints: README.md=\(.entrypoints.readme) AGENTS.md=\(.entrypoints.agents)"
    '
    printf '\n'

    cat <<'EOF'
## Evidence-backed findings (pending qualitative audit)

Pending. Run the audit playbook (`references/audit-playbook.md`) over this project and replace
this section with the evidence-backed findings list (category, anchor, why it matters).

## Phased slice plan (pending)

Pending. Sequence the refactor slices ahead of feature work per `references/refactor-sequencing.md`.

## Summary: DO FIRST / DO LATER / DO NOT DO (pending)

Pending. Classify the findings per the audit playbook tri-state rules.
EOF
  } > "$report"

  printf 'report: %s\n' "$report"
  if [ -n "$rank_json" ]; then
    local fix
    fix=$(printf '%s' "$rank_json" | jq -r 'if (.fix_next | length) == 0 then "none" else ([.fix_next[] | "\(.scope)/\(.path) (THI \(.thi))"] | join("; ")) end')
    printf 'fix next: %s\n' "$fix"
  else
    printf 'fix next: none (no metrics)\n'
  fi
}

# ---------------------------------------------------------------------------

case "${1:-}" in
  mine) shift; run_mine "$@" ;;
  rank) shift; run_rank "$@" ;;
  structure) shift; run_structure "$@" ;;
  sweep) shift; run_sweep "$@" ;;
  --help|-h|"") usage ;;
  *) die_usage "unknown command '${1:-}'" ;;
esac

#!/usr/bin/env bash
# Tests for fm-repo-maintenance.sh, the repo-maintenance instrument.
#
# The cases that matter most are the privacy boundary and the metric
# definitions: mine must extract read, edit, and token aggregates from
# structured session stores while never recording raw paths outside the home
# and pool roots, prompt text, or tool output, and rank must order files by the
# Token Heat Index so the weekly "fix next" list is reproducible. Every fixture
# store lives under the test temp root, so no case ever reads or writes the
# operator's live session stores or home records.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-repo-maintenance.sh"
TMP_ROOT=$(fm_test_tmproot fm-repo-maintenance)

# Fixture commits run inside command substitutions, so export the identity here
# where every case inherits it.
fm_git_identity fmtest fmtest@example.invalid

if ! command -v sqlite3 >/dev/null 2>&1; then
  fail "sqlite3 is required for the opencode fixture store"
fi
if ! command -v jq >/dev/null 2>&1; then
  fail "jq is required for the instrument output"
fi

# make_lab <name>: build a fresh home, project clone, pool copy, session
# stores, and registry under $TMP_ROOT/<name>; echo the lab root.
make_lab() {
  local name=$1 lab home proj pool i
  lab="$TMP_ROOT/$name"
  home="$lab/home"
  proj="$home/projects/proj"
  pool="$lab/pool/proj-abc123/1/proj"
  mkdir -p "$home/data/repo-maintenance/proj" "$home/.local/share/opencode" "$home/.codex/sessions" "$pool"

  # Project clone fixture.
  mkdir -p "$proj/src/a/b/c/d" "$proj/bin" "$proj/docs"
  ( cd "$proj" && git init -q )
  printf '# proj\n\nSetup and validation for the fixture.\n' > "$proj/README.md"
  printf '# proj agents\n\n| task | files | tests |\n' > "$proj/AGENTS.md"
  i=1
  while [ "$i" -le 700 ]; do printf 'line %s\n' "$i"; i=$((i + 1)); done > "$proj/src/one.py"
  printf 'deep = 1\n' > "$proj/src/a/b/c/d/deep.py"
  i=1
  while [ "$i" -le 620 ]; do printf 'x %s\n' "$i"; i=$((i + 1)); done > "$proj/big2.py"
  printf '#!/usr/bin/env bash\necho tool\n' > "$proj/bin/tool.sh"
  # shellcheck disable=SC2016  # backticks are literal fixture content, not command substitution.
  printf '# bin\n\nRole: fixture tooling.\n\n| File | Responsibility | Key Exported Symbols |\n| --- | --- | --- |\n| `other.sh` | fixture | - |\n' > "$proj/bin/SUMMARY.md"
  i=1
  while [ "$i" -le 33 ]; do printf 'summary line %s\n' "$i"; i=$((i + 1)); done > "$proj/docs/SUMMARY.md"
  # shellcheck disable=SC2016  # backticks are literal fixture content, not command substitution.
  printf '# src\n\nRole: fixture sources.\n\n| File | Responsibility | Key Exported Symbols |\n| --- | --- | --- |\n| `one.py` | fixture logic | - |\n' > "$proj/src/SUMMARY.md"
  ( cd "$proj" && git add -A && git commit -qm fixture )

  printf 'big2.py :: verified cold batch path for the fixture\n' > "$home/data/repo-maintenance/proj/exemptions.txt"
  cp -R "$proj" "$pool"
  rm -rf "$pool/.git"
  printf '# Projects\n\n- proj [no-mistakes] - Fixture project (added 2026-10-18)\n' > "$home/data/projects.md"

  # opencode fixture: ses_a reads one.py three times and edits it at turn 4;
  # ses_b reads one path outside every root; ses_c works outside the scope;
  # ses_d's only message predates the window.
  sqlite3 "$home/.local/share/opencode/opencode.db" <<SQL
CREATE TABLE session_v2 (id TEXT PRIMARY KEY, project_id TEXT, slug TEXT, directory TEXT, time_updated INTEGER);
CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, seq INTEGER, time_created INTEGER, data TEXT);
INSERT INTO session_v2 VALUES ('ses_a', 'p', 'curious-proj', '$pool', 1792400000000);
INSERT INTO session_v2 VALUES ('ses_b', 'p', 'steady-proj', '$proj', 1792400100000);
INSERT INTO session_v2 VALUES ('ses_c', 'p', 'outside', '/tmp/elsewhere', 1792400200000);
INSERT INTO session_v2 VALUES ('ses_d', 'p', 'old-work', '$pool', 1792400150000);
INSERT INTO session_message VALUES ('a1', 'ses_a', 'assistant', 1, 1792399900000,
 '{"tokens":{"input":1000,"output":100,"reasoning":0,"cache":{"read":0,"write":0}},"content":[{"type":"tool","name":"read","state":{"status":"completed","input":{"path":"$pool/src/one.py"},"content":[{"type":"text","text":"$(printf 'p%.0s' $(seq 1 400))"}]}}]}');
INSERT INTO session_message VALUES ('a2', 'ses_a', 'assistant', 2, 1792399910000,
 '{"tokens":{"input":2000,"output":100,"reasoning":0,"cache":{"read":0,"write":0}},"content":[{"type":"tool","name":"read","state":{"status":"completed","input":{"path":"$pool/src/one.py"},"content":[{"type":"text","text":"$(printf 'p%.0s' $(seq 1 410))"}]}}]}');
INSERT INTO session_message VALUES ('a3', 'ses_a', 'assistant', 3, 1792399920000,
 '{"tokens":{"input":3000,"output":100,"reasoning":0,"cache":{"read":0,"write":0}},"content":[{"type":"tool","name":"read","state":{"status":"completed","input":{"path":"$pool/src/one.py"},"content":[{"type":"text","text":"$(printf 'p%.0s' $(seq 1 420))"}]}},{"type":"tool","name":"read","state":{"status":"completed","input":{"path":"$pool/README.md"},"content":[{"type":"text","text":"short"}]}}]}');
INSERT INTO session_message VALUES ('a4', 'ses_a', 'assistant', 4, 1792399930000,
 '{"tokens":{"input":4000,"output":100,"reasoning":0,"cache":{"read":0,"write":0}},"content":[{"type":"tool","name":"edit","state":{"status":"completed","input":{"path":"$pool/src/one.py"}}}]}');
INSERT INTO session_message VALUES ('a0', 'ses_a', 'user', 0, 1792399890000, '{"text":"secret prompt text"}');
INSERT INTO session_message VALUES ('b1', 'ses_b', 'assistant', 1, 1792400050000,
 '{"tokens":{"input":500,"output":50,"reasoning":0,"cache":{"read":0,"write":0}},"content":[{"type":"tool","name":"read","state":{"status":"completed","input":{"path":"/tmp/outside/secret.py"},"content":[{"type":"text","text":"outside"}]}}]}');
INSERT INTO session_message VALUES ('c1', 'ses_c', 'assistant', 1, 1792400150000,
 '{"tokens":{"input":500,"output":50,"reasoning":0,"cache":{"read":0,"write":0}},"content":[{"type":"tool","name":"read","state":{"status":"completed","input":{"path":"/tmp/elsewhere/nope.py"},"content":[{"type":"text","text":"nope"}]}}]}');
INSERT INTO session_message VALUES ('d1', 'ses_d', 'assistant', 1, 1791700000000,
 '{"tokens":{"input":500,"output":50,"reasoning":0,"cache":{"read":0,"write":0}},"content":[{"type":"tool","name":"read","state":{"status":"completed","input":{"path":"$pool/src/one.py"},"content":[{"type":"text","text":"old"}]}}]}');
SQL

  # codex fixture: two turns, an apply_patch at turn 2, and token totals.
  {
    printf '{"timestamp":"2026-10-18T10:00:00.000Z","type":"session_meta","payload":{"session_id":"cdx_a","cwd":"%s","timestamp":"2026-10-18T10:00:00.000Z"}}\n' "$pool"
    printf '{"timestamp":"2026-10-18T10:00:01.000Z","type":"turn_context","payload":{"turn_id":"t1"}}\n'
    printf '{"timestamp":"2026-10-18T10:00:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":5000}}}}\n'
    printf '{"timestamp":"2026-10-18T10:00:03.000Z","type":"turn_context","payload":{"turn_id":"t2"}}\n'
    printf '{"timestamp":"2026-10-18T10:00:04.000Z","type":"response_item","payload":{"type":"function_call","name":"apply_patch","arguments":"{}"}}\n'
    printf '{"timestamp":"2026-10-18T10:00:05.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":8000}}}}\n'
    printf '{"timestamp":"2026-10-18T10:00:06.000Z","type":"turn_context","payload":{"turn_id":"t3"}}\n'
  } > "$home/.codex/sessions/rollout-2026-10-18T10-00-00-fixture.jsonl"

  printf '%s\n' "$lab"
}

# lab_env <lab>: export the fixture home and store overrides for the tool.
lab_env() {
  local lab=$1
  export FM_HOME="$lab/home"
  export FM_RM_OPENCODE_DB="$lab/home/.local/share/opencode/opencode.db"
  export FM_RM_CODEX_SESSIONS="$lab/home/.codex/sessions"
  export FM_RM_SESSION_ROOTS="$lab/home:$lab/pool"
}

# lab_mine <lab> [extra args...]: mine the fixture stores and echo the metrics
# path.
lab_mine() {
  local lab=$1 out
  shift
  lab_env "$lab"
  out="$lab/metrics.json"
  "$TOOL" mine --now 1792400300 --out "$out" "$@" >/dev/null || fail "mine failed"
  printf '%s\n' "$out"
}

test_structure_reports_ceiling_depth_and_summary_gaps() {
  local lab proj out
  lab=$(make_lab structure-basic)
  lab_env "$lab"
  proj="$lab/home/projects/proj"
  out=$("$TOOL" structure "$proj" --json) || fail "structure exited nonzero"

  assert_equals "1" "$(printf '%s' "$out" | jq -r '.files_over_ceiling.total')" "one.py is the only unexempted file over the ceiling"
  assert_equals "1" "$(printf '%s' "$out" | jq -r '.files_over_ceiling.exempt')" "big2.py is exempted"
  assert_equals "src/one.py" "$(printf '%s' "$out" | jq -r '.files_over_ceiling.listed[0].path')" "the listed file is one.py"
  assert_equals "1" "$(printf '%s' "$out" | jq -r '.depth_violations.total')" "the 5-level path under src/ violates the depth bound"
  assert_equals "src/a/b/c/d/deep.py" "$(printf '%s' "$out" | jq -r '.depth_violations.listed[0].path')" "the depth violation is the deep file"
  assert_equals "1" "$(printf '%s' "$out" | jq -r '.dirs_missing_summary.total')" "only the deepest dir lacks SUMMARY.md"
  assert_equals "bin/tool.sh" "$(printf '%s' "$out" | jq -r '.summary_gaps.listed[0].file')" "bin/tool.sh is not listed by its summary"
  assert_equals "1" "$(printf '%s' "$out" | jq -r '.summary_over_limit.total')" "docs/SUMMARY.md exceeds 30 lines"
  assert_equals "true" "$(printf '%s' "$out" | jq -r '.entrypoints.ok')" "both root entrypoints are present"
  pass "structure reports ceiling, depth, and SUMMARY findings with exemptions honored"
}

test_structure_is_read_only_and_refuses_non_git() {
  local lab proj plain dirty
  lab=$(make_lab structure-readonly)
  lab_env "$lab"
  proj="$lab/home/projects/proj"
  plain="$lab/plain"
  mkdir -p "$plain"
  "$TOOL" structure "$proj" --json >/dev/null || fail "structure exited nonzero"
  dirty=$(cd "$proj" && git status --porcelain)
  assert_equals "" "$dirty" "structure left the fixture work tree unchanged"

  local status=0
  "$TOOL" structure "$plain" --json >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "structure refuses a non-git directory"
  pass "structure is read-only and refuses a non-git root"
}

test_mine_extracts_read_metrics_from_opencode() {
  local lab metrics
  lab=$(make_lab mine-opencode)
  metrics=$(lab_mine "$lab")

  assert_equals "4" "$(jq -r '.tasks[] | select(.id=="ses_a") | .turns' "$metrics")" "four assistant turns"
  assert_equals "4" "$(jq -r '.tasks[] | select(.id=="ses_a") | .first_edit_turn' "$metrics")" "the first edit lands on turn 4"
  assert_equals "10400" "$(jq -r '.tasks[] | select(.id=="ses_a") | .tokens_total' "$metrics")" "token counters sum once per turn"
  assert_equals "6300" "$(jq -r '.tasks[] | select(.id=="ses_a") | .tokens_exploration' "$metrics")" "exploration stops before the edit turn"
  assert_equals "4" "$(jq -r '.tasks[] | select(.id=="ses_a") | .files_read' "$metrics")" "four read events"
  assert_equals "2" "$(jq -r '.tasks[] | select(.id=="ses_a") | .unique_files' "$metrics")" "two unique files"
  assert_equals "1" "$(jq -r '.tasks[] | select(.id=="ses_a") | .reread_files' "$metrics")" "one file is re-read three times"

  assert_equals "3" "$(jq -r '.files[] | select(.path=="src/one.py") | .reads' "$metrics")" "one.py was read three times"
  assert_equals "1" "$(jq -r '.files[] | select(.path=="src/one.py") | .tasks' "$metrics")" "one task read one.py"
  assert_equals "1" "$(jq -r '.files[] | select(.path=="src/one.py") | .reread_tasks' "$metrics")" "one task re-read one.py"
  assert_equals "420" "$(jq -r '.files[] | select(.path=="src/one.py") | .max_payload_bytes' "$metrics")" "the largest observed payload wins"
  assert_equals "projects/proj" "$(jq -r '.files[] | select(.path=="src/one.py") | .scope' "$metrics")" "the pool worktree maps to the project scope"

  assert_equals "1" "$(jq -r '.external.reads' "$metrics")" "the out-of-scope read is counted"
  assert_equals "1" "$(jq -r '.external.tasks' "$metrics")" "the out-of-scope task is counted"
  assert_equals "2" "$(jq -r '.coverage[] | select(.source=="opencode") | .sessions_mined' "$metrics")" "two opencode sessions were mined"
  assert_equals "1" "$(jq -r '.coverage[] | select(.source=="opencode") | .skipped_empty' "$metrics")" "the pre-window session is reported as empty"
  assert_equals "0" "$(jq -r '[.tasks[] | select(.id=="ses_d")] | length' "$metrics")" "the pre-window session is never mined"
  pass "mine extracts opencode read, edit, and token aggregates"
}

test_mine_never_records_raw_paths_or_content() {
  local lab metrics
  lab=$(make_lab mine-privacy)
  metrics=$(lab_mine "$lab")

  assert_not_contains "$(cat "$metrics")" "$lab" "no fixture absolute path appears in the metrics"
  assert_not_contains "$(cat "$metrics")" "/tmp/outside" "no out-of-scope path appears in the metrics"
  assert_not_contains "$(cat "$metrics")" "secret prompt" "no prompt text appears in the metrics"
  assert_contains "$(cat "$metrics")" "<HOME>/.local/share/opencode/opencode.db" "the source path is sanitized"
  assert_contains "$(cat "$metrics")" "<POOL>/proj-abc123/1/proj" "the task directory is sanitized"
  assert_contains "$(cat "$metrics")" "\"dir\": \"<HOME>/projects/proj\"" "the home clone directory is sanitized"
  pass "mine stores sanitized paths and no prompt, path, or content payloads"
}

test_mine_codex_session_metrics() {
  local lab metrics
  lab=$(make_lab mine-codex)
  metrics=$(lab_mine "$lab" --source codex)

  assert_equals "codex" "$(jq -r '.tasks[] | select(.id=="cdx_a") | .source' "$metrics")" "the rollout is mined as a codex task"
  assert_equals "3" "$(jq -r '.tasks[] | select(.id=="cdx_a") | .turns' "$metrics")" "turn contexts count as turns"
  assert_equals "2" "$(jq -r '.tasks[] | select(.id=="cdx_a") | .first_edit_turn' "$metrics")" "apply_patch on turn 2 is the first edit"
  assert_equals "8000" "$(jq -r '.tasks[] | select(.id=="cdx_a") | .tokens_total' "$metrics")" "the last token count is the total"
  assert_equals "5000" "$(jq -r '.tasks[] | select(.id=="cdx_a") | .tokens_exploration' "$metrics")" "exploration stops at the token count before the edit"
  assert_equals "0" "$(jq -r '.tasks[] | select(.id=="cdx_a") | .files_read' "$metrics")" "codex contributes no guessed file rows"
  assert_equals "0" "$(jq -r '[.files[]] | length' "$metrics")" "no file rows come from shell-mediated reads"
  pass "mine extracts codex session-level metrics without guessing file reads"
}

test_mine_reports_absent_sources() {
  local lab out status=0
  lab=$(make_lab mine-absent)
  mkdir -p "$lab/home"
  FM_HOME="$lab/home" FM_RM_OPENCODE_DB="$lab/none.db" FM_RM_CODEX_SESSIONS="$lab/none" \
    "$TOOL" mine --now 1792400300 --out "$lab/absent.json" >/dev/null || status=$?
  expect_code 0 "$status" "mine succeeds with absent sources"
  out=$(cat "$lab/absent.json")
  assert_equals "absent" "$(printf '%s' "$out" | jq -r '.coverage[] | select(.source=="opencode") | .status')" "the missing opencode store is reported absent"
  assert_equals "absent" "$(printf '%s' "$out" | jq -r '.coverage[] | select(.source=="codex") | .status')" "the missing codex root is reported absent"
  pass "mine reports absent sources instead of failing silently"
}

test_rank_orders_by_token_heat() {
  local lab metrics rank
  lab=$(make_lab rank-basic)
  metrics=$(lab_mine "$lab")
  rank=$(FM_HOME="$lab/home" "$TOOL" rank --metrics "$metrics" --project proj --json) || fail "rank exited nonzero"

  assert_equals "src/one.py" "$(printf '%s' "$rank" | jq -r '.files[0].path')" "the re-read 700-line file leads the ranking"
  assert_equals "4644" "$(printf '%s' "$rank" | jq -r '.files[0].thi')" "THI is tasks x reads x token size"
  assert_equals "true" "$(printf '%s' "$rank" | jq -r '.files[0].prioritized')" "an over-ceiling file is prioritized"
  assert_equals "700" "$(printf '%s' "$rank" | jq -r '.files[0].lines')" "the line count comes from the working tree"
  assert_equals "src/one.py" "$(printf '%s' "$rank" | jq -r '.fix_next[0].path')" "the top prioritized file is the fix-next answer"
  assert_equals "src" "$(printf '%s' "$rank" | jq -r '.folders[0].folder')" "the hottest folder aggregates the file"
  assert_equals "README.md" "$(printf '%s' "$rank" | jq -r '.files[1].path')" "the second file is the README"
  assert_equals "false" "$(printf '%s' "$rank" | jq -r '.files[1].prioritized')" "the small, navigable file is not prioritized"
  pass "rank orders files by Token Heat Index and names the fix-next set"
}

test_rank_without_metrics_refuses() {
  local lab status=0
  lab=$(make_lab rank-empty)
  FM_HOME="$lab/home" "$TOOL" rank >/dev/null 2>"$lab/err.txt" || status=$?
  assert_equals "1" "$status" "rank without metrics exits nonzero"
  assert_contains "$(cat "$lab/err.txt")" "no metrics file found" "the refusal names the missing metrics"
  pass "rank refuses when no metrics exist"
}

test_sweep_writes_report_and_refuses_overwrite() {
  local lab report status=0
  lab=$(make_lab sweep-basic)
  lab_env "$lab"
  # The default metrics path is what sweep reads, so this case mines without --out.
  "$TOOL" mine --now 1792400300 >/dev/null || fail "mine failed"
  report="$lab/home/data/repo-maintenance/proj/2026-10-18/report.md"

  FM_HOME="$lab/home" "$TOOL" sweep proj --date 2026-10-18 >/dev/null || fail "sweep exited nonzero"
  assert_present "$report" "the sweep writes the dated report"
  assert_contains "$(cat "$report")" "## Token heat ranking (instrument)" "the report carries the instrument ranking"
  assert_contains "$(cat "$report")" 'src/one.py` (THI 4644' "the report names the fix-next file"
  assert_contains "$(cat "$report")" "## Structure audit (instrument)" "the report carries the structure audit"
  assert_contains "$(cat "$report")" "pending qualitative audit" "the qualitative sections are visibly pending"

  FM_HOME="$lab/home" "$TOOL" sweep proj --date 2026-10-18 >/dev/null 2>"$lab/err.txt" || status=$?
  expect_code 2 "$status" "a second sweep of the same date refuses"
  assert_contains "$(cat "$lab/err.txt")" "already exists" "the refusal names the existing report"

  FM_HOME="$lab/home" "$TOOL" sweep proj --date 2026-10-18 --force >/dev/null || fail "forced sweep failed"
  pass "sweep writes the dated report, refuses overwrite, and regenerates under --force"
}

test_structure_reports_ceiling_depth_and_summary_gaps
test_structure_is_read_only_and_refuses_non_git
test_mine_extracts_read_metrics_from_opencode
test_mine_never_records_raw_paths_or_content
test_mine_codex_session_metrics
test_mine_reports_absent_sources
test_rank_orders_by_token_heat
test_rank_without_metrics_refuses
test_sweep_writes_report_and_refuses_overwrite

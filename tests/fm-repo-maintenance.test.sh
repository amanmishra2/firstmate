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
  mkdir -p "$proj/src/a/b/c/d/e" "$proj/bin" "$proj/docs" "$proj/tests"
  ( cd "$proj" && git init -q )
  printf '# proj\n\nSetup and validation for the fixture.\n' > "$proj/README.md"
  # shellcheck disable=SC2016  # backticks are literal fixture content, not command substitution.
  printf '# proj agents\n\n| Task | Domain | Files | Tests |\n| --- | --- | --- | --- |\n| maintain fixture | tooling | `bin/tool.sh` | `tests/fixture.test.sh` |\n' > "$proj/AGENTS.md"
  i=1
  while [ "$i" -le 700 ]; do printf 'line %s\n' "$i"; i=$((i + 1)); done > "$proj/src/one.py"
  printf 'deep = 1\n' > "$proj/src/a/b/c/d/deep.py"
  printf 'deeper = 1\n' > "$proj/src/a/b/c/d/e/deeper.py"
  i=1
  while [ "$i" -le 620 ]; do printf 'x %s\n' "$i"; i=$((i + 1)); done > "$proj/big2.py"
  i=1
  while [ "$i" -le 620 ]; do printf 'z %s\n' "$i"; i=$((i + 1)); done > "$proj/zz-malformed.py"
  printf '#!/usr/bin/env bash\necho tool\n' > "$proj/bin/tool.sh"
  printf '#!/usr/bin/env bash\nprintf "fixture test\\n"\n' > "$proj/tests/fixture.test.sh"
  # shellcheck disable=SC2016  # backticks are literal fixture content, not command substitution.
  printf '# tests\n\nRole: fixture validation tests.\n\n| File | Responsibility | Key Exported Symbols |\n| --- | --- | --- |\n| `fixture.test.sh` | fixture checks | - |\n' > "$proj/tests/SUMMARY.md"
  printf 'unicode fixture\n' > "$proj/src/unicode.txt"
  # shellcheck disable=SC2016  # backticks are literal fixture content, not command substitution.
  printf '# bin\n\nRole: fixture tooling.\n\n| File | Responsibility | Key Exported Symbols |\n| --- | --- | --- |\n| `other.sh` | fixture | - |\n' > "$proj/bin/SUMMARY.md"
  {
    printf '# docs\n\nRole: first sentence. second sentence.\n\n| File | Responsibility | Key Exported Symbols |\n| --- | --- | --- |\n'
    i=1
    while [ "$i" -le 26 ]; do printf 'summary line %s\n' "$i"; i=$((i + 1)); done
  } > "$proj/docs/SUMMARY.md"
  # shellcheck disable=SC2016  # backticks are literal fixture content, not command substitution.
  printf '# src\n\nRole: fixture sources.\n\n| File | Responsibility | Key Exported Symbols |\n| --- | --- | --- |\n| `one.py` | fixture logic | - |\n' > "$proj/src/SUMMARY.md"
  ( cd "$proj" && git add -A && git commit -qm fixture )

  printf 'big2.py :: verified cold batch path for the fixture\nzz-malformed.py ::\nmalformed-without-reason ::\n:: missing path\n' > "$home/data/repo-maintenance/proj/exemptions.txt"
  cp -R "$proj" "$pool"
  rm -rf "$pool/.git"
  printf '# Projects\n\n- proj [no-mistakes] - Fixture project (added 2026-10-18)\n' > "$home/data/projects.md"

  # opencode fixture: ses_a reads one.py three times and edits it at turn 4;
  # ses_b reads one path outside every root; ses_c works outside the scope;
  # ses_d's completion predates the window; ses_in_progress has no completion.
  sqlite3 "$home/.local/share/opencode/opencode.db" <<SQL
CREATE TABLE session_v2 (id TEXT PRIMARY KEY, project_id TEXT, slug TEXT, directory TEXT, idle_outcome TEXT, time_idle INTEGER);
CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, seq INTEGER, time_created INTEGER, data TEXT);
INSERT INTO session_v2 VALUES ('ses_a', 'p', 'curious-proj', '$pool', 'succeeded', 1792400000000);
INSERT INTO session_v2 VALUES ('ses_b', 'p', 'steady-proj', '$proj', 'succeeded', 1792400100000);
INSERT INTO session_v2 VALUES ('ses_c', 'p', 'outside', '/tmp/elsewhere', 'succeeded', 1792400200000);
INSERT INTO session_v2 VALUES ('ses_d', 'p', 'old-work', '$pool', 'succeeded', 1791700000000);
INSERT INTO session_v2 VALUES ('ses_unicode', 'p', 'unicode-work', '$pool', 'failed', 1792400250000);
INSERT INTO session_v2 VALUES ('ses_shell', 'p', 'shell-only', '$pool', 'interrupted', 1792400260000);
INSERT INTO session_v2 VALUES ('ses_in_progress', 'p', 'still-working', '$pool', NULL, NULL);
INSERT INTO session_message VALUES ('a1', 'ses_a', 'assistant', 1, 1791700000000,
 '{"tokens":{"input":1000,"output":100,"reasoning":0,"cache":{"read":0,"write":0}},"content":[{"type":"tool","name":"read","state":{"status":"completed","input":{"path":"$pool/src/one.py"},"content":[{"type":"text","text":"$(printf 'p%.0s' $(seq 1 400))"}]}},{"type":"tool","name":"edit","state":{"status":"error","input":{"path":"$pool/src/one.py"},"content":[{"type":"text","text":"edit failed"}]}}]}');
INSERT INTO session_message VALUES ('a2', 'ses_a', 'assistant', 2, 1792399910000,
 '{"tokens":{"input":2000,"output":100,"reasoning":0,"cache":{"read":0,"write":0}},"content":[{"type":"tool","name":"read","state":{"status":"completed","input":{"path":"$pool/src/one.py"},"content":[{"type":"text","text":"$(printf 'p%.0s' $(seq 1 410))"}]}}]}');
INSERT INTO session_message VALUES ('a3', 'ses_a', 'assistant', 3, 1792399920000,
 '{"tokens":{"input":3000,"output":100,"reasoning":0,"cache":{"read":0,"write":0}},"content":[{"type":"tool","name":"read","state":{"status":"completed","input":{"path":"$pool/src/one.py"},"content":[{"type":"text","text":"$(printf 'p%.0s' $(seq 1 420))"}]}},{"type":"tool","name":"read","state":{"status":"completed","input":{"path":"$pool/README.md"},"content":[{"type":"text","text":"short"}]}},{"type":"tool","name":"read","state":{"status":"error","input":{"path":"$pool/src/missing.py"},"content":[{"type":"text","text":"file not found"}]}}]}');
INSERT INTO session_message VALUES ('a4', 'ses_a', 'assistant', 4, 1792399930000,
 '{"tokens":{"input":4000,"output":100,"reasoning":0,"cache":{"read":0,"write":0}},"content":[{"type":"tool","name":"edit","state":{"status":"completed","input":{"path":"$pool/src/one.py"}}}]}');
INSERT INTO session_message VALUES ('a0', 'ses_a', 'user', 0, 1792399890000, '{"text":"secret prompt text"}');
INSERT INTO session_message VALUES ('b1', 'ses_b', 'assistant', 1, 1792400050000,
 '{"tokens":{"input":500,"output":50,"reasoning":0,"cache":{"read":0,"write":0}},"content":[{"type":"tool","name":"read","state":{"status":"completed","input":{"path":"/tmp/outside/secret.py"},"content":[{"type":"text","text":"outside"}]}}]}');
INSERT INTO session_message VALUES ('c1', 'ses_c', 'assistant', 1, 1792400150000,
 '{"tokens":{"input":500,"output":50,"reasoning":0,"cache":{"read":0,"write":0}},"content":[{"type":"tool","name":"read","state":{"status":"completed","input":{"path":"/tmp/elsewhere/nope.py"},"content":[{"type":"text","text":"nope"}]}}]}');
INSERT INTO session_message VALUES ('d1', 'ses_d', 'assistant', 1, 1791700000000,
 '{"tokens":{"input":500,"output":50,"reasoning":0,"cache":{"read":0,"write":0}},"content":[{"type":"tool","name":"read","state":{"status":"completed","input":{"path":"$pool/src/one.py"},"content":[{"type":"text","text":"old"}]}}]}');
INSERT INTO session_message VALUES ('u1', 'ses_unicode', 'assistant', 1, 1792400250000,
 '{"tokens":{"input":600,"output":60,"reasoning":0,"cache":{"read":0,"write":0}},"content":[{"type":"tool","name":"read","state":{"status":"completed","input":{"path":"$pool/src/unicode.txt"},"content":[{"type":"text","text":"é"}]}}]}');
INSERT INTO session_message VALUES ('s1', 'ses_shell', 'assistant', 1, 1792400260000,
 '{"tokens":{"input":700,"output":70,"reasoning":0,"cache":{"read":0,"write":0}},"content":[{"type":"tool","name":"bash","state":{"status":"completed","input":{"command":"printf changed > src/one.py"}}}]}');
INSERT INTO session_message VALUES ('p1', 'ses_in_progress', 'assistant', 1, 1792400260000,
 '{"tokens":{"input":800,"output":80,"reasoning":0,"cache":{"read":0,"write":0}},"content":[{"type":"tool","name":"read","state":{"status":"completed","input":{"path":"$pool/src/one.py"},"content":[{"type":"text","text":"unfinished"}]}}]}');
SQL

  # codex fixture: three turn contexts, an apply_patch at turn 2, and token totals.
  {
    printf '{"timestamp":"2026-10-18T10:00:00.000Z","type":"session_meta","payload":{"session_id":"cdx_a","cwd":"%s","timestamp":"2026-10-18T10:00:00.000Z"}}\n' "$pool"
    printf '{"timestamp":"2026-10-18T10:00:00.500Z","type":"event_msg","payload":{"type":"task_started","turn_id":"task-a"}}\n'
    printf '{"timestamp":"2026-10-18T10:00:01.000Z","type":"turn_context","payload":{"turn_id":"t1"}}\n'
    printf '{"timestamp":"2026-10-18T10:00:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":5000,"input_tokens":5000}}}}\n'
    printf '{"timestamp":"2026-10-18T10:00:02.500Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":8000,"input_tokens":8000},"last_token_usage":{"input_tokens":3000}}}}\n'
    printf '{"timestamp":"2026-10-18T10:00:02.750Z","type":"response_item","payload":{"type":"function_call","call_id":"write-fail","name":"write","arguments":"{}"}}\n'
    printf '{"timestamp":"2026-10-18T10:00:02.800Z","type":"response_item","payload":{"type":"function_call_output","call_id":"write-fail","output":{"success":false}}}\n'
    printf '{"timestamp":"2026-10-18T10:00:02.900Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"message","call_id":"write-fail","output":"not a completed function call"}}}\n'
    printf '{"timestamp":"2026-10-18T10:00:03.000Z","type":"turn_context","payload":{"turn_id":"t2"}}\n'
    printf '{"timestamp":"2026-10-18T10:00:03.500Z","type":"response_item","payload":{"type":"function_call","call_id":"exec-string","name":"exec_command","arguments":"{\\"cmd\\":\\"printf changed > src/one.py\\"}"}}\n'
    printf '{"timestamp":"2026-10-18T10:00:03.750Z","type":"response_item","payload":{"type":"function_call_output","call_id":"exec-string","output":"command completed"}}\n'
    printf '{"timestamp":"2026-10-18T10:00:03.875Z","type":"response_item","payload":{"type":"function_call","call_id":"exec-array","name":"exec_command","arguments":"{}"}}\n'
    printf '{"timestamp":"2026-10-18T10:00:03.937Z","type":"response_item","payload":{"type":"function_call_output","call_id":"exec-array","output":[{"type":"text","text":"command completed"}]}}\n'
    printf '{"timestamp":"2026-10-18T10:00:04.000Z","type":"response_item","payload":{"type":"function_call","call_id":"patch-success","name":"apply_patch","arguments":"{}"}}\n'
    printf '{"timestamp":"2026-10-18T10:00:04.500Z","type":"response_item","payload":{"type":"function_call_output","call_id":"patch-success","output":"command completed"}}\n'
    printf '{"timestamp":"2026-10-18T10:00:04.750Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"function_call_output","call_id":"patch-success","output":"command completed"}}}\n'
    printf '{"timestamp":"2026-10-18T10:00:05.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":10000,"input_tokens":10000}}}}\n'
    printf '{"timestamp":"2026-10-18T10:00:06.000Z","type":"turn_context","payload":{"turn_id":"t3"}}\n'
    printf '{"timestamp":"2026-10-18T10:00:07.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"task-a"}}\n'
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
  out="$lab/home/data/repo-maintenance/metrics/2026-10-19.json"
  "$TOOL" mine --now 1792400300 "$@" >/dev/null || fail "mine failed"
  printf '%s\n' "$out"
}

test_structure_reports_ceiling_depth_and_summary_gaps() {
  local lab proj out
  lab=$(make_lab structure-basic)
  lab_env "$lab"
  proj="$lab/home/projects/proj"
  out=$("$TOOL" structure "$proj" --json) || fail "structure exited nonzero"

  assert_equals "2" "$(printf '%s' "$out" | jq -r '.files_over_ceiling.total')" "blank-reason exemptions do not hide over-ceiling files"
  assert_equals "1" "$(printf '%s' "$out" | jq -r '.files_over_ceiling.exempt')" "big2.py is exempted"
  assert_equals "src/one.py" "$(printf '%s' "$out" | jq -r '.files_over_ceiling.listed[0].path')" "the listed file is one.py"
  assert_equals "zz-malformed.py" "$(printf '%s' "$out" | jq -r '.files_over_ceiling.listed[1].path')" "the malformed exemption file is listed"
  assert_equals "1" "$(printf '%s' "$out" | jq -r '.depth_violations.total')" "five directories below src/ violate the depth bound"
  assert_equals "src/a/b/c/d/e/deeper.py" "$(printf '%s' "$out" | jq -r '.depth_violations.listed[0].path')" "the five-level path is the depth violation"
  assert_equals "5" "$(printf '%s' "$out" | jq -r '.dirs_missing_summary.total')" "every tracked ancestor without SUMMARY.md is reported"
  assert_equals "bin/tool.sh" "$(printf '%s' "$out" | jq -r '.summary_gaps.listed[0].file')" "bin/tool.sh is not listed by its summary"
  assert_equals "1" "$(printf '%s' "$out" | jq -r '.summary_over_limit.total')" "docs/SUMMARY.md exceeds 30 lines"
  assert_equals "1" "$(printf '%s' "$out" | jq -r '.summary_invalid.total')" "invalid summary shape is reported"
  assert_equals "true" "$(printf '%s' "$out" | jq -r '.entrypoints.routing_ok')" "AGENTS.md has a concrete routing row"
  assert_equals "true" "$(printf '%s' "$out" | jq -r '.entrypoints.ok')" "root entrypoints and routing are valid"
  assert_contains "$(printf '%s' "$out" | jq -r '.root_orphans.listed[].file')" "big2.py" "root-level tracked files are audited"
  pass "structure reports ceiling, depth, and SUMMARY findings with exemptions honored"
}

test_structure_and_sweep_list_all_findings() {
  local lab proj out total listed src_listed report report_listed status=0 i
  lab=$(make_lab structure-untruncated)
  lab_env "$lab"
  proj="$lab/home/projects/proj"
  i=1
  while [ "$i" -le 31 ]; do
    printf 'gap %s\n' "$i" > "$proj/src/gap-$i.py"
    i=$((i + 1))
  done
  ( cd "$proj" && git add src && git commit -qm 'add summary-gap fixtures' )

  out=$("$TOOL" structure "$proj" --json) || fail "structure exited nonzero"
  total=$(printf '%s' "$out" | jq -r '.summary_gaps.total')
  listed=$(printf '%s' "$out" | jq -r '.summary_gaps.listed | length')
  src_listed=$(printf '%s' "$out" | jq -r '[.summary_gaps.listed[] | select(.summary == "src/SUMMARY.md")] | length')
  [ "$total" -gt 30 ] || fail "fixture did not exceed 30 summary gaps"
  assert_equals "$total" "$listed" "every structure finding is listed"

  status=0
  "$TOOL" structure "$proj" --max-findings 1 --json >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "structure no longer accepts a findings limit"
  status=0
  "$TOOL" sweep proj --date 2026-10-18 --max-findings 1 >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "sweep no longer accepts a findings limit"

  "$TOOL" mine --now 1792400300 >/dev/null || fail "mine failed before sweep"
  "$TOOL" sweep proj --date 2026-10-18 >/dev/null || fail "sweep exited nonzero"
  report="$lab/home/data/repo-maintenance/proj/2026-10-18/report.md"
  report_listed=$(grep -Fc 'not in `src/SUMMARY.md`' "$report")
  assert_equals "$src_listed" "$report_listed" "sweep publishes every source-summary gap"
  pass "structure and sweep report every finding without a limit"
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

test_structure_requires_routing_table_and_ignores_malformed_exemptions() {
  local lab proj out human
  lab=$(make_lab structure-routing)
  lab_env "$lab"
  proj="$lab/home/projects/proj"
  rm -f "$proj/AGENTS.md"
  printf '# claude only\n' > "$proj/CLAUDE.md"
  out=$($TOOL structure "$proj" --json) || fail "structure exited nonzero"
  assert_equals "false" "$(printf '%s' "$out" | jq -r '.entrypoints.agents')" "CLAUDE.md cannot replace AGENTS.md"
  assert_equals "false" "$(printf '%s' "$out" | jq -r '.entrypoints.routing_ok')" "missing AGENTS.md has no routing table"
  assert_equals "false" "$(printf '%s' "$out" | jq -r '.entrypoints.ok')" "invalid entrypoints fail the structure result"
  assert_equals "1" "$(printf '%s' "$out" | jq -r '.files_over_ceiling.exempt')" "only the nonempty exemption reason is honored"
  : > "$proj/AGENTS.md"
  out=$($TOOL structure "$proj" --json) || fail "structure exited nonzero for empty AGENTS.md"
  assert_equals "true" "$(printf '%s' "$out" | jq -r '.entrypoints.agents')" "an empty AGENTS.md is still detected"
  assert_equals "false" "$(printf '%s' "$out" | jq -r '.entrypoints.agents_valid')" "an empty AGENTS.md is invalid"
  assert_equals "false" "$(printf '%s' "$out" | jq -r '.entrypoints.ok')" "an empty AGENTS.md cannot produce a clean result"
  printf '# one line\n' > "$proj/README.md"
  out=$($TOOL structure "$proj" --json) || fail "structure exited nonzero for one-line README"
  assert_equals "false" "$(printf '%s' "$out" | jq -r '.entrypoints.readme_valid')" "a one-line README is invalid"
  printf '# proj\n\nSetup and validation for the fixture.\n' > "$proj/README.md"
  printf '# malformed routing\n' > "$proj/AGENTS.md"
  out=$($TOOL structure "$proj" --json) || fail "structure exited nonzero for malformed AGENTS.md"
  assert_equals "false" "$(printf '%s' "$out" | jq -r '.entrypoints.agents_valid')" "a one-line AGENTS.md route is invalid"
  assert_equals "false" "$(printf '%s' "$out" | jq -r '.entrypoints.routing_ok')" "a malformed AGENTS.md has no routing table"
  assert_equals "false" "$(printf '%s' "$out" | jq -r '.entrypoints.ok')" "a malformed AGENTS.md cannot produce a clean result"
  # shellcheck disable=SC2016  # backticks are literal fixture content, not command substitution.
  printf '# proj agents\n\n| Task | Domain | Files | Tests |\n| --- | --- | --- | --- |\n| todo | todo | `missing.py` | `missing-test.sh` |\n' > "$proj/AGENTS.md"
  out=$($TOOL structure "$proj" --json) || fail "structure exited nonzero for placeholder routing"
  assert_equals "false" "$(printf '%s' "$out" | jq -r '.entrypoints.routing_ok')" "placeholder task and domain cells with missing targets are invalid"
  # shellcheck disable=SC2016  # backticks are literal fixture content, not command substitution.
  printf '# proj agents\n\n| Task | Domain | Files | Tests |\n| --- | --- | --- | --- |\n| maintain fixture | tooling | `bin/tool.sh` plus missing.py | `tests/fixture.test.sh` |\n' > "$proj/AGENTS.md"
  out=$($TOOL structure "$proj" --json) || fail "structure exited nonzero for mixed routing targets"
  assert_equals "false" "$(printf '%s' "$out" | jq -r '.entrypoints.routing_ok')" "a valid target plus stray missing path is invalid"
  printf '# proj agents\n\n| Task | Domain | Files | Tests |\n| --- | --- | --- | --- |\n| maintain fixture | tooling | `bin/tool.sh` | `tests/fixture.test.sh` |\n' > "$proj/AGENTS.md"
  printf 'orphan = 1\n' > "$proj/orphan.py"
  ( cd "$proj" && git add AGENTS.md orphan.py && git commit -qm 'add root orphan fixture' )
  out=$($TOOL structure "$proj" --json) || fail "structure exited nonzero for root orphan"
  assert_contains "$(printf '%s' "$out" | jq -r '.root_orphans.listed[].file')" "orphan.py" "unlisted tracked root files are reported"
  human=$($TOOL structure "$proj") || fail "human structure output failed for root orphan"
  assert_contains "$human" "root orphan files:" "human structure output reports root orphan totals"
  assert_contains "$human" "  orphan.py" "human structure output lists root orphan paths"
  # shellcheck disable=SC2016  # backticks are literal fixture content, not command substitution.
  printf '# TODO - fill this in\n\nRole: fixture sources.\n\n| File | Responsibility | Key Exported Symbols |\n| --- | --- | --- |\n| `one.py` | fixture logic | - |\n' > "$proj/src/SUMMARY.md"
  out=$($TOOL structure "$proj" --json) || fail "structure exited nonzero for placeholder summary heading"
  assert_contains "$(printf '%s' "$out" | jq -r '.summary_invalid.listed[].summary')" "src/SUMMARY.md" "placeholder summary headings are invalid"
  assert_contains "$(printf '%s' "$out" | jq -r '.summary_gaps.listed[] | select(.summary == "src/SUMMARY.md") | .file')" "src/one.py" "invalid summaries do not silently pass child files"
  # shellcheck disable=SC2016  # backticks are literal fixture content, not command substitution.
  printf '# src\n\nRole: TODO - fill this in.\n\n| File | Responsibility | Key Exported Symbols |\n| --- | --- | --- |\n| `one.py` | fixture logic | - |\n' > "$proj/src/SUMMARY.md"
  out=$($TOOL structure "$proj" --json) || fail "structure exited nonzero for placeholder summary role"
  assert_contains "$(printf '%s' "$out" | jq -r '.summary_invalid.listed[].summary')" "src/SUMMARY.md" "placeholder summary roles are invalid"
  # shellcheck disable=SC2016  # backticks are literal fixture content, not command substitution.
  printf '# src\n\nRole: fixture sources.\n\n| File | Responsibility | Key Exported Symbols |\n| --- | --- | --- |\n| `one.py` | fixture logic | TODO - fill this in |\n' > "$proj/src/SUMMARY.md"
  out=$($TOOL structure "$proj" --json) || fail "structure exited nonzero for placeholder summary exports"
  assert_contains "$(printf '%s' "$out" | jq -r '.summary_invalid.listed[].summary')" "src/SUMMARY.md" "placeholder summary exports are invalid"
  pass "structure validates entrypoint content, routing targets, and root orphans"
}

test_mine_extracts_read_metrics_from_opencode() {
  local lab metrics
  lab=$(make_lab mine-opencode)
  metrics=$(lab_mine "$lab")

  assert_equals "4" "$(jq -r '.tasks[] | select(.source=="opencode" and .turns==4) | .turns' "$metrics")" "four assistant turns"
  assert_equals "4" "$(jq -r '.tasks[] | select(.source=="opencode" and .turns==4) | .first_edit_turn' "$metrics")" "the first edit lands on turn 4"
  assert_equals "10400" "$(jq -r '.tasks[] | select(.source=="opencode" and .turns==4) | .tokens_total' "$metrics")" "token counters sum once per turn"
  assert_equals "6000" "$(jq -r '.tasks[] | select(.source=="opencode" and .turns==4) | .tokens_exploration' "$metrics")" "prompt tokens stop before the edit turn"
  assert_equals "4" "$(jq -r '.tasks[] | select(.source=="opencode" and .turns==4) | .files_read' "$metrics")" "four read events"
  assert_equals "2" "$(jq -r '.tasks[] | select(.source=="opencode" and .turns==4) | .unique_files' "$metrics")" "two unique files"
  assert_equals "2" "$(jq -r '.tasks[] | select(.source=="opencode" and .turns==4) | .reread_reads' "$metrics")" "two repeat read events"
  assert_equals "1" "$(jq -r '.tasks[] | select(.source=="opencode" and .turns==4) | .three_plus_read_files' "$metrics")" "one file is read three times"

  assert_equals "3" "$(jq -r '.files[] | select(.path=="src/one.py") | .reads' "$metrics")" "one.py was read three times"
  assert_equals "1" "$(jq -r '.files[] | select(.path=="src/one.py") | .tasks' "$metrics")" "one task read one.py"
  assert_equals "2" "$(jq -r '.files[] | select(.path=="src/one.py") | .reread_reads' "$metrics")" "two repeat reads of one.py"
  assert_equals "1" "$(jq -r '.files[] | select(.path=="src/one.py") | .reread_tasks' "$metrics")" "one task re-read one.py"
  assert_equals "1" "$(jq -r '.files[] | select(.path=="src/one.py") | .three_plus_read_tasks' "$metrics")" "one task read one.py three times"
  assert_equals "420" "$(jq -r '.files[] | select(.path=="src/one.py") | .max_payload_bytes' "$metrics")" "the largest observed payload wins"
  assert_equals "projects/proj" "$(jq -r '.files[] | select(.path=="src/one.py") | .scope' "$metrics")" "the pool worktree maps to the project scope"
  assert_equals "0" "$(jq -r '[.files[] | select(.path=="src/missing.py")] | length' "$metrics")" "a failed read creates no file row or stale-size fallback"

  assert_equals "1" "$(jq -r '.external.reads' "$metrics")" "the out-of-scope read is counted"
  assert_equals "1" "$(jq -r '.external.tasks' "$metrics")" "the out-of-scope task is counted"
  assert_equals "4" "$(jq -r '.coverage[] | select(.source=="opencode") | .sessions_seen' "$metrics")" "unfinished and pre-window sessions are omitted from the cohort"
  assert_equals "4" "$(jq -r '.coverage[] | select(.source=="opencode") | .sessions_mined' "$metrics")" "four opencode sessions were mined"
  assert_equals "0" "$(jq -r '.coverage[] | select(.source=="opencode") | .skipped_empty' "$metrics")" "pre-window and unfinished sessions are omitted without empty skips"
  assert_equals "false" "$(jq -r '.coverage[] | select(.source=="opencode") | has("skipped_cap")' "$metrics")" "opencode coverage has no cap field"
  assert_equals "2" "$(jq -r '.files[] | select(.path=="src/unicode.txt") | .max_payload_bytes' "$metrics")" "SQLite payload size uses UTF-8 bytes"
  assert_equals "1" "$(jq -r '[.tasks[] | select(.source=="opencode" and .files_read == 0 and .first_edit_turn == null)] | length' "$metrics")" "shell-only mutation has no named edit turn"
  assert_equals "5" "$(jq -r '.tasks | length' "$metrics")" "the pre-window session is never mined"
  assert_not_contains "$(cat "$metrics")" '"id"' "task identifiers are not persisted"
  assert_not_contains "$(cat "$metrics")" 'curious-proj' "task slugs are not persisted"
  pass "mine extracts opencode read, edit, and token aggregates"
}

test_mine_keeps_distinct_home_and_code_roots_aligned() {
  local lab code metrics rank
  lab=$(make_lab mine-separate-roots)
  code="$lab/code"
  mkdir -p "$code"
  printf 'code one\ncode two\ncode three\n' > "$code/README.md"
  printf 'home one\nhome two\n' > "$lab/home/README.md"
  sqlite3 "$lab/home/.local/share/opencode/opencode.db" <<SQL
INSERT INTO session_v2 VALUES ('ses_code_root', 'p', 'code-root', '$code', 'succeeded', 1792400270000);
INSERT INTO session_v2 VALUES ('ses_home_root', 'p', 'home-root', '$lab/home', 'succeeded', 1792400280000);
INSERT INTO session_message VALUES ('code_read', 'ses_code_root', 'assistant', 1, 1792400270000,
 '{"tokens":{"input":100,"output":10,"reasoning":0,"cache":{"read":0,"write":0}},"content":[{"type":"tool","name":"read","state":{"status":"completed","input":{"path":"$code/README.md"},"content":[{"type":"text","text":"code"}]}}]}');
INSERT INTO session_message VALUES ('home_read', 'ses_home_root', 'assistant', 1, 1792400280000,
 '{"tokens":{"input":100,"output":10,"reasoning":0,"cache":{"read":0,"write":0}},"content":[{"type":"tool","name":"read","state":{"status":"completed","input":{"path":"$lab/home/README.md"},"content":[{"type":"text","text":"home"}] }},{"type":"tool","name":"read","state":{"status":"completed","input":{"path":"$lab/home"},"content":[{"type":"text","text":"directory"}]}}]}');
SQL
  lab_env "$lab"
  metrics="$lab/home/data/repo-maintenance/metrics/2026-10-19.json"
  FM_HOME="$lab/home" FM_ROOT_OVERRIDE="$code" \
    "$TOOL" mine --now 1792400300 >/dev/null || fail "mine failed with distinct home and code roots"
  rank=$(FM_HOME="$lab/home" FM_ROOT_OVERRIDE="$code" \
    "$TOOL" rank --metrics "$metrics" --json) || fail "rank failed with distinct home and code roots"

  assert_equals "firstmate" "$(jq -r '.files[] | select(.path=="README.md" and .scope=="firstmate") | .scope' "$metrics")" "code-root reads use firstmate scope"
  assert_equals "home" "$(jq -r '.files[] | select(.path=="README.md" and .scope=="home") | .scope' "$metrics")" "other home reads retain home scope"
  assert_equals "3" "$(printf '%s' "$rank" | jq -r '.files[] | select(.scope=="firstmate" and .path=="README.md") | .lines')" "firstmate ranking reads the code-root file"
  assert_equals "2" "$(printf '%s' "$rank" | jq -r '.files[] | select(.scope=="home" and .path=="README.md") | .lines')" "home ranking reads the home-root file"
  assert_equals "2" "$(jq -r '.external.reads' "$metrics")" "an exact home-root read is external and failed reads are omitted"
  assert_not_contains "$(cat "$metrics")" "$lab" "neither split-root paths nor the exact home root are persisted"
  assert_equals "<FIRSTMATE>" "$(jq -r '.roots[] | select(.=="<FIRSTMATE>")' "$metrics")" "the separate code root is represented by a sanitized label"
  pass "mine and rank keep split physical roots aligned"
}

test_mine_resolves_file_paths_when_realpath_fails() {
  local lab fakebin metrics no_realpath_path
  lab=$(make_lab mine-realpath-fallback)
  fakebin="$lab/fake-bin"
  mkdir -p "$fakebin"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/realpath"
  chmod +x "$fakebin/realpath"
  lab_env "$lab"
  PATH="$fakebin:$PATH" FM_HOME="$lab/home" \
    "$TOOL" mine --now 1792400300 >/dev/null || fail "mine failed when realpath failed"
  no_realpath_path=$(fm_test_base_path_sans "$PATH" realpath) || fail "could not build PATH without realpath"
  if PATH="$no_realpath_path" command -v realpath >/dev/null 2>&1; then
    fail "realpath remained available in the missing-command fixture"
  fi
  PATH="$no_realpath_path" FM_HOME="$lab/home" \
    "$TOOL" mine --now 1792400300 >/dev/null || fail "mine failed when realpath was absent"
  metrics="$lab/home/data/repo-maintenance/metrics/2026-10-19.json"

  assert_equals "3" "$(jq -r '.files[] | select(.path=="src/one.py") | .reads' "$metrics")" "existing files remain classifiable through their physical parent"
  assert_equals "projects/proj" "$(jq -r '.files[] | select(.path=="src/one.py") | .scope' "$metrics")" "the fallback retains project scope"
  pass "mine resolves regular file paths when realpath fails or is absent"
}

test_mine_cleanup_preserves_paths_with_spaces() {
  local lab metrics
  lab=$(make_lab mine-cleanup-spaces)
  mkdir -p "$lab/tmp" "$lab/tmp area"
  printf 'keep\n' > "$lab/tmp/sentinel"
  lab_env "$lab"
  TMPDIR="$lab/tmp area" FM_HOME="$lab/home" \
    "$TOOL" mine --now 1792400300 >/dev/null || fail "mine failed with a TMPDIR containing spaces"
  metrics="$lab/home/data/repo-maintenance/metrics/2026-10-19.json"
  TMPDIR="$lab/tmp area" FM_HOME="$lab/home" \
    "$TOOL" rank --metrics "$metrics" --project proj --json >/dev/null || fail "rank failed with a TMPDIR containing spaces"
  TMPDIR="$lab/tmp area" FM_HOME="$lab/home" \
    "$TOOL" structure "$lab/home/projects/proj" --json >/dev/null || fail "structure failed with a TMPDIR containing spaces"
  TMPDIR="$lab/tmp area" FM_HOME="$lab/home" \
    "$TOOL" sweep proj --date 2026-10-19 >/dev/null || fail "sweep failed with a TMPDIR containing spaces"

  assert_equals "keep" "$(cat "$lab/tmp/sentinel")" "cleanup preserves the path before the space across every command"
  pass "repo-maintenance cleanup preserves paths with spaces"
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
  metrics=$(lab_mine "$lab")

  assert_equals "codex" "$(jq -r '.tasks[] | select(.source=="codex") | .source' "$metrics")" "the rollout is mined as a codex task"
  assert_equals "3" "$(jq -r '.tasks[] | select(.source=="codex") | .turns' "$metrics")" "turn contexts count as turns"
  assert_equals "2" "$(jq -r '.tasks[] | select(.source=="codex") | .first_edit_turn' "$metrics")" "shell exec_command does not count before apply_patch on turn 2"
  assert_equals "10000" "$(jq -r '.tasks[] | select(.source=="codex") | .tokens_total' "$metrics")" "the last token count is the total"
  assert_equals "8000" "$(jq -r '.tasks[] | select(.source=="codex") | .tokens_exploration' "$metrics")" "cumulative input tokens stop before the edit"
  assert_equals "0" "$(jq -r '.tasks[] | select(.source=="codex") | .files_read' "$metrics")" "codex contributes no guessed file rows"
  assert_equals "0" "$(jq -r '[.tasks[] | select(.source=="codex" and .files_read > 0)] | length' "$metrics")" "no file rows come from shell-mediated reads"
  assert_not_contains "$(cat "$metrics")" 'cdx_a' "codex session identifiers are not persisted"
  pass "mine extracts codex task-span metrics without guessing file reads"
}

test_mine_reports_absent_sources() {
  local lab out status=0
  lab=$(make_lab mine-absent)
  mkdir -p "$lab/home"
  FM_HOME="$lab/home" FM_RM_OPENCODE_DB="$lab/home/none.db" FM_RM_CODEX_SESSIONS="$lab/home/none" \
    "$TOOL" mine --now 1792400300 >/dev/null || status=$?
  expect_code 0 "$status" "mine succeeds with absent sources"
  out=$(cat "$lab/home/data/repo-maintenance/metrics/2026-10-19.json")
  assert_equals "absent" "$(printf '%s' "$out" | jq -r '.coverage[] | select(.source=="opencode") | .status')" "the missing opencode store is reported absent"
  assert_equals "absent" "$(printf '%s' "$out" | jq -r '.coverage[] | select(.source=="codex") | .status')" "the missing codex root is reported absent"
  pass "mine reports absent sources instead of failing silently"
}

test_mine_skips_external_stores() {
  local lab home outside db codex metrics out mode db_path codex_path source report
  lab=$(make_lab mine-external-stores)
  home="$lab/home"
  outside="$lab/outside"
  mkdir -p "$outside"
  cp "$home/.local/share/opencode/opencode.db" "$outside/opencode.db"
  cp -R "$home/.codex/sessions" "$outside/"
  db="$home/.local/share/opencode/external.db"
  codex="$home/.codex/external-sessions"
  ln -s "$outside/opencode.db" "$db"
  ln -s "$outside/sessions" "$codex"
  metrics="$home/data/repo-maintenance/metrics/2026-10-19.json"

  for mode in direct symlink relative; do
    if [ "$mode" = direct ]; then
      db_path="$outside/opencode.db"
      codex_path="$outside/sessions"
    elif [ "$mode" = relative ]; then
      db_path="outside/opencode.db"
      codex_path="outside/sessions"
    else
      db_path=$db
      codex_path=$codex
    fi
    if [ "$mode" = relative ]; then
      out=$(cd "$lab" && FM_HOME="$home" FM_RM_OPENCODE_DB="$db_path" FM_RM_CODEX_SESSIONS="$codex_path" \
        FM_RM_SESSION_ROOTS="$home:$lab/pool" "$TOOL" mine --now 1792400300) || fail "mine rejected $mode outside stores"
    else
      out=$(FM_HOME="$home" FM_RM_OPENCODE_DB="$db_path" FM_RM_CODEX_SESSIONS="$codex_path" \
        FM_RM_SESSION_ROOTS="$home:$lab/pool" "$TOOL" mine --now 1792400300) || fail "mine rejected $mode outside stores"
    fi
    for source in opencode codex; do
      assert_equals "outside-home" "$(jq -r --arg source "$source" '.coverage[] | select(.source == $source) | .status' "$metrics")" "$source $mode store is rejected"
      assert_equals "0" "$(jq -r --arg source "$source" '.coverage[] | select(.source == $source) | .sessions_seen' "$metrics")" "$source $mode store is not enumerated"
      assert_contains "$out" "$source skipped: source store is outside firstmate home" "$source $mode skip is reported clearly"
    done
    assert_equals "0" "$(jq -r '.tasks | length' "$metrics")" "$mode outside stores contribute no tasks"
    assert_equals "0" "$(jq -r '.files | length' "$metrics")" "$mode outside stores contribute no file rows"
    assert_equals "<EXTERNAL>" "$(jq -r '.coverage[0].path' "$metrics")" "$mode source location stays sanitized"
    assert_not_contains "$(cat "$metrics")" "$outside" "$mode source path is not persisted"
  done
  FM_HOME="$home" "$TOOL" sweep proj --date 2026-10-18 >/dev/null || fail "sweep failed with external stores"
  report="$home/data/repo-maintenance/proj/2026-10-18/report.md"
  assert_contains "$(cat "$report")" "source store is outside firstmate home" "sweep explains skipped external sources"
  assert_not_contains "$(cat "$report")" "$outside" "sweep does not persist external source paths"
  pass "mine rejects external and symlink-escaped source stores"
}

test_mine_uses_fixed_home_data_root() {
  local lab expected alternate
  lab=$(make_lab mine-fixed-data-root)
  expected="$lab/home/data/repo-maintenance/metrics/2026-10-19.json"
  alternate="$lab/alternate/repo-maintenance/metrics/2026-10-19.json"
  lab_env "$lab"

  FM_HOME="$lab/home" FM_DATA_OVERRIDE="$lab/alternate" \
    FM_RM_OPENCODE_DB="$lab/home/.local/share/opencode/opencode.db" \
    FM_RM_CODEX_SESSIONS="$lab/home/.codex/sessions" \
    "$TOOL" mine --now 1792400300 >/dev/null || fail "mine failed with an ignored data override"
  assert_present "$expected" "metrics stay under the fixed home data root"
  assert_absent "$alternate" "the alternate data root receives no metrics"
  pass "mine keeps metrics under the fixed home data root"
}

test_mine_reports_empty_sources() {
  local lab empty_db out status=0
  lab=$(make_lab mine-empty)
  empty_db="$lab/home/empty.db"
  sqlite3 "$empty_db" 'CREATE TABLE session_v2 (id TEXT PRIMARY KEY, project_id TEXT, slug TEXT, directory TEXT, idle_outcome TEXT, time_idle INTEGER); CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, seq INTEGER, time_created INTEGER, data TEXT);'
  mkdir -p "$lab/home/empty-codex"
  FM_HOME="$lab/home" FM_RM_OPENCODE_DB="$empty_db" FM_RM_CODEX_SESSIONS="$lab/home/empty-codex" \
    "$TOOL" mine --now 1792400300 >/dev/null || status=$?
  expect_code 0 "$status" "mine succeeds with valid empty sources"
  out=$(cat "$lab/home/data/repo-maintenance/metrics/2026-10-19.json")
  assert_equals "empty" "$(printf '%s' "$out" | jq -r '.coverage[] | select(.source=="opencode") | .status')" "an empty opencode store is reported empty"
  assert_equals "empty" "$(printf '%s' "$out" | jq -r '.coverage[] | select(.source=="codex") | .status')" "an empty codex store is reported empty"
  pass "mine distinguishes valid empty sources from absent and unreadable stores"
}

test_rank_orders_by_token_heat() {
  local lab metrics rank
  lab=$(make_lab rank-basic)
  metrics=$(lab_mine "$lab")
  rank=$(FM_HOME="$lab/home" "$TOOL" rank --metrics "$metrics" --project proj --json) || fail "rank exited nonzero"

  assert_equals "src/one.py" "$(printf '%s' "$rank" | jq -r '.files[0].path')" "the re-read 700-line file leads the ranking"
  assert_equals "3096" "$(printf '%s' "$rank" | jq -r '.files[0].thi')" "THI is tasks x repeat reads x token size"
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

test_rank_zeroes_thi_for_distinct_single_reads_and_rejects_traversal() {
  local lab metrics rank fakebin
  lab=$(make_lab rank-boundaries)
  lab_env "$lab"
  metrics="$lab/home/data/repo-maintenance/metrics/single.json"
  mkdir -p "$(dirname "$metrics")"
  fakebin="$lab/fake-bin"
  mkdir -p "$fakebin"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/realpath"
  chmod +x "$fakebin/realpath"
  printf 'outside\n' > "$lab/outside.txt"
  ln -s "$lab/outside.txt" "$lab/home/projects/proj/escape.txt"
  cat > "$metrics" <<'JSON'
{"files":[
  {"scope":"projects/proj","path":"README.md","reads":3,"tasks":3,"reread_reads":0,"max_payload_bytes":12},
  {"scope":"projects/proj","path":"../README.md","reads":1,"tasks":1,"reread_reads":1,"max_payload_bytes":12},
  {"scope":"projects/proj","path":"escape.txt","reads":1,"tasks":1,"reread_reads":1,"max_payload_bytes":12},
  {"scope":"projects/proj","path":"bin/tool.sh","reads":1,"tasks":1,"reread_reads":0,"max_payload_bytes":12},
  {"scope":"projects/proj","path":"src/stale.py","reads":1,"tasks":1,"reread_reads":0,"max_payload_bytes":12},
  {"scope":"projects/proj","path":"src/unicode.txt","reads":1,"tasks":1,"reread_reads":0,"max_payload_bytes":12},
  {"scope":"projects/proj","path":"zz-malformed.py","reads":1,"tasks":1,"reread_reads":0,"max_payload_bytes":12}
]}
JSON
  rank=$(PATH="$fakebin:$PATH" FM_HOME="$lab/home" "$TOOL" rank --metrics "$metrics" --project proj --json) || fail "rank exited nonzero"
  assert_equals "0" "$(printf '%s' "$rank" | jq -r '.files[0].thi')" "one read in each distinct task has zero THI"
  assert_equals "2" "$(printf '%s' "$rank" | jq -r '.unresolved')" "traversal and symlink escape rows are unresolved"
  assert_equals "5" "$(printf '%s' "$rank" | jq -r '.files | length')" "resolvable rows reach ranking output"
  assert_equals "true" "$(printf '%s' "$rank" | jq -r '.files[] | select(.path=="README.md") | .nav')" "a valid root entrypoint is navigable"
  assert_equals "false" "$(printf '%s' "$rank" | jq -r '.files[] | select(.path=="bin/tool.sh") | .nav')" "a nested route cannot bypass a missing summary entry"
  assert_equals "false" "$(printf '%s' "$rank" | jq -r '.files[] | select(.path=="src/stale.py") | .nav')" "a stale path is not navigable"
  assert_equals "false" "$(printf '%s' "$rank" | jq -r '.files[] | select(.path=="src/unicode.txt") | .nav')" "an unlisted direct child is not navigable"
  assert_equals "false" "$(printf '%s' "$rank" | jq -r '.files[] | select(.path=="zz-malformed.py") | .nav')" "a slashless orphan is not navigable"
  pass "rank consumes validated navigation for existing, stale, and orphan paths"
}

test_mine_marks_session_enumeration_failures_unreadable() {
  local lab bad_db out status=0
  lab=$(make_lab mine-enumeration-failure)
  bad_db="$lab/home/bad.db"
  sqlite3 "$bad_db" 'CREATE TABLE other (value TEXT);'
  lab_env "$lab"
  FM_RM_OPENCODE_DB="$bad_db" FM_RM_CODEX_SESSIONS="$lab/home/no-codex-store" \
    "$TOOL" mine --now 1792400300 >/dev/null || status=$?
  expect_code 0 "$status" "mine reports an enumeration failure without aborting"
  out=$(cat "$lab/home/data/repo-maintenance/metrics/2026-10-19.json")
  assert_equals "unreadable" "$(printf '%s' "$out" | jq -r '.coverage[] | select(.source=="opencode") | .status')" "schema enumeration failure is unreadable"
  assert_equals "0" "$(printf '%s' "$out" | jq -r '.coverage[] | select(.source=="opencode") | .sessions_mined')" "schema failures cannot become mined"
  assert_equals "1" "$(printf '%s' "$out" | jq -r '.coverage[] | select(.source=="opencode") | .skipped_error')" "schema enumeration failure is counted as an error"
  assert_equals "absent" "$(printf '%s' "$out" | jq -r '.coverage[] | select(.source=="codex") | .status')" "the absent second source remains distinguishable"
  pass "mine marks session enumeration failures unreadable"
}

test_mine_marks_opencode_processing_failures_unreadable() {
  local lab fakebin real_sqlite out status=0
  lab=$(make_lab mine-opencode-query-failure)
  fakebin="$lab/fake-bin"
  real_sqlite=$(command -v sqlite3) || fail "sqlite3 is required for the query failure fixture"
  mkdir -p "$fakebin"
  cat > "$fakebin/sqlite3" <<'SH'
#!/usr/bin/env bash
set -u
query=""
for arg in "$@"; do query=$arg; done
case "$query" in
  *"SELECT m.seq AS seq,"*) exit 1 ;;
esac
exec "$FM_RM_TEST_SQLITE3" "$@"
SH
  chmod +x "$fakebin/sqlite3"
  lab_env "$lab"
  PATH="$fakebin:$PATH" FM_RM_TEST_SQLITE3="$real_sqlite" \
    FM_RM_CODEX_SESSIONS="$lab/home/no-codex" \
    "$TOOL" mine --now 1792400300 >/dev/null || status=$?
  expect_code 0 "$status" "mine reports OpenCode query failures without aborting"
  out=$(cat "$lab/home/data/repo-maintenance/metrics/2026-10-19.json")
  assert_equals "unreadable" "$(printf '%s' "$out" | jq -r '.coverage[] | select(.source=="opencode") | .status')" "query failures are not reported as empty"
  assert_equals "0" "$(printf '%s' "$out" | jq -r '.coverage[] | select(.source=="opencode") | .sessions_mined')" "failed queries cannot become mined"
  assert_equals "true" "$(printf '%s' "$out" | jq -r '.coverage[] | select(.source=="opencode") | (.skipped_error > 0)')" "processing failures are counted"
  pass "mine marks zero-mined OpenCode query failures unreadable"
}

test_mine_marks_codex_projection_failures_unreadable() {
  local lab fakebin codex_dir rollout real_jq out status=0
  lab=$(make_lab mine-codex-projection-failure)
  fakebin="$lab/fake-bin"
  codex_dir="$lab/home/codex"
  rollout="$codex_dir/rollout-projection.jsonl"
  real_jq=$(command -v jq) || fail "jq is required for the projection failure fixture"
  mkdir -p "$fakebin" "$codex_dir"
  cat > "$fakebin/jq" <<'SH'
#!/usr/bin/env bash
set -u
filter=""
for arg in "$@"; do filter=$arg; done
if [ "$filter" = '. + {source: "codex", dir: $dir}' ]; then exit 1; fi
exec "$FM_RM_TEST_JQ" "$@"
SH
  chmod +x "$fakebin/jq"
  printf '%s\n' \
    "{\"timestamp\":\"2026-10-18T10:00:00.000Z\",\"type\":\"session_meta\",\"payload\":{\"session_id\":\"cdx_projection\",\"cwd\":\"$lab/pool/proj-abc123/1/proj\",\"timestamp\":\"2026-10-18T10:00:00.000Z\"}}" \
    '{"timestamp":"2026-10-18T10:00:00.500Z","type":"event_msg","payload":{"type":"task_started","turn_id":"projection"}}' \
    '{"timestamp":"2026-10-18T10:00:01.000Z","type":"turn_context","payload":{"turn_id":"t1"}}' \
    '{"timestamp":"2026-10-18T10:00:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":100,"input_tokens":100}}}}' \
    '{"timestamp":"2026-10-18T10:00:03.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"projection"}}' \
    > "$rollout"
  touch -t 2610181200 "$rollout"
  lab_env "$lab"
  PATH="$fakebin:$PATH" FM_RM_TEST_JQ="$real_jq" \
    FM_RM_OPENCODE_DB="$lab/home/no-opencode.db" FM_RM_CODEX_SESSIONS="$codex_dir" \
    "$TOOL" mine --now 1792400300 >/dev/null || status=$?
  expect_code 0 "$status" "mine reports Codex projection failures without aborting"
  out=$(cat "$lab/home/data/repo-maintenance/metrics/2026-10-19.json")
  assert_equals "unreadable" "$(printf '%s' "$out" | jq -r '.coverage[] | select(.source=="codex") | .status')" "projection failures are not reported as empty"
  assert_equals "0" "$(printf '%s' "$out" | jq -r '.coverage[] | select(.source=="codex") | .sessions_mined')" "failed projections cannot become mined"
  assert_equals "1" "$(printf '%s' "$out" | jq -r '.coverage[] | select(.source=="codex") | .skipped_error')" "the projection failure is counted"
  pass "mine marks zero-mined Codex projection failures unreadable"
}

test_mine_marks_malformed_candidates_unreadable() {
  local lab bad_db bad_codex out status=0
  lab=$(make_lab mine-malformed-candidates)
  bad_db="$lab/home/malformed.db"
  sqlite3 "$bad_db" <<'SQL'
CREATE TABLE session_v2 (id TEXT PRIMARY KEY, project_id TEXT, slug TEXT, directory TEXT, idle_outcome TEXT, time_idle INTEGER);
CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, seq INTEGER, time_created INTEGER, data TEXT);
INSERT INTO session_v2 VALUES ('', 'p', 'bad', 'relative-cwd', 'succeeded', 1792400200000);
SQL
  bad_codex="$lab/home/malformed-codex"
  rm -rf "$bad_codex"
  mkdir -p "$bad_codex"
  printf '%s\n' \
    "{\"type\":\"session_meta\",\"payload\":{\"session_id\":\"bad-codex\",\"cwd\":\"$lab/pool/proj-abc123/1/proj\",\"timestamp\":\"not-a-timestamp\"}}" \
    '{"type":"event_msg","payload":{"type":"task_complete"}}' \
    > "$bad_codex/rollout-malformed.jsonl"
  touch -t 2610181200 "$bad_codex/rollout-malformed.jsonl"
  lab_env "$lab"
  FM_RM_OPENCODE_DB="$bad_db" FM_RM_CODEX_SESSIONS="$bad_codex" \
    "$TOOL" mine --now 1792400300 >/dev/null || status=$?
  expect_code 0 "$status" "mine reports malformed candidates without aborting"
  out=$(cat "$lab/home/data/repo-maintenance/metrics/2026-10-19.json")
  assert_equals "unreadable" "$(printf '%s' "$out" | jq -r '.coverage[] | select(.source=="opencode") | .status')" "malformed opencode metadata is unreadable"
  assert_equals "1" "$(printf '%s' "$out" | jq -r '.coverage[] | select(.source=="opencode") | .skipped_error')" "malformed opencode metadata is counted as an error"
  assert_equals "unreadable" "$(printf '%s' "$out" | jq -r '.coverage[] | select(.source=="codex") | .status')" "malformed codex metadata is unreadable"
  assert_equals "1" "$(printf '%s' "$out" | jq -r '.coverage[] | select(.source=="codex") | .skipped_error')" "malformed codex metadata is counted as an error"
  pass "mine marks malformed candidate records unreadable"
}

test_completed_cohort_uses_completion_time_for_all_rollouts() {
  local lab codex_dir completed_old completed_new unfinished stale multiple out status=0
  lab=$(make_lab codex-completion-cohort)
  codex_dir="$lab/home/codex-completion"
  mkdir -p "$codex_dir"
  completed_old="$codex_dir/rollout-completed-old-mtime.jsonl"
  completed_new="$codex_dir/rollout-completed-new-mtime.jsonl"
  unfinished="$codex_dir/rollout-in-progress.jsonl"
  stale="$codex_dir/rollout-stale-completion.jsonl"
  multiple="$codex_dir/rollout-multiple-completions.jsonl"
  printf '%s\n' \
    "{\"timestamp\":\"2020-01-01T00:00:00.000Z\",\"type\":\"session_meta\",\"payload\":{\"session_id\":\"cdx_completed_old\",\"cwd\":\"$lab/pool/proj-abc123/1/proj\",\"timestamp\":\"not-a-timestamp\"}}" \
    '{"timestamp":"2026-10-18T10:00:00.500Z","type":"event_msg","payload":{"type":"task_started","turn_id":"old-a"}}' \
    '{"timestamp":"2026-10-18T10:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":900},"last_token_usage":{"input_tokens":100}}}}' \
    '{"timestamp":"2026-10-18T10:00:01.500Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":900},"last_token_usage":{"input_tokens":200}}}}' \
    '{"timestamp":"2026-10-18T10:00:02.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"old-a"}}' \
    '{"timestamp":"2026-10-18T10:00:03.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"old-b"}}' \
    '{"timestamp":"2026-10-18T10:00:04.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":800,"input_tokens":800}}}}' \
    > "$completed_old"
  printf '%s\n' \
    "{\"timestamp\":\"2026-10-18T11:00:00.000Z\",\"type\":\"session_meta\",\"payload\":{\"session_id\":\"cdx_completed_new\",\"cwd\":\"$lab/pool/proj-abc123/1/proj\",\"timestamp\":\"2026-10-18T11:00:00.000Z\"}}" \
    '{"timestamp":"2026-10-18T11:00:00.500Z","type":"event_msg","payload":{"type":"task_started","turn_id":"new-a"}}' \
    '{"timestamp":"2026-10-18T11:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":100,"input_tokens":100}}}}' \
    '{"timestamp":"2026-10-18T11:00:02.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"new-a"}}' \
    '{"timestamp":"2026-10-18T11:00:03.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"new-b"}}' \
    '{"timestamp":"2026-10-18T11:00:04.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":200,"input_tokens":200}}}}' \
    '{"timestamp":"2020-01-01T00:00:02.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"new-b"}}' \
    > "$completed_new"
  printf '%s\n' \
    "{\"timestamp\":\"2026-10-18T12:00:00.000Z\",\"type\":\"session_meta\",\"payload\":{\"session_id\":\"cdx_in_progress\",\"cwd\":\"$lab/pool/proj-abc123/1/proj\",\"timestamp\":\"2026-10-18T12:00:00.000Z\"}}" \
    '{"timestamp":"2026-10-18T12:00:00.500Z","type":"event_msg","payload":{"type":"task_started","turn_id":"unfinished"}}' \
    '{"timestamp":"2026-10-18T12:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":800,"input_tokens":800}}}}' \
    > "$unfinished"
  printf '%s\n' \
    "{\"timestamp\":\"2026-10-18T13:00:00.000Z\",\"type\":\"session_meta\",\"payload\":{\"session_id\":\"cdx_stale_completion\",\"cwd\":\"$lab/pool/proj-abc123/1/proj\",\"timestamp\":\"2026-10-18T13:00:00.000Z\"}}" \
    '{"timestamp":"2026-10-18T13:00:00.500Z","type":"event_msg","payload":{"type":"task_started","turn_id":"stale"}}' \
    '{"timestamp":"2026-10-18T13:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":700,"input_tokens":700}}}}' \
    '{"timestamp":"2020-01-01T00:00:02.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"stale"}}' \
    > "$stale"
  printf '%s\n' \
    "{\"timestamp\":\"2026-10-18T14:00:00.000Z\",\"type\":\"session_meta\",\"payload\":{\"session_id\":\"cdx_multiple\",\"cwd\":\"$lab/pool/proj-abc123/1/proj\",\"timestamp\":\"2026-10-18T14:00:00.000Z\"}}" \
    '{"timestamp":"2026-10-18T14:00:00.500Z","type":"event_msg","payload":{"type":"task_started","turn_id":"multi-a"}}' \
    '{"timestamp":"2026-10-18T14:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":111,"input_tokens":111}}}}' \
    '{"timestamp":"2026-10-18T14:00:02.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"multi-a"}}' \
    '{"timestamp":"2026-10-18T14:00:03.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"multi-b"}}' \
    '{"timestamp":"2026-10-18T14:00:04.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":333,"input_tokens":333}}}}' \
    '{"timestamp":"2026-10-18T14:00:05.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"multi-b"}}' \
    > "$multiple"
  touch -t 2601010000 "$completed_old"
  touch -t 2610181300 "$completed_new" "$unfinished" "$stale" "$multiple"
  lab_env "$lab"
  FM_RM_OPENCODE_DB="$lab/home/no-opencode.db" FM_RM_CODEX_SESSIONS="$codex_dir" \
    "$TOOL" mine --now 1792400300 >"$lab/mine.out" || status=$?
  expect_code 0 "$status" "codex completion cohort mining succeeds"
  out=$(cat "$lab/home/data/repo-maintenance/metrics/2026-10-19.json")
  assert_equals "3" "$(printf '%s' "$out" | jq -r '.coverage[] | select(.source=="codex") | .sessions_seen')" "only rollouts with completed task spans in the window are seen"
  assert_equals "3" "$(printf '%s' "$out" | jq -r '.coverage[] | select(.source=="codex") | .sessions_mined')" "each eligible rollout is mined once"
  assert_equals "100,111,222,900" "$(printf '%s' "$out" | jq -r '[.tasks[] | select(.source=="codex") | .tokens_total] | sort | join(",")')" "completion time admits matching task spans"
  assert_equals "100:100,111:111,222:222,900:300" "$(printf '%s' "$out" | jq -r '[.tasks[] | select(.source=="codex") | "\(.tokens_total):\(.tokens_exploration)"] | sort | join(",")')" "cumulative token snapshots become per-task deltas and fallback inputs accumulate"
  assert_equals "4" "$(printf '%s' "$out" | jq -r '[.tasks[] | select(.source=="codex")] | length')" "multiple completed tasks produce separate rows"
  assert_not_contains "$out" '"tokens_total":800' "unfinished task spans are omitted"
  assert_not_contains "$out" '"tokens_total":200' "out-of-window task spans are omitted"
  assert_not_contains "$out" "cdx_in_progress" "unfinished rollout identifiers are not persisted"
  pass "codex eligibility uses task completion time and mines all completed rollouts"
}

test_mine_marks_codex_find_failures_unreadable() {
  local lab out status=0 fakebin
  lab=$(make_lab mine-find-failure)
  fakebin="$lab/fake-bin"
  mkdir -p "$fakebin"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/find"
  chmod +x "$fakebin/find"
  lab_env "$lab"
  PATH="$fakebin:$PATH" FM_RM_OPENCODE_DB="$lab/home/no-opencode.db" \
    "$TOOL" mine --now 1792400300 >/dev/null || status=$?
  expect_code 0 "$status" "mine reports a find failure without aborting"
  out=$(cat "$lab/home/data/repo-maintenance/metrics/2026-10-19.json")
  assert_equals "unreadable" "$(printf '%s' "$out" | jq -r '.coverage[] | select(.source=="codex") | .status')" "find failure is unreadable"
  assert_equals "0" "$(printf '%s' "$out" | jq -r '.coverage[] | select(.source=="codex") | .sessions_mined')" "find failures cannot become mined"
  assert_equals "1" "$(printf '%s' "$out" | jq -r '.coverage[] | select(.source=="codex") | .skipped_error')" "find failure is counted as an error"
  pass "mine marks codex find failures unreadable"
}

test_artifact_writers_fail_before_success_messages() {
  local lab metrics_dir mine_out mine_status=0 report_dir sweep_out sweep_status=0
  lab=$(make_lab artifact-writers)
  metrics_dir="$lab/home/data/repo-maintenance/metrics"
  printf 'blocked\n' > "$metrics_dir"
  lab_env "$lab"
  mine_out="$lab/mine.out"
  FM_HOME="$lab/home" FM_RM_OPENCODE_DB="$lab/home/.local/share/opencode/opencode.db" \
    FM_RM_CODEX_SESSIONS="$lab/home/.codex/sessions" "$TOOL" mine --now 1792400300 \
    >"$mine_out" 2>"$lab/mine.err" || mine_status=$?
  expect_code 1 "$mine_status" "mine fails when its metrics directory is a file"
  assert_not_contains "$(cat "$mine_out")" "mine: wrote" "mine does not announce an unpublished metrics artifact"

  lab=$(make_lab artifact-sweep)
  lab_env "$lab"
  "$TOOL" mine --now 1792400300 >/dev/null || fail "mine failed before sweep writer test"
  report_dir="$lab/home/data/repo-maintenance/proj/2026-10-18"
  printf 'blocked\n' > "$report_dir"
  sweep_out="$lab/sweep.out"
  FM_HOME="$lab/home" "$TOOL" sweep proj --date 2026-10-18 \
    >"$sweep_out" 2>"$lab/sweep.err" || sweep_status=$?
  expect_code 1 "$sweep_status" "sweep fails when its report directory is a file"
  assert_not_contains "$(cat "$sweep_out")" "report:" "sweep does not announce an unpublished report"
  pass "artifact writers publish success only after final paths are available"
}

test_sweep_writes_report_and_refuses_overwrite() {
  local lab report original status=0
  lab=$(make_lab sweep-basic)
  lab_env "$lab"
  # The fixed metrics path is what sweep reads.
  "$TOOL" mine --now 1792400300 >/dev/null || fail "mine failed"
  report="$lab/home/data/repo-maintenance/proj/2026-10-18/report.md"

  FM_HOME="$lab/home" "$TOOL" sweep proj --date 2026-10-18 >/dev/null || fail "sweep exited nonzero"
  assert_present "$report" "the sweep writes the dated report"
  assert_contains "$(cat "$report")" "## Token heat ranking (instrument)" "the report carries the instrument ranking"
  assert_contains "$(cat "$report")" 'src/one.py` (THI 3096' "the report names the fix-next file"
  assert_contains "$(cat "$report")" "## Structure audit (instrument)" "the report carries the structure audit"
  assert_not_contains "$(cat "$report")" "skipped_cap" "the sweep coverage has no cap reporting"
  assert_contains "$(cat "$report")" "pending qualitative audit" "the qualitative sections are visibly pending"
  assert_contains "$(cat "$report")" "This build delivered the initial Phase 1 slices" "the report records Phase 1 delivery"
  assert_contains "$(cat "$report")" "three pending receipts: a green test suite, zero broken imports" "the report keeps the Phase 1 receipts pending"
  assert_not_contains "$(cat "$report")" "$lab" "the report contains no fixture absolute path"
  assert_not_contains "$(cat "$report")" "$HOME" "the report contains no host home path"
  original=$(cat "$report")

  FM_HOME="$lab/home" "$TOOL" sweep proj --date 2026-10-18 >/dev/null 2>"$lab/err.txt" || status=$?
  expect_code 2 "$status" "a second sweep of the same date refuses"
  assert_contains "$(cat "$lab/err.txt")" "already exists" "the refusal names the existing report"
  assert_equals "$original" "$(cat "$report")" "the refusal preserves the completed report"

  pass "sweep writes the dated report and refuses overwrite"
}

test_sweep_concurrent_publish_refuses_second_writer() {
  local lab report fakebin barrier real_ln first_status=0 second_status=0 wait_count=0
  local first_pid second_pid
  lab=$(make_lab sweep-concurrent-publish)
  lab_env "$lab"
  "$TOOL" mine --now 1792400300 >/dev/null || fail "mine failed before concurrent sweep"
  report="$lab/home/data/repo-maintenance/proj/2026-10-18/report.md"
  real_ln=$(command -v ln) || fail "ln is required for concurrent publish test"
  fakebin="$lab/fake-bin"
  barrier="$lab/link-barrier"
  mkdir -p "$fakebin" "$barrier"
  cat > "$fakebin/ln" <<'SH'
#!/usr/bin/env bash
set -u
if mkdir "$FM_RM_TEST_LINK_BARRIER/first" 2>/dev/null; then
  : > "$FM_RM_TEST_LINK_BARRIER/arrived-one"
else
  : > "$FM_RM_TEST_LINK_BARRIER/arrived-two"
fi
while [ ! -e "$FM_RM_TEST_LINK_BARRIER/release" ]; do sleep 0.01; done
exec "$FM_RM_TEST_REAL_LN" "$@"
SH
  chmod +x "$fakebin/ln"

  PATH="$fakebin:$PATH" FM_RM_TEST_LINK_BARRIER="$barrier" FM_RM_TEST_REAL_LN="$real_ln" \
    FM_HOME="$lab/home" "$TOOL" sweep proj --date 2026-10-18 >"$lab/first.out" 2>&1 &
  first_pid=$!
  PATH="$fakebin:$PATH" FM_RM_TEST_LINK_BARRIER="$barrier" FM_RM_TEST_REAL_LN="$real_ln" \
    FM_HOME="$lab/home" "$TOOL" sweep proj --date 2026-10-18 >"$lab/second.out" 2>&1 &
  second_pid=$!

  while [ ! -e "$barrier/arrived-one" ] || [ ! -e "$barrier/arrived-two" ]; do
    wait_count=$((wait_count + 1))
    if [ "$wait_count" -ge 500 ]; then
      : > "$barrier/release"
      wait "$first_pid" || true
      wait "$second_pid" || true
      fail "both sweeps did not reach atomic publication"
    fi
    sleep 0.01
  done
  : > "$barrier/release"

  wait "$first_pid" || first_status=$?
  wait "$second_pid" || second_status=$?
  if ! { [ "$first_status" -eq 0 ] && [ "$second_status" -eq 2 ]; } \
    && ! { [ "$first_status" -eq 2 ] && [ "$second_status" -eq 0 ]; }; then
    fail "concurrent sweeps must publish once and refuse once (statuses $first_status, $second_status)"
  fi
  assert_present "$report" "one complete report wins the concurrent publish"
  assert_contains "$(cat "$report")" "## Structure audit (instrument)" "the concurrent report is complete"
  assert_not_contains "$(cat "$report")" "$lab" "the concurrent report contains no fixture absolute path"
  pass "concurrent sweeps publish once without replacing the report"
}

test_structure_reports_ceiling_depth_and_summary_gaps
test_structure_and_sweep_list_all_findings
test_structure_is_read_only_and_refuses_non_git
test_structure_requires_routing_table_and_ignores_malformed_exemptions
test_mine_extracts_read_metrics_from_opencode
test_mine_keeps_distinct_home_and_code_roots_aligned
test_mine_resolves_file_paths_when_realpath_fails
test_mine_cleanup_preserves_paths_with_spaces
test_mine_never_records_raw_paths_or_content
test_mine_codex_session_metrics
test_mine_reports_absent_sources
test_mine_skips_external_stores
test_mine_uses_fixed_home_data_root
test_mine_reports_empty_sources
test_rank_orders_by_token_heat
test_rank_without_metrics_refuses
test_rank_zeroes_thi_for_distinct_single_reads_and_rejects_traversal
test_mine_marks_session_enumeration_failures_unreadable
test_mine_marks_opencode_processing_failures_unreadable
test_mine_marks_codex_projection_failures_unreadable
test_mine_marks_malformed_candidates_unreadable
test_completed_cohort_uses_completion_time_for_all_rollouts
test_mine_marks_codex_find_failures_unreadable
test_artifact_writers_fail_before_success_messages
test_sweep_writes_report_and_refuses_overwrite
test_sweep_concurrent_publish_refuses_second_writer

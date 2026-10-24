#!/usr/bin/env bash
# Behavior tests for the prevention ledger and its brief plan lint.
#
# Covers bin/fm-prevention-ledger.py (idempotent append, schema validation,
# reviewed classification, per-task export), bin/fm-brief-preflight.py (the
# three labelled plan-lint checks), and the three scaffold lines that make the
# lint answerable. Everything runs against a synthetic no-mistakes state
# database, so the suite never reads this host's pipeline history.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-prevention-ledger)
EXPORTER="$ROOT/bin/fm-prevention-ledger.py"
PREFLIGHT="$ROOT/bin/fm-brief-preflight.py"

# Build a firstmate home and a no-mistakes data directory with three runs:
# one completed run carrying two classified findings, one failed run whose
# termination was an environment failure, and one still-running run.
write_fixture() {
  local base=$1
  local home="$base/home" nm="$base/nm"
  mkdir -p "$home/state" "$home/data/task-alpha" "$nm/repos"

  cat > "$home/state/task-alpha.meta" <<'EOF'
project=alpha
kind=ship
mode=no-mistakes
EOF
  cat > "$home/state/task-alpha.status" <<'EOF'
working [at=1790000000]: scaffolding
needs-decision [at=1790000010] [key=nm-run-alpha-0001-review]: ask-user findings=review-2 file=/tmp/x
resolved [at=1790000020]: answered
done [at=1790000030]: ready
EOF
  cat > "$home/data/task-alpha/brief.md" <<'EOF'
# Task
## Captain's intent
Fixture intent.

## Firstmate spec
Fixture spec.

Contract coverage: `bin/fm-brief.sh`
Edge cases: none
Stale facts: none
EOF
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] task-alpha - Fixture task (repo: alpha) (kind: ship)
- [ ] task-beta - Second fixture task (repo: beta) (kind: ship)
EOF

  python3 - "$nm/state.sqlite" <<'PY'
import json
import sqlite3
import sys

conn = sqlite3.connect(sys.argv[1])
conn.executescript(
    """
    CREATE TABLE repos (
        id TEXT PRIMARY KEY,
        working_path TEXT NOT NULL,
        default_branch TEXT NOT NULL DEFAULT 'main',
        created_at INTEGER NOT NULL
    );
    CREATE TABLE runs (
        id TEXT PRIMARY KEY,
        repo_id TEXT NOT NULL,
        branch TEXT NOT NULL,
        head_sha TEXT NOT NULL,
        base_sha TEXT NOT NULL,
        submitted_head_sha TEXT,
        last_pushed_sha TEXT,
        review_approved_head_sha TEXT,
        status TEXT NOT NULL,
        pr_url TEXT,
        pr_state TEXT,
        ci_ready_no_ci INTEGER NOT NULL DEFAULT 0,
        error TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
    );
    CREATE TABLE step_results (
        id TEXT PRIMARY KEY,
        run_id TEXT NOT NULL,
        step_name TEXT NOT NULL,
        status TEXT NOT NULL,
        findings_json TEXT
    );
    CREATE TABLE step_rounds (
        id TEXT PRIMARY KEY,
        step_result_id TEXT NOT NULL,
        round INTEGER NOT NULL,
        trigger_type TEXT NOT NULL,
        findings_json TEXT,
        user_findings_json TEXT,
        selected_finding_ids TEXT,
        selection_source TEXT,
        response_origin TEXT NOT NULL DEFAULT 'unknown',
        created_at INTEGER NOT NULL
    );
    """
)
conn.execute("INSERT INTO repos VALUES ('repo-alpha', '/fixture/alpha', 'main', 1790000000)")

FINDINGS = {
    "review-1": {
        "id": "review-1",
        "severity": "error",
        "file": "src/alpha/guard.py",
        "action": "auto-fix",
        "description": "fixture defect",
    },
    "review-2": {
        "id": "review-2",
        "severity": "warning",
        "file": "src/alpha/guard.py",
        "action": "ask-user",
        "description": "fixture decision",
    },
    "review-3": {
        "id": "review-3",
        "severity": "warning",
        "file": "docs/guide.md",
        "action": "ask-user",
        "description": "fixture escalated decision",
    },
}

conn.execute(
    "INSERT INTO runs VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
    (
        "run-delta-0001",
        "repo-alpha",
        "fm/task-delta",
        "f" * 40,
        "a" * 40,
        "f" * 40,
        None,
        None,
        "completed",
        None,
        None,
        0,
        None,
        1790006000,
        1790006600,
    ),
)
conn.execute(
    "INSERT INTO step_results VALUES (?,?,?,?,?)",
    ("sr-delta-review", "run-delta-0001", "review", "completed", None),
)
conn.execute(
    "INSERT INTO runs VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
    (
        "run-alpha-0001",
        "repo-alpha",
        "fm/task-alpha",
        "a" * 40,
        "b" * 40,
        "a" * 40,
        "c" * 40,
        "c" * 40,
        "completed",
        "https://example.test/alpha/alpha/pull/1",
        "merged",
        0,
        None,
        1790000000,
        1790003600,
    ),
)
conn.execute(
    "INSERT INTO step_results VALUES (?,?,?,?,?)",
    ("sr-alpha-review", "run-alpha-0001", "review", "completed", json.dumps({"findings": list(FINDINGS.values())})),
)
conn.execute(
    "INSERT INTO step_results VALUES (?,?,?,?,?)",
    ("sr-alpha-ci", "run-alpha-0001", "ci", "completed", None),
)
conn.executemany(
    "INSERT INTO step_rounds VALUES (?,?,?,?,?,?,?,?,?,?)",
    [
        (
            "rd-alpha-1",
            "sr-alpha-review",
            1,
            "initial",
            json.dumps({"findings": list(FINDINGS.values())}),
            None,
            None,
            "",
            "unknown",
            1790000100,
        ),
        (
            "rd-alpha-2",
            "sr-alpha-review",
            2,
            "auto_fix",
            json.dumps({"findings": [FINDINGS["review-2"]]}),
            json.dumps({"findings": [FINDINGS["review-2"]]}),
            json.dumps(["review-2"]),
            "user",
            "interactive",
            1790000200,
        ),
    ],
)
conn.execute(
    "INSERT INTO runs VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
    (
        "run-beta-0001",
        "repo-alpha",
        "fm/task-beta",
        "d" * 40,
        "0" * 40,
        None,
        None,
        None,
        "failed",
        None,
        None,
        0,
        'step review failed: agent review: codex exited: exit status 1: You have hit your usage limit. Upgrade to Pro',
        1790004000,
        1790004100,
    ),
)
conn.execute(
    "INSERT INTO runs VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
    (
        "run-gamma-0001",
        "repo-alpha",
        "fm/task-gamma",
        "e" * 40,
        "0" * 40,
        None,
        None,
        None,
        "running",
        None,
        None,
        0,
        None,
        1790005000,
        1790005000,
    ),
)
conn.commit()
conn.close()
PY

  printf 'project\tbranch\tfinding_id\tcategory\n' > "$base/classifications.tsv"
  printf 'alpha\tfm/task-alpha\treview-1\tunsafe edge/rollback\n' >> "$base/classifications.tsv"
  printf 'alpha\tfm/task-alpha\treview-2\tmissing contract\n' >> "$base/classifications.tsv"
  printf 'alpha\tfm/task-alpha\treview-3\tstale assumption\n' >> "$base/classifications.tsv"
}

fixture_ledger() {
  printf '%s/%s/data/prevention-ledger/runs.jsonl' "$TMP_ROOT" "$1"
}

run_exporter() {
  "$EXPORTER" "$@" --root "$TMP_ROOT/fixture/home" --nm-data "$TMP_ROOT/fixture/nm"
}

test_backfill_is_idempotent_and_skips_nonterminal_runs() {
  local ledger before after rows
  ledger=$(fixture_ledger fixture)
  mkdir -p "$(dirname "$ledger")"
  cp "$TMP_ROOT/classifications.tsv" "$(dirname "$ledger")/classifications.tsv"

  run_exporter backfill --ledger "$ledger" --until 1790100000 --quiet 2>"$TMP_ROOT/backfill.err"
  expect_code 0 "$?" "backfill must succeed on the fixture state database"
  rows=$(wc -l < "$ledger" | tr -d ' ')
  [ "$rows" = "3" ] || fail "backfill must write exactly the three terminal runs, wrote $rows"
  grep -q 'run-gamma-0001' "$ledger" && fail "backfill must skip a run that has not reached a terminal state"
  grep -q 'run-alpha-0001' "$ledger" || fail "backfill dropped the completed run"

  before=$(shasum "$ledger" | awk '{print $1}')
  run_exporter backfill --ledger "$ledger" --until 1790100000 --quiet
  expect_code 0 "$?" "replaying backfill must succeed"
  after=$(shasum "$ledger" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "replaying backfill rewrote the ledger; appends must be idempotent"
  pass "fm-prevention-ledger.py backfill: two terminal rows, idempotent replay"
}

test_row_shape_matches_the_schema() {
  local ledger
  ledger=$(fixture_ledger fixture)
  python3 - "$ledger" <<'PY' || fail "row shape drifted from the schema"
import json
import sys

fields = [
    "project", "task", "brief_path", "plan_ref", "run_id", "start_head", "end_head",
    "findings", "ask_user_answers", "fix_commits", "pr_url", "ci_result", "rounds",
    "wall_time_s", "observed_at", "source", "gaps",
]
rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert len(rows) == 3, rows
for row in rows:
    assert list(row) == fields, list(row)
alpha = next(row for row in rows if row["run_id"] == "run-alpha-0001")
assert alpha["project"] == "alpha", alpha["project"]
assert alpha["task"] == "task-alpha", alpha["task"]
assert alpha["findings"][0]["category"] in (
    "missing contract", "unsafe edge/rollback"
), alpha["findings"]
assert alpha["ci_result"] == "green", alpha["ci_result"]
assert alpha["rounds"] == 2, alpha["rounds"]
assert alpha["wall_time_s"] == 3600, alpha["wall_time_s"]
assert alpha["observed_at"] == 1790003600, alpha["observed_at"]
answers = {a["finding_id"]: a["decision"] for a in alpha["ask_user_answers"]}
assert answers.get("review-2") == "selected", answers
assert answers.get("review-3") == "escalated-to-captain", answers
beta = next(row for row in rows if row["run_id"] == "run-beta-0001")
assert beta["ci_result"] == "not-run", beta["ci_result"]
assert "run:environment-failure" in beta["gaps"], beta["gaps"]
assert "start_head:unrecorded" in beta["gaps"], beta["gaps"]
delta = next(row for row in rows if row["run_id"] == "run-delta-0001")
assert delta["ci_result"] == "unknown", delta["ci_result"]
assert "ci_result:unrecorded" in delta["gaps"], delta["gaps"]
PY
  [ "$?" = "0" ] || fail "row shape or recovered values drifted from the schema"
  pass "fm-prevention-ledger.py backfill: row fields, decisions, and gaps"
}

test_unclassified_findings_become_gaps_not_guesses() {
  local ledger base
  base="$TMP_ROOT/unclassified"
  mkdir -p "$base"
  write_fixture "$base"
  ledger="$base/ledger/runs.jsonl"
  mkdir -p "$base/ledger"
  printf 'project\tbranch\tfinding_id\tcategory\n' > "$base/ledger/classifications.tsv"
  "$EXPORTER" backfill --root "$base/home" --nm-data "$base/nm" --ledger "$ledger" \
    --until 1790100000 --quiet
  expect_code 0 "$?" "backfill must succeed without a reviewed classification table"
  python3 - "$ledger" <<'PY' || fail "an unreviewed finding must carry a null category plus a gap token"
import json
import sys

rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
alpha = next(row for row in rows if row["run_id"] == "run-alpha-0001")
assert all(finding["category"] is None for finding in alpha["findings"]), alpha["findings"]
assert any(gap.startswith("classification:unclassified:") for gap in alpha["gaps"]), alpha["gaps"]
PY
  [ "$?" = "0" ] || fail "an unreviewed finding must carry a null category plus a gap token"
  "$EXPORTER" validate --ledger "$ledger" >/dev/null 2>&1
  expect_code 0 "$?" "validate must accept a null category when its gap token is present"
  pass "fm-prevention-ledger.py: unreviewed findings are recorded as gaps"
}

test_validate_rejects_schema_drift() {
  local base ledger
  base="$TMP_ROOT/invalid"
  mkdir -p "$base"
  write_fixture "$base"
  ledger="$base/runs.jsonl"
  cp "$TMP_ROOT/fixture/data/prevention-ledger/runs.jsonl" "$ledger"
  python3 - "$ledger" <<'PY'
import json
import sys

path = sys.argv[1]
rows = [json.loads(line) for line in open(path, encoding="utf-8")]
rows[0]["findings"][0]["category"] = "made up"
rows[1]["ci_result"] = "maybe"
with open(path, "w", encoding="utf-8") as handle:
    for row in rows:
        handle.write(json.dumps(row, separators=(",", ":")) + "\n")
PY
  "$EXPORTER" validate --ledger "$ledger" >"$base/out" 2>&1
  expect_code 1 "$?" "validate must fail on an out-of-taxonomy category and an invalid ci_result"
  grep -q "outside the taxonomy" "$base/out" || fail "validate did not name the taxonomy violation"
  grep -q "ci_result" "$base/out" || fail "validate did not name the ci_result violation"
  pass "fm-prevention-ledger.py validate: refuses schema and taxonomy drift"
}

test_validate_requires_a_gap_for_every_null_category() {
  local base ledger
  base="$TMP_ROOT/nullgap"
  mkdir -p "$base"
  ledger="$base/runs.jsonl"
  cp "$TMP_ROOT/fixture/data/prevention-ledger/runs.jsonl" "$ledger"
  python3 - "$ledger" <<'PY'
import json
import sys

path = sys.argv[1]
rows = [json.loads(line) for line in open(path, encoding="utf-8")]
rows[0]["findings"][0]["category"] = None
with open(path, "w", encoding="utf-8") as handle:
    for row in rows:
        handle.write(json.dumps(row, separators=(",", ":")) + "\n")
PY
  "$EXPORTER" validate --ledger "$ledger" >"$base/out" 2>&1
  expect_code 1 "$?" "validate must refuse a null category with no gap token"
  grep -q "without a gap token" "$base/out" || fail "validate did not explain the missing gap token"
  pass "fm-prevention-ledger.py validate: null category requires its gap token"
}

test_export_writes_one_task_and_leaves_the_rest_alone() {
  local ledger
  ledger="$TMP_ROOT/export/runs.jsonl"
  mkdir -p "$(dirname "$ledger")"
  printf 'project\tbranch\tfinding_id\tcategory\n' > "$(dirname "$ledger")/classifications.tsv"
  run_exporter export task-alpha --ledger "$ledger" --until 1790100000 --quiet
  expect_code 0 "$?" "export task-alpha must succeed"
  [ "$(wc -l < "$ledger" | tr -d ' ')" = "1" ] || fail "export task-alpha must write exactly one row"
  grep -q run-alpha-0001 "$ledger" || fail "export task-alpha dropped its own run"
  grep -q run-beta-0001 "$ledger" && fail "export task-alpha wrote another task's run"
  run_exporter export task-alpha --ledger "$ledger" --until 1790100000 --quiet
  [ "$(wc -l < "$ledger" | tr -d ' ')" = "1" ] || fail "repeating export must not append a duplicate row"
  pass "fm-prevention-ledger.py export: one task, idempotent"
}

test_gh_enrichment_uses_a_stubbed_forge() {
  local base ledger fake
  base="$TMP_ROOT/gh"
  mkdir -p "$base/ledger" "$base/bin"
  ledger="$base/ledger/runs.jsonl"
  cp "$TMP_ROOT/fixture/classifications.tsv" "$base/ledger/classifications.tsv"
  fake="$base/bin/gh-axi"
  cat > "$fake" <<'EOF'
#!/usr/bin/env bash
# Fixture forge: one merged pull request with four passing checks.
cat <<'OUT'
pull_request:
  number: 1
  state: merged
  checks: "4 passed, 0 failed, 4 total"
OUT
EOF
  chmod +x "$fake"
  PATH="$base/bin:$PATH" "$EXPORTER" backfill --root "$TMP_ROOT/fixture/home" \
    --nm-data "$TMP_ROOT/fixture/nm" --ledger "$ledger" --until 1790100000 --gh --quiet
  expect_code 0 "$?" "backfill --gh must succeed against a readable forge"
  python3 - "$ledger" <<'PY' || fail "--gh did not record forge evidence only for runs with a pull request"
import json
import sys

rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
alpha = next(row for row in rows if row["run_id"] == "run-alpha-0001")
assert "gh-axi" in alpha["source"], alpha["source"]
assert alpha["ci_result"] == "green", alpha["ci_result"]
beta = next(row for row in rows if row["run_id"] == "run-beta-0001")
assert "gh-axi" not in beta["source"], beta["source"]
PY
  [ "$?" = "0" ] || fail "--gh did not record forge evidence only for runs with a pull request"
  pass "fm-prevention-ledger.py backfill --gh: forge check state, stubbed offline"
}

test_stats_reports_the_category_mix() {
  local out
  out=$("$EXPORTER" stats --ledger "$TMP_ROOT/fixture/data/prevention-ledger/runs.jsonl" --format json)
  expect_code 0 "$?" "stats must succeed on the fixture ledger"
  printf '%s' "$out" | python3 -c '
import json, sys
payload = json.load(sys.stdin)
assert payload["rows"] == 3, payload
assert payload["completed_rows"] == 1, payload
assert payload["first_pass_rows"] == 0, payload
assert payload["ci_results"]["unknown"] == 1, payload
assert payload["findings"] == 3, payload
assert payload["categories"]["missing contract"]["count"] == 1, payload
assert payload["categories"]["unsafe edge/rollback"]["count"] == 1, payload
' || fail "stats did not report the expected category mix"
  pass "fm-prevention-ledger.py stats: category mix for the weekly review"
}

test_preflight_accepts_a_complete_brief() {
  local brief
  brief="$TMP_ROOT/preflight-good.md"
  cat > "$brief" <<'EOF'
# Task
Parse `bin/fm-brief.sh` and update `docs/configuration.md`.
Contract coverage: `bin/fm-brief.sh`, `docs/configuration.md`
Edge cases: empty brief, brief with an unterminated heredoc
Stale facts: `docs/configuration.md`
EOF
  "$PREFLIGHT" --brief "$brief" --project "$ROOT" >"$TMP_ROOT/preflight-good.out" 2>&1
  expect_code 0 "$?" "preflight must accept a complete brief"
  grep -q "3/3 checks passed" "$TMP_ROOT/preflight-good.out" || fail "preflight did not report three passing checks"
  pass "fm-brief-preflight.py: complete brief passes all checks"
}

test_preflight_refuses_missing_and_placeholder_labels() {
  local brief out
  brief="$TMP_ROOT/preflight-missing.md"
  printf '# Task\nUpdate `bin/fm-brief.sh`.\n' > "$brief"
  "$PREFLIGHT" --brief "$brief" --project "$ROOT" >"$TMP_ROOT/preflight-missing.out" 2>&1
  expect_code 1 "$?" "preflight must refuse a brief with no labelled lines"
  grep -q "missing a line beginning" "$TMP_ROOT/preflight-missing.out" || fail "preflight did not name the missing label"

  brief="$TMP_ROOT/preflight-placeholder.md"
  cat > "$brief" <<'EOF'
# Task
Contract coverage: (fill before dispatch) name each consumer.
Edge cases: none
Stale facts: none
EOF
  "$PREFLIGHT" --brief "$brief" --project "$ROOT" >"$TMP_ROOT/preflight-placeholder.out" 2>&1
  expect_code 1 "$?" "preflight must refuse an unfilled scaffold line"
  grep -q "placeholder" "$TMP_ROOT/preflight-placeholder.out" || fail "preflight did not explain the placeholder"
  pass "fm-brief-preflight.py: missing and placeholder labels fail"
}

test_preflight_refuses_a_stale_cited_path() {
  local brief out
  brief="$TMP_ROOT/preflight-stale.md"
  cat > "$brief" <<'EOF'
# Task
Contract coverage: `bin/fm-removed-helper.sh`
Edge cases: none
Stale facts: none
EOF
  "$PREFLIGHT" --brief "$brief" --project "$ROOT" >"$TMP_ROOT/preflight-stale.out" 2>&1
  expect_code 1 "$?" "preflight must refuse a cited path that does not exist at the base revision"
  grep -q "parent directory exists" "$TMP_ROOT/preflight-stale.out" || fail "preflight did not report the stale reference"
  pass "fm-brief-preflight.py: a stale cited path blocks dispatch"
}

test_preflight_requires_edge_cases_only_for_risk_surfaces() {
  local brief out
  brief="$TMP_ROOT/preflight-risk.md"
  cat > "$brief" <<'EOF'
# Task
Harden the regex matcher in `bin/fm-brief.sh`.
Contract coverage: `bin/fm-brief.sh`
Stale facts: none
EOF
  "$PREFLIGHT" --brief "$brief" --project "$ROOT" >"$TMP_ROOT/preflight-risk.out" 2>&1
  expect_code 1 "$?" "preflight must require an edge-cases line when a risk surface is named"
  grep -q "needs an Edge cases" "$TMP_ROOT/preflight-risk.out" || fail "preflight did not name the edge-cases requirement"

  brief="$TMP_ROOT/preflight-norisk.md"
  cat > "$brief" <<'EOF'
# Task
Update `docs/configuration.md` wording.
Contract coverage: `docs/configuration.md`
Stale facts: `docs/configuration.md`
EOF
  "$PREFLIGHT" --brief "$brief" --project "$ROOT" >"$TMP_ROOT/preflight-norisk.out" 2>&1
  expect_code 0 "$?" "preflight must not require edge cases when no risk surface is named"
  pass "fm-brief-preflight.py: edge cases are required only for risk surfaces"
}

test_brief_scaffold_carries_the_three_plan_lint_lines() {
  local home id brief status
  home="$TMP_ROOT/scaffold-home"
  mkdir -p "$home/data"
  id=prevention-scaffold
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode no-mistakes >/dev/null 2>&1
  status=$?
  expect_code 0 "$status" "fm-brief.sh must scaffold a no-mistakes brief"
  brief="$home/data/$id/brief.md"
  assert_grep "Contract coverage:" "$brief" "brief scaffold missing the contract-coverage plan-lint line"
  assert_grep "Edge cases:" "$brief" "brief scaffold missing the edge-cases plan-lint line"
  assert_grep "Stale facts:" "$brief" "brief scaffold missing the stale-facts plan-lint line"

  "$PREFLIGHT" --brief "$brief" --project "$ROOT" >"$TMP_ROOT/scaffold-preflight.out" 2>&1
  expect_code 1 "$?" "the unfilled scaffold must not pass its own preflight"
  pass "fm-brief.sh: scaffold carries the three plan-lint lines"
}

test_an_existing_row_is_never_rewritten() {
  local base ledger before first_line
  base="$TMP_ROOT/append-only"
  mkdir -p "$base"
  write_fixture "$base"
  ledger="$base/runs.jsonl"
  "$EXPORTER" backfill --root "$base/home" --nm-data "$base/nm" --ledger "$ledger" \
    --classifications "$base/classifications.tsv" --until 1790100000 --quiet
  expect_code 0 "$?" "backfill must seed the append-only fixture"
  before=$(shasum "$ledger" | awk '{print $1}')
  first_line=$(sed -n '1p' "$ledger" | shasum | awk '{print $1}')

  # Change the source after the row is written: the export must not rewrite it.
  python3 - "$base/nm/state.sqlite" <<'PY'
import json
import sqlite3
import sys

conn = sqlite3.connect(sys.argv[1])
current = conn.execute(
    "SELECT findings_json FROM step_results WHERE id = 'sr-alpha-review'"
).fetchone()[0]
payload = json.loads(current)
payload["findings"][0]["severity"] = "info"
conn.execute(
    "UPDATE step_results SET findings_json = ? WHERE id = 'sr-alpha-review'",
    (json.dumps(payload),),
)
conn.commit()
conn.close()
PY

  "$EXPORTER" backfill --root "$base/home" --nm-data "$base/nm" --ledger "$ledger" \
    --classifications "$base/classifications.tsv" --until 1790100000 --quiet
  expect_code 0 "$?" "replaying backfill over a changed source must succeed"
  [ "$(shasum "$ledger" | awk '{print $1}')" = "$before" ] \
    || fail "backfill rewrote the ledger after the source changed; existing rows must be immutable"
  [ "$(sed -n '1p' "$ledger" | shasum | awk '{print $1}')" = "$first_line" ] \
    || fail "backfill rewrote the first row's bytes"
  pass "fm-prevention-ledger.py backfill: an existing row is never rewritten"
}

test_stats_refuses_a_missing_ledger() {
  "$EXPORTER" stats --ledger "$TMP_ROOT/does-not-exist.jsonl" --format json >"$TMP_ROOT/stats-missing.out" 2>&1
  expect_code 1 "$?" "stats must refuse a missing ledger instead of reporting zero rows"
  grep -q "ledger not found" "$TMP_ROOT/stats-missing.out" || fail "stats did not name the missing ledger"
  pass "fm-prevention-ledger.py stats: a missing ledger is an error, not an empty result"
}

test_preflight_refuses_an_unresolvable_base_ref() {
  local brief
  brief="$TMP_ROOT/preflight-badref.md"
  printf '# Task\nContract coverage: none\nEdge cases: none\nStale facts: none\n' > "$brief"
  "$PREFLIGHT" --brief "$brief" --project "$ROOT" --base-ref no-such-ref >"$TMP_ROOT/preflight-badref.out" 2>&1
  expect_code 2 "$?" "preflight must treat an unresolvable base ref as a usage error"
  grep -q "cannot resolve" "$TMP_ROOT/preflight-badref.out" || fail "preflight did not explain the bad ref"
  pass "fm-brief-preflight.py: an unresolvable base ref is a usage error"
}

test_preflight_records_adoption() {
  local brief record
  brief="$TMP_ROOT/preflight-record.md"
  record="$TMP_ROOT/preflight-record.jsonl"
  printf '# Task\nHarden the matcher in `bin/fm-brief.sh`.\nContract coverage: `bin/fm-brief.sh`\nStale facts: none\n' > "$brief"
  "$PREFLIGHT" --brief "$brief" --project "$ROOT" --record "$record" >/dev/null 2>&1
  expect_code 1 "$?" "the recorded run must still fail on the missing edge-cases line"
  [ -s "$record" ] || fail "--record wrote no adoption line"
  python3 - "$record" <<'PY' || fail "the adoption record did not describe the failed check"
import json
import sys

lines = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert len(lines) == 1, lines
record = lines[0]
assert record["ok"] is False, record
assert record["failed"] == ["edge-cases"], record
assert record["declared_none"] == ["stale-facts"], record
assert record["observed_at"] > 0, record
PY
  [ "$?" = "0" ] || fail "the adoption record did not describe the failed check"
  pass "fm-brief-preflight.py --record: adoption is recorded durably"
}

test_spec_placeholder_is_caught_with_extra_scaffold_lines() {
  local brief rc
  brief="$TMP_ROOT/scaffold-unfilled.md"
  cat > "$brief" <<'EOF'
# Task
## Captain's intent
A real captain ask.

## Firstmate spec
{FIRSTMATE_SPEC}

Contract coverage: (fill before dispatch) name each consumer.
Edge cases: none
Stale facts: none
EOF
  bash -c '. "$1/bin/fm-dod-lib.sh"; fm_brief_task_placeholders_present "$2"' _ "$ROOT" "$brief"
  rc=$?
  expect_code 0 "$rc" "the spawn placeholder guard must still see an unfilled spec below the scaffold lines"
  pass "fm-dod-lib.sh: scaffold lines cannot hide an unfilled spec placeholder"
}


mkdir -p "$TMP_ROOT"
write_fixture "$TMP_ROOT/fixture"
cp "$TMP_ROOT/fixture/classifications.tsv" "$TMP_ROOT/classifications.tsv"

test_backfill_is_idempotent_and_skips_nonterminal_runs
test_row_shape_matches_the_schema
test_unclassified_findings_become_gaps_not_guesses
test_validate_rejects_schema_drift
test_validate_requires_a_gap_for_every_null_category
test_export_writes_one_task_and_leaves_the_rest_alone
test_gh_enrichment_uses_a_stubbed_forge
test_stats_reports_the_category_mix
test_preflight_accepts_a_complete_brief
test_preflight_refuses_missing_and_placeholder_labels
test_preflight_refuses_a_stale_cited_path
test_preflight_requires_edge_cases_only_for_risk_surfaces
test_an_existing_row_is_never_rewritten
test_stats_refuses_a_missing_ledger
test_preflight_refuses_an_unresolvable_base_ref
test_preflight_records_adoption
test_spec_placeholder_is_caught_with_extra_scaffold_lines
test_brief_scaffold_carries_the_three_plan_lint_lines

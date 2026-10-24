#!/usr/bin/env python3
"""fm-prevention-ledger.py - export the append-only prevention ledger for no-mistakes runs.

The ledger is the single evidence store behind the preventive engineering loop:
one JSON object per terminal no-mistakes run, appended to
``<FM_HOME>/data/prevention-ledger/runs.jsonl``. It records what the pipeline
found, what it fixed, and what was decided, so authoring quality can be measured
without reading review prose twice.

Sources, all read-only:

  1. The no-mistakes state database (``$NO_MISTAKES_DATA/state.sqlite``), for
     runs, step results, step rounds, per-round findings, and ask-user gates.
  2. ``state/<task>.meta`` for the project, task kind, and delivery mode.
  3. ``state/<task>.status`` for ask-user escalations recorded only as status
     events.
  4. ``data/<task>/brief.md`` (or ``launch-brief.md``) for the brief path and
     the plan or slice reference.
  5. The no-mistakes proxy repositories (``<NO_MISTAKES_DATA>/repos/<id>.git``)
     for the fix commits between the submitted head and the pushed head.
  6. ``classifications.tsv``, the reviewed category mapping for every finding,
     keyed ``project, branch, finding_id``. It is resolved as ``--classifications``,
     then next to the ledger, then in this repository's tracked copy, because the
     mapping ships with the code while the ledger stays in the private home.
  7. Optionally ``gh-axi pr view`` with ``--gh`` for live PR check state.

Home resolution is ``--root``, then ``FM_HOME``, then ``$HOME/firstmate``, then
this script's repository root, taking the first that holds both ``state/`` and
``data/``. The ledger default is ``<home>/data/prevention-ledger/runs.jsonl``.

Idempotency: the ledger key is ``(project, run_id)``. A run already present is
skipped and never rewritten, so replaying ``backfill`` over an unchanged state
database leaves the ledger byte-identical. New rows are appended in
``(observed_at, project, run_id)`` order, which is stable for a fixed capture
window.

Determinism: no row field is taken from the current clock. ``observed_at`` is
the run's own terminal update time, and ``--until`` bounds the capture window,
so the same state database plus the same ``--until`` reproduces the same rows.
Findings never carry a description, only the reviewed category, so the ledger
holds no review prose.

Category taxonomy, one per finding, is owned by ``data/prevention-ledger/SCHEMA.md``.
A finding whose category is neither in the reviewed mapping nor matched by a
deterministic path rule gets ``category: null`` and a ``classification:*`` gap
token; the exporter never guesses.

Exit codes: 0 success, 1 validation or data failure, 2 usage error.
"""

from __future__ import annotations

import argparse
import atexit
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from collections import Counter
from pathlib import Path, PurePosixPath

try:
    import fcntl
except ImportError:  # pragma: no cover - non-POSIX hosts fall back to an unlocked append
    fcntl = None

LEDGER_FIELDS = [
    "project",
    "task",
    "brief_path",
    "plan_ref",
    "run_id",
    "start_head",
    "end_head",
    "findings",
    "ask_user_answers",
    "fix_commits",
    "pr_url",
    "ci_result",
    "rounds",
    "wall_time_s",
    "observed_at",
    "source",
    "gaps",
]

FINDING_FIELDS = ["id", "severity", "category", "file", "action"]

SEVERITIES = ("error", "warning", "info")
ACTIONS = ("auto-fix", "ask-user", "no-op")

CATEGORIES = (
    "missing contract",
    "wrong path/name",
    "stale assumption",
    "missing test/fixture",
    "schema/migration drift",
    "ambiguous acceptance",
    "unsafe edge/rollback",
    "environment/tooling",
)

CI_RESULTS = ("green", "failed", "no-ci", "not-run", "pending", "unknown")

DECISIONS = ("selected", "declined", "presented", "escalated-to-captain", "unrecorded")

TERMINAL_STATUSES = ("completed", "failed", "cancelled")

SHA_RE = re.compile(r"^[0-9a-f]{40}$")
PLAN_RE = re.compile(r"docs/plans/[A-Za-z0-9._/-]+\.md")
PLAN_ALT_RE = re.compile(r"data/[A-Za-z0-9._-]+/(?:report|plan|blueprint)\.md")
PLAN_NUMBERED_RE = re.compile(r"data/[A-Za-z0-9._-]+/\d\d-[A-Za-z0-9._-]+\.md")
SLICE_RE = re.compile(r"\bslice\s+(\d+)\b", re.IGNORECASE)
TASK_SLICE_RE = re.compile(r"(?:^|-)(?:s|slice[-_]?)(\d+)(?:-|$)")
BACKLOG_ITEM_RE = re.compile(r"^- \[[ x]\] ([A-Za-z0-9._-]+) - ")
ENV_FAILURE_RE = re.compile(
    r"usage limit|rate limit|\b429\b|quota|out of credits|at capacity|"
    r"daemon shutting down|create session|no such file|fork/exec|"
    r"execution did not succeed|wall-clock limit|invocation budget|timed out|"
    r"connection refused|socket|network",
    re.IGNORECASE,
)

# Deterministic first-pass rules for findings absent from the reviewed mapping.
# Ordered, first match wins. Each rule covers a path class whose defect nature is
# fixed by where the defect landed, so no prose inspection is involved.
PATH_RULES = (
    (re.compile(r"(^|/)(tests?|spec|__tests__|fixtures?)/"), "missing test/fixture"),
    (re.compile(r"(^|/)(migrations?|alembic)/"), "schema/migration drift"),
    (re.compile(r"\.sql$"), "schema/migration drift"),
    (re.compile(r"(^|/)\.github/"), "environment/tooling"),
    (re.compile(r"(^|/)(Makefile|Dockerfile|docker-compose\.ya?ml)$"), "environment/tooling"),
    (re.compile(r"(^|/)(uv\.lock|poetry\.lock|package-lock\.json|pnpm-lock\.yaml)$"), "environment/tooling"),
)


class LedgerError(Exception):
    """One deterministic ledger failure."""


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------


def read_text(path: Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return None


def parse_kv(path: Path) -> dict[str, str]:
    text = read_text(path)
    out: dict[str, str] = {}
    if text is None:
        return out
    for line in text.splitlines():
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        if key:
            out[key] = value.strip()
    return out


def task_from_branch(branch: str) -> str:
    return branch[3:] if branch.startswith("fm/") else branch


def load_backlog(path: Path) -> dict[str, str]:
    """Return {task: body} from the markdown backlog, one item per task."""
    text = read_text(path)
    items: dict[str, str] = {}
    if text is None:
        return items
    current: str | None = None
    body: list[str] = []
    for line in text.splitlines():
        match = BACKLOG_ITEM_RE.match(line)
        if match:
            if current:
                items[current] = "\n".join(body)
            current = match.group(1)
            body = [line]
            continue
        if line.startswith("## ") or line.startswith("# "):
            if current:
                items[current] = "\n".join(body)
            current = None
            body = []
            continue
        if current:
            body.append(line)
    if current:
        items[current] = "\n".join(body)
    return items


def extract_plan_ref(task: str, *texts: str) -> tuple[str | None, str | None]:
    """Return (plan_ref, source) from the first text carrying a plan reference."""
    slice_number = None
    task_slice = TASK_SLICE_RE.search(task)
    if task_slice:
        slice_number = task_slice.group(1)
    for label, text in texts:
        if not text:
            continue
        if slice_number is None:
            found = SLICE_RE.search(text)
            if found:
                slice_number = found.group(1)
        for pattern in (PLAN_RE, PLAN_ALT_RE, PLAN_NUMBERED_RE):
            match = pattern.search(text)
            if match:
                ref = match.group(0)
                if slice_number:
                    ref = f"{ref}#slice-{slice_number}"
                return ref, label
    return None, None


def project_from_path(working_path: str | None) -> str:
    if not working_path:
        return "unknown"
    return PurePosixPath(working_path).name


def open_state_db(nm_data: Path) -> tuple[sqlite3.Connection, str]:
    """Open the no-mistakes state database read-only, copying it if required."""
    db_path = nm_data / "state.sqlite"
    if not db_path.is_file():
        raise LedgerError(f"no-mistakes state database not found: {db_path}")
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    try:
        conn.execute("select count(*) from runs").fetchone()
        return conn, "live-readonly"
    except sqlite3.Error:
        conn.close()
    tmpdir = Path(tempfile.mkdtemp(prefix="fm-prevention-ledger-"))
    atexit.register(shutil.rmtree, tmpdir, True)
    for suffix in ("", "-wal", "-shm"):
        source = Path(str(db_path) + suffix)
        if source.is_file():
            shutil.copy2(source, tmpdir / (db_path.name + suffix))
    conn = sqlite3.connect(str(tmpdir / db_path.name))
    conn.row_factory = sqlite3.Row
    conn.execute("select count(*) from runs").fetchone()
    return conn, f"snapshot:{tmpdir}"


def load_classifications(path: Path) -> dict[tuple[str, str, str], str]:
    """Load the reviewed category mapping, keyed (project, branch, finding_id)."""
    mapping: dict[tuple[str, str, str], str] = {}
    text = read_text(path)
    if text is None:
        return mapping
    for lineno, line in enumerate(text.splitlines(), start=1):
        if not line.strip() or line.startswith("#"):
            continue
        fields = line.split("\t")
        if fields[0] == "project" and fields[1:2] == ["branch"]:
            continue
        if len(fields) != 4:
            raise LedgerError(f"{path}:{lineno}: expected 4 tab-separated fields")
        project, branch, finding_id, category = fields
        if category not in CATEGORIES:
            raise LedgerError(f"{path}:{lineno}: unknown category {category!r}")
        key = (project, branch, finding_id)
        if key in mapping:
            raise LedgerError(f"{path}:{lineno}: duplicate classification for {key}")
        mapping[key] = category
    return mapping


def classify(
    project: str,
    branch: str,
    finding: dict,
    mapping: dict[tuple[str, str, str], str],
) -> str | None:
    """Return the one reviewed category for a finding, or None when unknown."""
    finding_id = finding.get("id")
    if finding_id:
        hit = mapping.get((project, branch, str(finding_id)))
        if hit:
            return hit
    path = finding.get("file") or ""
    for pattern, category in PATH_RULES:
        if path and pattern.search(path):
            return category
    return None


# ---------------------------------------------------------------------------
# Reading no-mistakes state
# ---------------------------------------------------------------------------


def load_runs(conn: sqlite3.Connection, until: int | None) -> list[dict]:
    query = (
        "SELECT ru.*, rp.working_path FROM runs ru "
        "LEFT JOIN repos rp ON rp.id = ru.repo_id "
        "ORDER BY ru.created_at, ru.id"
    )
    rows = []
    for row in conn.execute(query):
        record = dict(row)
        if record["status"] not in TERMINAL_STATUSES:
            continue
        if until is not None and record["updated_at"] > until:
            continue
        rows.append(record)
    return rows


def load_findings(conn: sqlite3.Connection) -> tuple[dict[str, dict[str, dict]], set[str]]:
    """Return ({run_id: {finding_id: finding}}, run ids with unparseable findings)."""
    per_run: dict[str, dict[str, dict]] = {}
    unparseable: set[str] = set()

    def absorb(run_id: str, payload: str | None) -> None:
        if not payload:
            return
        try:
            data = json.loads(payload)
        except json.JSONDecodeError:
            unparseable.add(run_id)
            return
        if isinstance(data, dict):
            items = data.get("findings") or []
        elif isinstance(data, list):
            items = data
        else:
            unparseable.add(run_id)
            return
        if not isinstance(items, list):
            unparseable.add(run_id)
            return
        bucket = per_run.setdefault(run_id, {})
        for item in items:
            if not isinstance(item, dict):
                unparseable.add(run_id)
                continue
            finding_id = item.get("id")
            if finding_id in (None, ""):
                continue
            bucket.setdefault(str(finding_id), item)

    for row in conn.execute(
        "SELECT sr.run_id, r.findings_json FROM step_rounds r "
        "JOIN step_results sr ON sr.id = r.step_result_id "
        "WHERE sr.step_name = 'review' AND coalesce(r.findings_json, '') != '' "
        "ORDER BY r.created_at"
    ):
        absorb(row["run_id"], row["findings_json"])
    for row in conn.execute(
        "SELECT run_id, findings_json FROM step_results "
        "WHERE step_name = 'review' AND coalesce(findings_json, '') != ''"
    ):
        absorb(row["run_id"], row["findings_json"])
    return per_run, unparseable


def load_gate_rounds(conn: sqlite3.Connection) -> dict[str, list[dict]]:
    """Return {run_id: [round records]} for ask-user gate evidence."""
    per_run: dict[str, list[dict]] = {}
    for row in conn.execute(
        "SELECT sr.run_id, r.round, r.user_findings_json, r.selected_finding_ids, "
        "r.selection_source, r.response_origin, r.created_at FROM step_rounds r "
        "JOIN step_results sr ON sr.id = r.step_result_id "
        "ORDER BY r.created_at"
    ):
        per_run.setdefault(row["run_id"], []).append(dict(row))
    return per_run


def load_review_rounds(conn: sqlite3.Connection) -> dict[str, int]:
    counts: dict[str, int] = {}
    for row in conn.execute(
        "SELECT sr.run_id AS run_id, COUNT(*) AS n FROM step_rounds r "
        "JOIN step_results sr ON sr.id = r.step_result_id "
        "WHERE sr.step_name = 'review' GROUP BY sr.run_id"
    ):
        counts[row["run_id"]] = row["n"]
    return counts


def load_step_status(conn: sqlite3.Connection) -> dict[tuple[str, str], str]:
    out: dict[tuple[str, str], str] = {}
    for row in conn.execute("SELECT run_id, step_name, status FROM step_results"):
        out[(row["run_id"], row["step_name"])] = row["status"]
    return out


# ---------------------------------------------------------------------------
# Building one row
# ---------------------------------------------------------------------------


def git_fix_commits(nm_data: Path, repo_id: str, start: str | None, end: str | None) -> list[str] | None:
    if not start or not end:
        return None
    git_dir = nm_data / "repos" / f"{repo_id}.git"
    if not git_dir.is_dir():
        return None
    command = [
        "git",
        "--git-dir",
        str(git_dir),
        "log",
        "--format=%H%x09%s",
        f"{start}..{end}",
    ]
    try:
        proc = subprocess.run(
            command, check=False, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=30
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if proc.returncode != 0:
        return None
    commits = []
    for line in proc.stdout.decode("utf-8", "replace").splitlines():
        sha, _, subject = line.partition("\t")
        if subject.startswith("no-mistakes("):
            commits.append(sha)
    return commits


def ask_user_answers(
    run_id: str,
    findings: dict[str, dict],
    gate_rounds: list[dict],
    status_text: str | None,
) -> tuple[list[dict], list[str]]:
    answers: list[dict] = []
    gaps: list[str] = []
    ask_ids = sorted(fid for fid, f in findings.items() if f.get("action") == "ask-user")
    status_lines = status_text.splitlines() if status_text else []
    escalated = {
        match.group(1)
        for line in status_lines
        for match in [re.search(r"needs-decision \[[^\]]*\] \[key=nm-([^\]]+)\]", line)]
        if match
    }
    for finding_id in ask_ids:
        decision = "unrecorded"
        origin = "none"
        for record in gate_rounds:
            presented: list[str] = []
            try:
                payload = json.loads(record.get("user_findings_json") or "{}")
            except json.JSONDecodeError:
                payload = {}
            if isinstance(payload, dict):
                presented = [
                    str(item.get("id"))
                    for item in payload.get("findings") or []
                    if isinstance(item, dict)
                ]
            if finding_id not in presented:
                continue
            selection = record.get("selection_source") or ""
            selected_ids: list[str] = []
            try:
                parsed = json.loads(record.get("selected_finding_ids") or "[]")
                if isinstance(parsed, list):
                    selected_ids = [str(x) for x in parsed]
            except json.JSONDecodeError:
                selected_ids = []
            if selection == "user" and finding_id in selected_ids:
                decision = "selected"
            elif selection == "user_declined":
                decision = "declined"
            elif decision == "unrecorded":
                decision = "presented"
            origin = record.get("response_origin") or "unknown"
        if decision == "unrecorded":
            for key in escalated:
                if key.startswith(f"{run_id}-"):
                    decision = "escalated-to-captain"
                    origin = "status"
                    break
        if decision == "unrecorded":
            gaps.append(f"ask_user:no-recorded-decision:{finding_id}")
        answers.append({"finding_id": finding_id, "decision": decision, "origin": origin})
    return answers, gaps


def ci_result_for(run: dict, steps: dict[tuple[str, str], str]) -> tuple[str, bool]:
    """Return (ci_result, unrecorded) from the pipeline's own recorded CI step."""
    if run.get("ci_ready_no_ci"):
        return "no-ci", False
    ci = steps.get((run["id"], "ci"))
    if ci == "completed":
        return "green", False
    if ci == "failed":
        return "failed", False
    if run["status"] == "cancelled":
        return "not-run", False
    if run["status"] == "completed":
        return "unknown", True
    return "not-run", False


def gh_ci_result(pr_url: str) -> str | None:
    """Read live PR check state with gh-axi, returning None when unreadable."""
    match = re.search(r"https://[^/]+/([^/]+/[^/]+)/pull/(\d+)", pr_url)
    if not match:
        return None
    repo, number = match.group(1), match.group(2)
    command = ["gh-axi", "pr", "view", number, "--repo", repo]
    try:
        proc = subprocess.run(
            command, check=False, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=60
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if proc.returncode != 0:
        return None
    output = proc.stdout.decode("utf-8", "replace")
    checks = re.search(r"^\s*checks:\s*\"?([^\"\n]+)\"?\s*$", output, re.MULTILINE)
    if not checks:
        return None
    summary = checks.group(1)
    failed = re.search(r"(\d+)\s+failed", summary)
    if failed and int(failed.group(1)) > 0:
        return "failed"
    if re.search(r"\b(pending|queued|in_progress|running)\b", summary, re.IGNORECASE):
        return "pending"
    passed = re.search(r"(\d+)\s+passed", summary)
    if passed and int(passed.group(1)) > 0:
        return "green"
    return None


def enrich_with_gh(row: dict) -> dict:
    """Replace ci_result with live forge evidence when the PR is still readable."""
    if not row.get("pr_url"):
        return row
    live = gh_ci_result(row["pr_url"])
    if live is None:
        row["gaps"] = sorted(set(row["gaps"]) | {"ci_result:gh-unreadable"})
        return row
    row["ci_result"] = live
    row["source"] = "+".join(dict.fromkeys([*row["source"].split("+"), "gh-axi"]))
    return row


def build_row(
    run: dict,
    *,
    root: Path,
    nm_data: Path,
    findings: dict[str, dict],
    gate_rounds: list[dict],
    review_rounds: dict[str, int],
    steps: dict[tuple[str, str], str],
    mapping: dict[tuple[str, str, str], str],
    backlog: dict[str, str],
    use_git: bool,
    unparseable: bool = False,
) -> dict:
    project = project_from_path(run["working_path"])
    task = task_from_branch(run["branch"])
    source: list[str] = ["nm-state"]
    gaps: list[str] = []
    if project == "unknown":
        gaps.append("project:unrecorded")
    if unparseable:
        gaps.append("findings:unparseable")

    meta_path = root / "state" / f"{task}.meta"
    meta = parse_kv(meta_path)
    if meta:
        source.append("task-meta")
    else:
        gaps.append("meta:missing")

    brief_path = None
    for candidate in (root / "data" / task / "brief.md", root / "data" / task / "launch-brief.md"):
        if candidate.is_file():
            brief_path = str(candidate.relative_to(root))
            break
    if brief_path is None:
        gaps.append("brief:missing")
    else:
        source.append("brief")

    plan_ref = meta.get("plan") or None
    plan_source = "task-meta" if plan_ref else None
    brief_text = read_text(root / brief_path) if brief_path else None
    if plan_ref is None:
        plan_ref, plan_source = extract_plan_ref(
            task, ("brief", brief_text or ""), ("backlog", backlog.get(task, ""))
        )
    if plan_source:
        source.append(plan_source)
    if plan_ref is None:
        gaps.append("plan_ref:unrecorded")

    start_head = run.get("base_sha") or None
    if not start_head or not SHA_RE.match(start_head) or set(start_head) == {"0"}:
        start_head = None
        gaps.append("start_head:unrecorded")

    end_head = run.get("last_pushed_sha") or run.get("review_approved_head_sha") or None
    if not end_head:
        end_head = run.get("head_sha") or None
        gaps.append("end_head:not-pushed")
    if end_head is not None and not (isinstance(end_head, str) and SHA_RE.match(end_head)):
        end_head = None
        gaps.append("end_head:invalid")

    finding_rows: list[dict] = []
    for finding_id in sorted(findings, key=natural_key):
        finding = findings[finding_id]
        category = classify(project, run["branch"], finding, mapping)
        if category is None:
            gaps.append(f"classification:unclassified:{finding_id}")
        finding_rows.append(
            {
                "id": str(finding_id),
                "severity": finding.get("severity") or "warning",
                "category": category,
                "file": finding.get("file") or None,
                "action": finding.get("action") or "no-op",
            }
        )

    answers, answer_gaps = ask_user_answers(
        run["id"], findings, gate_rounds, read_text(root / "state" / f"{task}.status")
    )
    gaps.extend(answer_gaps)
    if any(answer["origin"] == "status" for answer in answers):
        source.append("task-status")
    gaps.extend(environment_gaps(run))
    ci_result, ci_unrecorded = ci_result_for(run, steps)
    if ci_unrecorded:
        gaps.append("ci_result:unrecorded")

    fix_commits: list[str] | None = None
    if use_git:
        fix_commits = git_fix_commits(nm_data, run["repo_id"], start_head, end_head)
        if fix_commits is None:
            gaps.append("fix_commits:unrecorded")
        else:
            source.append("proxy-git")
    else:
        gaps.append("fix_commits:not-requested")

    return {
        "project": project,
        "task": task,
        "brief_path": brief_path,
        "plan_ref": plan_ref,
        "run_id": run["id"],
        "start_head": start_head,
        "end_head": end_head,
        "findings": finding_rows,
        "ask_user_answers": answers,
        "fix_commits": fix_commits or [],
        "pr_url": run.get("pr_url") or None,
        "ci_result": ci_result,
        "rounds": review_rounds.get(run["id"], 0),
        "wall_time_s": max(0, int(run["updated_at"]) - int(run["created_at"])),
        "observed_at": int(run["updated_at"]),
        "source": "+".join(dict.fromkeys(source)),
        "gaps": sorted(set(gaps)),
    }


def environment_gaps(run: dict) -> list[str]:
    """Record runs that ended on an environment failure rather than a defect."""
    message = run.get("error") or ""
    if not message:
        return []
    if not ENV_FAILURE_RE.search(message):
        return []
    return ["run:environment-failure"]


def natural_key(value: str) -> list:
    return [int(part) if part.isdigit() else part for part in re.split(r"(\d+)", str(value))]


# ---------------------------------------------------------------------------
# Ledger IO
# ---------------------------------------------------------------------------


def default_ledger_path(root: Path) -> Path:
    return root / "data" / "prevention-ledger" / "runs.jsonl"


def read_ledger(path: Path) -> list[dict]:
    rows: list[dict] = []
    text = read_text(path)
    if text is None:
        return rows
    for lineno, line in enumerate(text.splitlines(), start=1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError as exc:
            raise LedgerError(f"{path}:{lineno}: invalid JSON: {exc}") from exc
        if not isinstance(row, dict):
            raise LedgerError(f"{path}:{lineno}: expected a JSON object")
        rows.append(row)
    return rows


def append_rows(path: Path, rows: list[dict]) -> None:
    """Append rows under an exclusive lock so two exporters cannot interleave."""
    if not rows:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        if fcntl is not None:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        try:
            for row in rows:
                handle.write(json.dumps(row, sort_keys=False, separators=(",", ":")) + "\n")
            handle.flush()
            os.fsync(handle.fileno())
        finally:
            if fcntl is not None:
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------


def resolve_root(args) -> Path:
    """Resolve the firstmate home holding state/, data/, and the ledger."""
    if args.root:
        return Path(args.root).expanduser().resolve()
    env = os.environ.get("FM_HOME")
    if env:
        return Path(env).expanduser().resolve()
    for candidate in (Path.home() / "firstmate", Path(__file__).resolve().parent.parent):
        if (candidate / "state").is_dir() and (candidate / "data").is_dir():
            return candidate
    return Path(__file__).resolve().parent.parent


def resolve_nm_data(args) -> Path:
    if args.nm_data:
        return Path(args.nm_data).expanduser().resolve()
    env = os.environ.get("NO_MISTAKES_DATA")
    if env:
        return Path(env).expanduser().resolve()
    return Path.home() / ".no-mistakes"


def resolve_classifications(args, ledger: Path) -> Path:
    """Find the reviewed category table: explicit, ledger-adjacent, then tracked."""
    if getattr(args, "classifications", None):
        explicit = Path(args.classifications).expanduser().resolve()
        if not explicit.is_file():
            raise LedgerError(f"classification table not found: {explicit}")
        return explicit
    adjacent = ledger.parent / "classifications.tsv"
    if adjacent.is_file():
        return adjacent
    return Path(__file__).resolve().parent.parent / "data" / "prevention-ledger" / "classifications.tsv"


def gather(args) -> tuple[Path, list[dict], Path]:
    root = resolve_root(args)
    nm_data = resolve_nm_data(args)
    ledger = Path(args.ledger).expanduser().resolve() if args.ledger else default_ledger_path(root)
    mapping = load_classifications(resolve_classifications(args, ledger))
    conn, _mode = open_state_db(nm_data)
    try:
        runs = load_runs(conn, args.until)
        findings, unparseable = load_findings(conn)
        gates = load_gate_rounds(conn)
        rounds = load_review_rounds(conn)
        steps = load_step_status(conn)
    finally:
        conn.close()
    backlog = load_backlog(root / "data" / "backlog.md")
    rows = [
        build_row(
            run,
            root=root,
            nm_data=nm_data,
            findings=findings.get(run["id"], {}),
            gate_rounds=gates.get(run["id"], []),
            review_rounds=rounds,
            steps=steps,
            mapping=mapping,
            backlog=backlog,
            use_git=not args.no_git,
            unparseable=run["id"] in unparseable,
        )
        for run in runs
    ]
    if getattr(args, "gh", False):
        rows = [enrich_with_gh(row) for row in rows]
    rows.sort(key=lambda row: (row["observed_at"], row["project"], row["run_id"]))
    return ledger, rows, root


def cmd_backfill(args) -> int:
    ledger, rows, _root = gather(args)
    existing = {(row.get("project"), row.get("run_id")) for row in read_ledger(ledger)}
    fresh = [row for row in rows if (row["project"], row["run_id"]) not in existing]
    fresh.sort(key=lambda row: (row["observed_at"], row["project"], row["run_id"]))
    if args.dry_run:
        for row in fresh:
            print(json.dumps(row, sort_keys=False, separators=(",", ":")))
        print(f"would append {len(fresh)} rows to {ledger}", file=sys.stderr)
        return 0
    append_rows(ledger, fresh)
    if not args.quiet:
        print(f"backfill: appended {len(fresh)} rows, skipped {len(rows) - len(fresh)} existing, ledger {ledger}")
    return 0


def cmd_export(args) -> int:
    ledger, rows, _root = gather(args)
    task = task_from_branch(args.task) if args.task.startswith("fm/") else args.task
    selected = [row for row in rows if row["task"] == task]
    if not selected:
        raise LedgerError(f"no terminal runs for task {task!r}")
    existing = {(row.get("project"), row.get("run_id")) for row in read_ledger(ledger)}
    fresh = [row for row in selected if (row["project"], row["run_id"]) not in existing]
    fresh.sort(key=lambda row: (row["observed_at"], row["project"], row["run_id"]))
    append_rows(ledger, fresh)
    if not args.quiet:
        print(f"export: task {task}, appended {len(fresh)} rows, skipped {len(selected) - len(fresh)} existing")
    return 0


def validate_rows(rows: list[dict]) -> list[str]:
    problems: list[str] = []
    seen: set[tuple[str, str]] = set()
    for index, row in enumerate(rows, start=1):
        where = f"row {index}"
        if list(row.keys()) != LEDGER_FIELDS:
            problems.append(f"{where}: field set or order differs from the schema")
            continue
        key = (row["project"], row["run_id"])
        if key in seen:
            problems.append(f"{where}: duplicate (project, run_id) {key}")
        seen.add(key)
        for field in ("project", "task", "run_id", "source"):
            if not isinstance(row[field], str) or not row[field]:
                problems.append(f"{where}: {field} must be a non-empty string")
        for field in ("brief_path", "plan_ref", "pr_url"):
            if row[field] is not None and not isinstance(row[field], str):
                problems.append(f"{where}: {field} must be a string or null")
        for field in ("start_head", "end_head"):
            value = row[field]
            if value is not None and not (isinstance(value, str) and SHA_RE.match(value)):
                problems.append(f"{where}: {field} must be a 40-hex sha or null")
        if not isinstance(row["rounds"], int) or isinstance(row["rounds"], bool) or row["rounds"] < 0:
            problems.append(f"{where}: rounds must be a non-negative integer")
        if not isinstance(row["wall_time_s"], int) or row["wall_time_s"] < 0:
            problems.append(f"{where}: wall_time_s must be a non-negative integer")
        if not isinstance(row["observed_at"], int) or row["observed_at"] <= 0:
            problems.append(f"{where}: observed_at must be a positive epoch second")
        if row["ci_result"] not in CI_RESULTS:
            problems.append(f"{where}: ci_result {row['ci_result']!r} is not one of {CI_RESULTS}")
        if not isinstance(row["fix_commits"], list) or not all(isinstance(x, str) for x in row["fix_commits"]):
            problems.append(f"{where}: fix_commits must be a list of strings")
        if not isinstance(row["gaps"], list) or not all(isinstance(x, str) for x in row["gaps"]):
            problems.append(f"{where}: gaps must be a list of strings")
        gaps = set(row["gaps"]) if isinstance(row["gaps"], list) else set()
        if isinstance(row["gaps"], list) and row["gaps"] != sorted(gaps):
            problems.append(f"{where}: gaps must be sorted and unique")

        finding_ids: set[str] = set()
        if not isinstance(row["findings"], list):
            problems.append(f"{where}: findings must be a list")
            continue
        for finding in row["findings"]:
            if not isinstance(finding, dict) or list(finding.keys()) != FINDING_FIELDS:
                problems.append(f"{where}: finding fields differ from the schema")
                continue
            if finding["id"] in finding_ids:
                problems.append(f"{where}: duplicate finding id {finding['id']}")
            finding_ids.add(finding["id"])
            if finding["severity"] not in SEVERITIES:
                problems.append(f"{where}: severity {finding['severity']!r} is not one of {SEVERITIES}")
            if finding["action"] not in ACTIONS:
                problems.append(f"{where}: action {finding['action']!r} is not one of {ACTIONS}")
            if finding["category"] is None:
                token = f"classification:unclassified:{finding['id']}"
                if token not in gaps:
                    problems.append(f"{where}: null category for {finding['id']} without a gap token")
            elif finding["category"] not in CATEGORIES:
                problems.append(f"{where}: category {finding['category']!r} is outside the taxonomy")

        if not isinstance(row["ask_user_answers"], list):
            problems.append(f"{where}: ask_user_answers must be a list")
            continue
        for answer in row["ask_user_answers"]:
            if not isinstance(answer, dict) or list(answer.keys()) != ["finding_id", "decision", "origin"]:
                problems.append(f"{where}: ask_user_answers entries must be finding_id, decision, origin")
                continue
            if answer["decision"] not in DECISIONS:
                problems.append(f"{where}: decision {answer['decision']!r} is not one of {DECISIONS}")
    return problems


def cmd_validate(args) -> int:
    path = Path(args.ledger).expanduser().resolve() if args.ledger else default_ledger_path(resolve_root(args))
    if not path.is_file():
        raise LedgerError(f"ledger not found: {path}")
    rows = read_ledger(path)
    problems = validate_rows(rows)
    if problems:
        for problem in problems:
            print(f"not ok - {problem}", file=sys.stderr)
        return 1
    unclassified = sum(
        1 for row in rows for finding in row["findings"] if finding["category"] is None
    )
    env_failures = sum(1 for row in rows if "run:environment-failure" in row["gaps"])
    print(
        f"ok - {len(rows)} rows, "
        f"{sum(len(row['findings']) for row in rows)} findings, "
        f"{unclassified} unclassified, "
        f"{env_failures} environment failures, "
        f"{path}"
    )
    return 0


def cmd_stats(args) -> int:
    path = Path(args.ledger).expanduser().resolve() if args.ledger else default_ledger_path(resolve_root(args))
    if not path.is_file():
        raise LedgerError(f"ledger not found: {path}")
    rows = read_ledger(path)
    problems = validate_rows(rows)
    if problems:
        for problem in problems[:5]:
            print(f"not ok - {problem}", file=sys.stderr)
        raise LedgerError(f"{len(problems)} schema problem(s) in {path}; run validate")
    if args.since:
        rows = [row for row in rows if row["observed_at"] >= args.since]
    counts: Counter[str] = Counter()
    per_project: Counter[str] = Counter()
    tasks: set[str] = set()
    completed = 0
    first_pass = 0
    errors = 0
    rework = 0
    walls: list[int] = []
    rounds: list[int] = []
    for row in rows:
        per_project[row["project"]] += 1
        tasks.add(row["task"])
        walls.append(row["wall_time_s"])
        rounds.append(row["rounds"])
        errors += sum(1 for finding in row["findings"] if finding["severity"] == "error")
        if row["ci_result"] in ("green", "no-ci"):
            completed += 1
            rework += len(row["fix_commits"])
            if not row["findings"] and "findings:unparseable" not in row["gaps"]:
                first_pass += 1
        for finding in row["findings"]:
            counts[finding["category"] or "unclassified"] += 1
    total = sum(counts.values())
    reviewed = sum(1 for row in rows if row["rounds"] > 0)
    payload = {
        "rows": len(rows),
        "tasks": len(tasks),
        "review_entering_rows": reviewed,
        "findings": total,
        "error_findings": errors,
        "findings_per_task": round(total / len(tasks), 2) if tasks else 0.0,
        "errors_per_review_entering_row": round(errors / reviewed, 2) if reviewed else 0.0,
        "completed_rows": completed,
        "first_pass_rows": first_pass,
        "first_pass_rate": round(first_pass / completed, 4) if completed else 0.0,
        "rework_commits_per_completed_row": round(rework / completed, 2) if completed else 0.0,
        "median_wall_time_s": sorted(walls)[len(walls) // 2] if walls else 0,
        "median_rounds": sorted(rounds)[len(rounds) // 2] if rounds else 0,
        "max_rounds": max(rounds) if rounds else 0,
        "unclassified": counts.get("unclassified", 0),
        "categories": {
            name: {
                "count": counts.get(name, 0),
                "share": round(counts.get(name, 0) / total, 4) if total else 0.0,
            }
            for name in [*CATEGORIES, "unclassified"]
        },
        "projects": dict(sorted(per_project.items())),
    }
    if args.format == "json":
        print(json.dumps(payload, indent=2, sort_keys=True))
        return 0
    print(
        f"rows: {payload['rows']}  tasks: {payload['tasks']}  findings: {total}  "
        f"first-pass rows: {first_pass}/{completed} completed"
    )
    print(
        f"  findings/task {payload['findings_per_task']}  "
        f"errors/review-entering row {payload['errors_per_review_entering_row']}  "
        f"rework commits/completed row {payload['rework_commits_per_completed_row']}  "
        f"median wall {payload['median_wall_time_s']}s  "
        f"median rounds {payload['median_rounds']} (max {payload['max_rounds']})"
    )
    for name in [*CATEGORIES, "unclassified"]:
        entry = payload["categories"][name]
        print(f"  {entry['count']:5d}  {entry['share'] * 100:5.1f}%  {name}")
    for project, count in payload["projects"].items():
        print(f"  {count:5d} rows  {project}")
    return 0


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def add_common(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--root", help="firstmate home holding state/, data/, and the ledger")
    parser.add_argument("--nm-data", help="no-mistakes data directory holding state.sqlite")
    parser.add_argument("--ledger", help="ledger path, default <root>/data/prevention-ledger/runs.jsonl")
    parser.add_argument("--classifications", help="reviewed category table, default next to the ledger")
    parser.add_argument("--until", type=int, help="capture cutoff epoch; runs updated later are skipped")
    parser.add_argument("--no-git", action="store_true", help="skip proxy-git fix commit recovery")
    parser.add_argument(
        "--gh",
        action="store_true",
        help="read live PR check state with gh-axi; off by default so replays reproduce",
    )
    parser.add_argument("--quiet", action="store_true", help="suppress the summary line")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="fm-prevention-ledger.py",
        description="Export the append-only prevention ledger for no-mistakes runs.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    backfill = sub.add_parser("backfill", help="append every terminal run not already in the ledger")
    add_common(backfill)
    backfill.add_argument("--dry-run", action="store_true", help="print the rows that would be appended")
    backfill.set_defaults(func=cmd_backfill)

    export = sub.add_parser("export", help="append the terminal runs of one task")
    export.add_argument("task", help="task name, with or without the fm/ prefix")
    add_common(export)
    export.set_defaults(func=cmd_export)

    validate = sub.add_parser("validate", help="validate the ledger against the row schema")
    validate.add_argument("--root")
    validate.add_argument("--ledger")
    validate.set_defaults(func=cmd_validate)

    stats = sub.add_parser("stats", help="print the category mix for the weekly review")
    stats.add_argument("--root")
    stats.add_argument("--ledger")
    stats.add_argument("--since", type=int, help="only rows observed at or after this epoch")
    stats.add_argument("--format", choices=("text", "json"), default="text")
    stats.set_defaults(func=cmd_stats)
    return parser


def main(argv: list[str]) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except LedgerError as exc:
        print(f"not ok - {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

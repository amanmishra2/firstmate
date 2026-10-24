#!/usr/bin/env python3
"""fm-brief-preflight.py - deterministic plan lint over a dispatch brief.

Run this on a written brief before spawning a worker. It checks the three
authoring contracts the prevention ledger identified as the top recurring
causes of preventable review findings, and it fails closed: a missing or
placeholder line is a failure, not a silent pass.

Checks, all deterministic and offline:

  contract-coverage
    The brief carries a line beginning ``Contract coverage:`` naming at least
    one repo path, or declaring ``none``. Each named path must exist at the
    base revision. This is the control for the ``missing contract`` category:
    a stated rule must name every consumer it has to hold at.

  edge-cases
    When the brief names a risk surface (parser, matcher, regex, heuristic,
    migration, concurrency, cleanup, resume, export, schedule), it must carry a
    line beginning ``Edge cases:`` with at least one concrete input, or
    declaring ``none``. This is the control for ``unsafe edge/rollback``.

  stale-facts
    The brief carries a line beginning ``Stale facts:`` naming at least one
    repo path the change must update, or declaring ``none``. Each named path
    must exist at the base revision. This is the control for the
    ``stale assumption`` category: doc, count, version, and navigation drift.

Path resolution uses ``git cat-file`` against ``--project`` and
``--base-ref``. A named path that exists passes. A named path whose parent
directory exists but whose file does not fails as a stale reference. A path
whose parent is also absent fails as unknown, because a brief may only cite
files that already exist; files the task will create belong in the change, not
in the coverage claim.
Tokens starting with ``data/`` are never resolved: they are firstmate-home task
material, not files in the project under review.

``--record <path>`` appends one outcome line per invocation so the weekly review
can measure adoption from durable evidence rather than from memory.
It is opt-in because a plain lint run must stay side-effect free.

Exit codes: 0 all requested checks pass, 1 at least one failed, 2 usage error
including an unresolvable ``--base-ref``.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path

CHECK_NAMES = ("contract-coverage", "edge-cases", "stale-facts")

LINE_LABELS = {
    "contract-coverage": re.compile(r"^\s*contract coverage\s*:\s*(.*)$", re.IGNORECASE),
    "edge-cases": re.compile(r"^\s*edge cases\s*:\s*(.*)$", re.IGNORECASE),
    "stale-facts": re.compile(r"^\s*stale facts\s*:\s*(.*)$", re.IGNORECASE),
}

RISK_SURFACE_RE = re.compile(
    r"\b(parse[rs]?|parsing|regex|regular expression|matcher|match(?:es|ing)?|"
    r"heuristic|classifier|normaliz\w*|threshold|migrat\w+|concurren\w*|race|"
    r"atomic|rollback|cleanup|resume|checkpoint|export\w*|schedul\w*|cron|"
    r"retry|fallback)\b",
    re.IGNORECASE,
)

INLINE_CODE_RE = re.compile(r"`([^`\n]+)`")
NONE_RE = re.compile(r"^(none|n/a|nothing)\.?$", re.IGNORECASE)


class PreflightError(Exception):
    """One deterministic preflight failure."""


def read_brief(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError as exc:
        raise PreflightError(f"cannot read brief {path}: {exc}") from exc


def labeled_value(text: str, check: str) -> tuple[bool, str]:
    """Return (present, value) for the labelled line a check depends on."""
    pattern = LINE_LABELS[check]
    for line in text.splitlines():
        match = pattern.match(line)
        if match:
            return True, match.group(1).strip()
    return False, ""


def is_placeholder(value: str) -> bool:
    if not value:
        return True
    if re.match(r"^\(\s*fill\b", value, re.IGNORECASE):
        return True
    if re.fullmatch(r"[\{<\[].*[\}>\]][\s.,;:]*", value) and len(value) <= 80:
        return True
    return bool(re.fullmatch(r"(tbd|todo|tba|\?+)\.?", value, re.IGNORECASE))


_TREE_CACHE: dict[tuple[str, str], list[str]] = {}


def repo_paths(project: Path, ref: str) -> list[str]:
    """Return every path at the base revision, cached for this process."""
    key = (str(project), ref)
    if key not in _TREE_CACHE:
        proc = subprocess.run(
            ["git", "-C", str(project), "ls-tree", "-r", "--name-only", ref],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        _TREE_CACHE[key] = proc.stdout.decode("utf-8", "replace").splitlines() if proc.returncode == 0 else []
    return _TREE_CACHE[key]


def unique_basename_match(project: Path, ref: str, token: str) -> str | None:
    """Return the single repository path whose basename matches a bare token."""
    matches = [path for path in repo_paths(project, ref) if path.rsplit("/", 1)[-1] == token]
    return matches[0] if len(matches) == 1 else None


def candidate_paths(value: str, project: Path | None, ref: str) -> list[str]:
    """Extract repo-relative path tokens from a labelled line."""
    tokens: list[str] = []
    for span in INLINE_CODE_RE.findall(value):
        tokens.extend(part for part in re.split(r"[\s,]+", span) if part)
    if not tokens:
        tokens = [part for part in re.split(r"[\s,]+", value) if part]
    result: list[str] = []
    for token in tokens:
        token = token.strip(".;:()[]'\"")
        if not token or token.startswith(("/", "~", "http", "data/")):
            continue
        if any(char in token for char in "<>*$?{}|"):
            continue
        if len(token) > 160:
            continue
        if "/" in token:
            result.append(token)
            continue
        # A bare token counts as a filename only when it looks like one, so
        # prose words and version strings are never resolved as paths. A
        # unique basename elsewhere in the tree is accepted, so shorthand such
        # as `fm-brief.sh` for `bin/fm-brief.sh` is not a false failure.
        if project is not None and "." in token:
            if git_path_exists(project, ref, token):
                result.append(token)
                continue
            resolved = unique_basename_match(project, ref, token)
            if resolved:
                result.append(resolved)
    return list(dict.fromkeys(result))


def git_path_exists(project: Path, ref: str, path: str) -> bool:
    proc = subprocess.run(
        ["git", "-C", str(project), "cat-file", "-e", f"{ref}:{path}"],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return proc.returncode == 0


def git_ref_exists(project: Path, ref: str) -> bool:
    proc = subprocess.run(
        ["git", "-C", str(project), "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}"],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return proc.returncode == 0


def resolve_paths(project: Path, ref: str, paths: list[str]) -> tuple[list[str], list[str]]:
    """Split paths into (resolved, unresolved) against the base revision."""
    resolved: list[str] = []
    unresolved: list[str] = []
    for path in paths:
        if git_path_exists(project, ref, path):
            resolved.append(path)
            continue
        parent = str(Path(path).parent)
        if parent not in (".", "") and git_path_exists(project, ref, parent):
            unresolved.append(f"{path} (parent directory exists, file does not)")
        else:
            unresolved.append(f"{path} (not present at {ref})")
    return resolved, unresolved


def check_line_check(text: str, check: str, project: Path | None, ref: str) -> dict:
    present, value = labeled_value(text, check)
    result = {"check": check, "ok": False, "declared_none": False, "detail": ""}
    if not present:
        result["detail"] = "missing a line beginning with the required label"
        return result
    if is_placeholder(value):
        result["detail"] = "label is present but the value is empty or a placeholder"
        return result
    if NONE_RE.match(value):
        result["ok"] = True
        result["declared_none"] = True
        result["detail"] = "declared none"
        return result
    paths = candidate_paths(value, project, ref)
    if not paths:
        result["detail"] = "no repo-relative path named; name the files or write none"
        return result
    if project is None:
        result["ok"] = True
        result["detail"] = f"{len(paths)} path(s) named; unverified because no project was given"
        return result
    resolved, unresolved = resolve_paths(project, ref, paths)
    if unresolved:
        result["detail"] = "unresolved: " + "; ".join(unresolved)
        return result
    result["ok"] = True
    result["detail"] = f"{len(resolved)} path(s) confirmed at {ref}"
    return result


def check_edge_cases(text: str) -> dict:
    result = {"check": "edge-cases", "ok": False, "declared_none": False, "detail": ""}
    surface = sorted({match.group(0).lower() for match in RISK_SURFACE_RE.finditer(text)})
    if not surface:
        result["ok"] = True
        result["detail"] = "no risk surface named; check not applicable"
        return result
    present, value = labeled_value(text, "edge-cases")
    if not present:
        result["detail"] = "risk surface (" + ", ".join(surface[:4]) + ") needs an Edge cases: line"
        return result
    if is_placeholder(value):
        result["detail"] = "Edge cases: is present but empty or a placeholder"
        return result
    if NONE_RE.match(value):
        result["ok"] = True
        result["declared_none"] = True
        result["detail"] = "declared none for surface " + ", ".join(surface[:4])
        return result
    result["ok"] = True
    result["detail"] = "named for surface " + ", ".join(surface[:4])
    return result


def run_checks(text: str, project: Path | None, ref: str, selected: tuple[str, ...]) -> list[dict]:
    results = []
    for check in selected:
        if check == "edge-cases":
            results.append(check_edge_cases(text))
        else:
            results.append(check_line_check(text, check, project, ref))
    return results


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="fm-brief-preflight.py",
        description="Deterministic plan lint over a dispatch brief.",
    )
    parser.add_argument("--brief", required=True, help="brief file to lint")
    parser.add_argument("--project", help="project checkout used to resolve cited paths")
    parser.add_argument("--base-ref", default="HEAD", help="revision cited paths must exist at (default HEAD)")
    parser.add_argument(
        "--check",
        action="append",
        choices=CHECK_NAMES,
        help="run only this check; repeat to run several (default: all)",
    )
    parser.add_argument("--json", action="store_true", help="emit one JSON object instead of text")
    parser.add_argument(
        "--record",
        help="append one outcome line to this JSONL file so the weekly review can measure adoption",
    )
    return parser


def record_outcome(path: Path, brief: str, results: list[dict], ok: bool) -> None:
    """Append one adoption record; the weekly review reads these, not the transcript."""
    path.parent.mkdir(parents=True, exist_ok=True)
    record = {
        "brief": brief,
        "ok": ok,
        "failed": [result["check"] for result in results if not result["ok"]],
        "declared_none": [result["check"] for result in results if result["declared_none"]],
        "observed_at": int(time.time()),
    }
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")


def main(argv: list[str]) -> int:
    args = build_parser().parse_args(argv)
    try:
        text = read_brief(Path(args.brief).expanduser())
    except PreflightError as exc:
        print(f"not ok - {exc}", file=sys.stderr)
        return 1
    project = Path(args.project).expanduser() if args.project else None
    if project is not None and not git_ref_exists(project, args.base_ref):
        print(f"not ok - cannot resolve {args.base_ref} in {project}", file=sys.stderr)
        return 2
    selected = tuple(args.check) if args.check else CHECK_NAMES
    results = run_checks(text, project, args.base_ref, selected)
    failed = [result for result in results if not result["ok"]]
    ok = not failed
    if args.record:
        record_outcome(Path(args.record).expanduser(), args.brief, results, ok)
    if args.json:
        print(
            json.dumps(
                {
                    "brief": str(args.brief),
                    "project": str(project) if project else None,
                    "base_ref": args.base_ref,
                    "checks": results,
                    "ok": not failed,
                },
                indent=2,
                sort_keys=True,
            )
        )
    else:
        for result in results:
            status = "ok" if result["ok"] else "not ok"
            print(f"{status} - {result['check']}: {result['detail']}")
        none_declared = sum(1 for result in results if result["declared_none"])
        print(f"preflight: {len(results) - len(failed)}/{len(results)} checks passed, declared-none={none_declared}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

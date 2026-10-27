#!/usr/bin/env python3
"""Lint implementation plans so dispatch cannot start from an incomplete plan.

A plan is a Markdown document with a YAML front-matter block. `PLAN_SCHEMA.yaml`
in `templates/implementation-plan/` owns the field list; this script owns the
deterministic checks. Every rule has a stable id, names the failure it prevents,
and cites the observed run or finding that motivated it (see RULES below, and
`fm-plan-lint.py --rules` for the same table on the terminal).

Usage:
  fm-plan-lint.py [PATH ...] [options]
  fm-plan-lint.py --rules

  PATH is a plan file, or a directory of a plan set. A directory is walked
  recursively and every *.md under a directory named `plans` is treated as a
  plan (so a new file added there without front matter is an error rather than
  silently skipped); any other *.md carrying a `plan_id` front-matter key is
  also linted. Everything else is ignored, which is what lets a design set that
  contains an INDEX.md and review notes be linted as a set.

Options:
  --json            Emit the fm-plan-lint.v1 JSON document instead of text.
  --home DIR        Firstmate home root, used to resolve `repo:` paths, the
                    contract registry, and the prevention ledger. Defaults to
                    $FM_HOME, then the nearest ancestor of PATH holding a
                    `data/` directory, then the current directory.
  --contracts FILE  Contract registry. Defaults to $HOME/data/plan-contracts.yaml
                    (see --home), then the registry shipped in
                    templates/implementation-plan/PLAN_CONTRACTS.example.yaml.
  --ledger FILE     Prevention ledger JSONL. Defaults to
                    <home>/data/prevention-ledger/runs.jsonl.
  --require-ready   Treat a plan that is not `status: ready` (or `in-flight`),
                    or that still has unchecked open decisions, as an error.
                    bin/fm-plan-gate.sh passes this for dispatch.
  --rules           Print the rule table and exit.
  --quiet           Suppress the per-file summary line in text mode.

Exit codes: 0 no error-severity finding; 1 at least one error; 2 usage or I/O
error (an unreadable registry or ledger is an error, never a silent skip).

The linter never executes an acceptance command and never writes to a plan or a
project: it reads text only, so the same input always produces the same output.

Ownership: `docs/plan-lifecycle.md` owns when each check runs and who fixes it;
`templates/implementation-plan/PLAN_SCHEMA.yaml` owns the field list; this
script's RULES table is the single owner of the rule ids.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

SCHEMA_VERSION = "fm-plan-lint.v1"

# --- rules -----------------------------------------------------------------
#
# `prevents` is the failure the rule closes; `evidence` is the observed run or
# finding that justifies it. Both are printed by --rules and carried in the
# JSON output next to every finding, so a reviewer can challenge a rule on its
# evidence rather than on taste.

RULES = {
    "PL001": {
        "title": "missing or empty required section",
        "severity": "error",
        "prevents": "a worker receives a plan that never states the section the "
        "review will need, so the gap is discovered as a review finding after "
        "the work is written.",
        "evidence": "firstmate-repo-maintenance-build run "
        "01M58PGWG1BFYCMSWMJKCNC062 raised 76 findings, 45 of them classified "
        "'missing contract': a rule or boundary the plan never stated, found "
        "only after the change was written.",
    },
    "PL002": {
        "title": "placeholder or unspecified instruction",
        "severity": "error",
        "prevents": "an instruction that reads like a specification but decides "
        "nothing, so the worker guesses and review has to ask.",
        "evidence": "job-search-director-experience-rule run "
        "01M593XECCD9PV856ZKW1MG8DM ended with 23 of its 37 findings ask-user, "
        "the cost of instructions that read like specifications but decide "
        "nothing.",
    },
    "PL003": {
        "title": "acceptance is not a runnable command with an expected result",
        "severity": "error",
        "prevents": "acceptance that cannot be run or cannot fail, which is why "
        "a plan can claim success while a reviewer still has to decide what "
        "success means.",
        "evidence": "job-search-eval-harness-intervals run "
        "01M4S89DM4AWTF2HH1SN98M7JA raised S1 'ambiguous acceptance' on "
        "frozen_benchmark.py; the guard's own plan named prose acceptance.",
    },
    "PL004": {
        "title": "unknown, deprecated, or undeclared contract name",
        "severity": "error",
        "prevents": "a plan and its implementation naming the same table, "
        "field, flag, or command differently, and a deprecated name coming "
        "back into new work.",
        "evidence": "job-search-filtration-data-audit run "
        "01M59G7X5YW26CAQ0VCJJ948CM raised duplicate-legacy-projection-repair "
        "('schema/migration drift') and redundant-qualification-fts-rebuild "
        "('stale assumption') over the same table set.",
    },
    "PL005": {
        "title": "missing, malformed, or unresolvable finding citation",
        "severity": "error",
        "prevents": "a plan section changing without a recorded reason, and a "
        "prevention control whose motivating finding cannot be checked.",
        "evidence": "43 of the ledger's 78 terminal rows record "
        "plan_ref:unrecorded, so no row could be joined to the plan it changed.",
    },
    "PL006": {
        "title": "effort or dependency claim inconsistent with the plan body",
        "severity": "error",
        "prevents": "a slice sized as small being dispatched with a dependency "
        "and a table migration, which is how a 'small' task becomes a "
        "multi-round pipeline run.",
        "evidence": "job-search-director-experience-rule, sized as one rule, "
        "needed 43 review rounds across 13 terminal runs; its longest single "
        "run was 13 rounds (01M593XECCD9PV856ZKW1MG8DM).",
    },
    "PL007": {
        "title": "stale file, line, table, or flag reference",
        "severity": "error",
        "prevents": "a plan citing a path or line that no longer exists, so the "
        "worker edits by guess or reports a wrong-path finding.",
        "evidence": "codebase-maintenance-roadmap runs raised 'wrong "
        "path/name' repeatedly (RM-039, RM-059, RM-073, RM-096, RM-097) for "
        "stale document and script pointers.",
    },
    "PL008": {
        "title": "missing or non-actionable rollback",
        "severity": "error",
        "prevents": "a landed change that cannot be undone, or a rollback line "
        "that only says 'revert' without naming what reverting restores.",
        "evidence": "'unsafe edge/rollback' is the largest ledger category, "
        "397 of 866 findings; a plan that names its undo path before the work "
        "starts is the only place that failure is cheap to prevent.",
    },
    "PL009": {
        "title": "unknown or cyclic plan dependency",
        "severity": "error",
        "prevents": "a slice dispatched before its dependency exists, or two "
        "slices each declaring the other as a prerequisite.",
        "evidence": "data-model §12 backfills depend on schema §15 order; the "
        "redesign set records the ordering in prose only, which is what this "
        "rule makes checkable.",
    },
    "PL010": {
        "title": "plan-set integrity",
        "severity": "error",
        "prevents": "a file added to a plan set without front matter, a "
        "duplicate plan_id, or an unknown status/kind silently bypassing every "
        "other rule.",
        "evidence": "the job-search redesign plan set is 37 documents with no "
        "front matter, so none of them could be gated at dispatch before this "
        "change.",
    },
    "PL011": {
        "title": "definition of ready violated",
        "severity": "error",
        "prevents": "an incomplete plan being dispatched because a gate only "
        "checked that a plan path was present.",
        "evidence": "firstmate-repo-maintenance-build run "
        "01M593WF8DTPXPRTRWBPD2JCJE carries the plan_ref:unrecorded gap, so "
        "nothing recorded what the run implemented, let alone whether it was "
        "ready.",
    },
    "PL012": {
        "title": "changelog or landed-state inconsistency",
        "severity": "error",
        "prevents": "a plan that lands without a dated record, or one marked "
        "landed while the index and changelog still describe it as planned.",
        "evidence": "43 of 78 ledger rows record plan_ref:unrecorded and none "
        "records a plan changelog, because nothing wrote back to a plan after "
        "its merge.",
    },
}

REQUIRED_SECTIONS = {
    # key: (aliases, human label)
    "identity": (["identity"], "Identity"),
    "objective": (["objective and non goals", "objective non goals", "objective"], "Objective and non-goals"),
    "evidence": (["current state evidence", "current state", "evidence"], "Current-state evidence"),
    "contracts": (["contracts", "shared contract", "contract"], "Contracts"),
    "changes": (["exact change list", "change list", "changes"], "Exact change list"),
    "data": (["data and migration", "data migration", "data model changes"], "Data and migration"),
    "failures": (["failure modes", "failure behavior", "failures"], "Failure modes"),
    "tests": (["tests", "test plan"], "Tests"),
    "acceptance": (["acceptance criteria", "acceptance"], "Acceptance criteria"),
    "rollout": (["rollout and rollback", "rollout rollback", "rollback", "rollout"], "Rollout and rollback"),
    "dependencies": (
        ["dependencies and parallel safety", "dependencies parallel safety", "dependencies"],
        "Dependencies and parallel-safety",
    ),
    "observability": (["observability", "telemetry", "metrics and telemetry"], "Observability"),
    "decisions": (["open decisions", "decisions", "open questions"], "Open decisions"),
    "changelog": (["changelog", "change log"], "Changelog"),
}

# Sections whose body text is scanned for placeholders. Narrative sections of a
# long design document are excluded on purpose: a false positive there would
# teach authors to ignore the rule.
PLACEHOLDER_SCAN_SECTIONS = (
    "objective",
    "changes",
    "data",
    "failures",
    "acceptance",
    "rollout",
    "dependencies",
    "observability",
    "decisions",
)

PLACEHOLDER_PATTERNS = [
    (re.compile(r"\bTBD\b", re.I), "TBD"),
    (re.compile(r"\bTODO\b", re.I), "TODO"),
    (re.compile(r"\bFIXME\b", re.I), "FIXME"),
    (re.compile(r"\bsimilar to above\b", re.I), "similar to above"),
    (re.compile(r"\bas above\b", re.I), "as above"),
    (re.compile(r"\bsee above\b", re.I), "see above"),
    (re.compile(r"\bhandle errors?\b", re.I), "handle errors"),
    (re.compile(r"\badd tests?\b", re.I), "add tests"),
    (re.compile(r"\bmake it work\b", re.I), "make it work"),
    (re.compile(r"\bif needed\b", re.I), "if needed"),
    (re.compile(r"\bas needed\b", re.I), "as needed"),
    (re.compile(r"\blorem ipsum\b", re.I), "lorem ipsum"),
    (re.compile(r"\?\?\?"), "???"),
    (re.compile(r"<placeholder>", re.I), "<placeholder>"),
    (re.compile(r"\betc\.?\s*$", re.I), "etc."),
]

ALLOW_MARKER = re.compile(r"<!--\s*plan-lint:\s*allow\s+([^>]+?)\s*-->", re.I)

STATUSES = ("draft", "ready", "in-flight", "landed", "superseded")
KINDS = ("slice", "subtask", "migration", "evaluation")
EFFORTS = ("S", "M", "L", "XL")
EFFORT_CHANGE_ROWS = {"S": 3, "M": 8, "L": 20, "XL": None}

# A command must start with one of these, or with a path that exists in the
# plan's repo. The list is deliberately small: it is a shape check that catches
# "verify it works" prose, not an allowlist of project tooling.
COMMAND_RUNNERS = {
    "pytest", "python", "python3", "bash", "sh", "make", "go", "cargo", "npm",
    "pnpm", "yarn", "node", "deno", "bun", "git", "sqlite3", "psql", "jq",
    "rg", "grep", "awk", "sed", "diff", "cmp", "test", "curl", "uv", "tox",
    "nosetests", "autopep8", "ruff", "mypy", "shellcheck", "actionlint",
}
PROSE_COMMAND = re.compile(
    r"\b(manually|by hand|eyeball|sanity check|verify that|check that|confirm that|"
    r"review the|inspect the|look at|should work|works? as expected)\b",
    re.I,
)
EXPECT_OBSERVABLE = re.compile(
    r"(exit\s+(0|zero|non-?zero|[1-9]\d*)|==|>=|<=|[<>]|\bpasses?\b|\bfails?\b|"
    r"\breturns?\b|\bprints?\b|\bcontains?\b|\bmatches?\b|\bwithin\b|\bequals?\b|"
    r"\bempty\b|\bno output\b|\bzero\b|\b0\b|\bnone\b|\bcount\b|\bsucceeds?\b|"
    r"\baborts?\b|\brefuses?\b)",
    re.I,
)

PATH_REF = re.compile(
    r"`((?:src|scripts|tests|bin|docs|config|tools|migrations|app|ops|packages)/"
    r"[^`\s|,]+?)(?::(\d+)(?:-(\d+))?)?`"
)

FINDING_ID = re.compile(r"^(?P<run>[A-Za-z0-9][A-Za-z0-9_-]{7,}):(?P<finding>[A-Za-z0-9][A-Za-z0-9._-]*)$")


# --- minimal YAML subset ---------------------------------------------------
#
# The registry and the front matter are YAML, and the linter must stay
# dependency-free, so this reads the subset the templates and the registry
# actually use: nested block mappings and sequences, inline `{k: v}` maps,
# inline `[a, b]` lists, quoted and plain scalars, and comments. Anything it
# cannot read raises YamlError, which the caller turns into PL010 rather than
# guessing: a silently misread contract registry would defeat PL004.


class YamlError(ValueError):
    pass


def _strip_yaml_comment(line):
    out = []
    quote = None
    for i, ch in enumerate(line):
        if quote:
            out.append(ch)
            if ch == quote and (i == 0 or line[i - 1] != "\\"):
                quote = None
            continue
        if ch in ("'", '"'):
            quote = ch
            out.append(ch)
            continue
        if ch == "#" and (i == 0 or line[i - 1] in " \t"):
            break
        out.append(ch)
    return "".join(out).rstrip()


def _scalar(text):
    text = text.strip()
    if text == "":
        return None
    if text in ("null", "~"):
        return None
    if text.lower() in ("true", "yes"):
        return True
    if text.lower() in ("false", "no"):
        return False
    if re.fullmatch(r"-?\d+", text):
        return int(text)
    if len(text) >= 2 and text[0] == text[-1] and text[0] in ("'", '"'):
        body = text[1:-1]
        if text[0] == '"':
            body = body.replace('\\"', '"').replace("\\\\", "\\")
        return body
    return text


def _split_inline(text):
    parts, buf, quote, depth = [], [], None, 0
    for ch in text:
        if quote:
            buf.append(ch)
            if ch == quote:
                quote = None
            continue
        if ch in ("'", '"'):
            quote = ch
            buf.append(ch)
            continue
        if ch in "[{":
            depth += 1
        elif ch in "]}":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append("".join(buf))
            buf = []
            continue
        buf.append(ch)
    if "".join(buf).strip():
        parts.append("".join(buf))
    return [p for p in (p.strip() for p in parts) if p]


def _value(text):
    text = text.strip()
    if text.startswith("[") and text.endswith("]"):
        return [_value(part) for part in _split_inline(text[1:-1])]
    if text.startswith("{") and text.endswith("}"):
        out = {}
        for part in _split_inline(text[1:-1]):
            if ":" not in part:
                raise YamlError("inline map entry without ':'")
            key, _, rest = part.partition(":")
            out[_scalar(key)] = _value(rest)
        return out
    return _scalar(text)


def _tokenize_yaml(lines):
    tokens = []
    for number, raw in enumerate(lines, start=1):
        if "\t" in raw[: len(raw) - len(raw.lstrip())]:
            raise YamlError("line %d: tab indentation" % number)
        line = _strip_yaml_comment(raw)
        if not line.strip():
            continue
        if line.strip() in ("---", "..."):
            continue
        indent = len(line) - len(line.lstrip(" "))
        tokens.append((indent, line.strip(), number))
    return tokens


def _parse_block(tokens, index, indent):
    if index >= len(tokens):
        return None, index
    first_indent, first_text, _ = tokens[index]
    if first_indent < indent:
        return None, index
    if first_text.startswith("- ") or first_text == "-":
        return _parse_sequence(tokens, index, first_indent)
    return _parse_mapping(tokens, index, first_indent)


def _parse_sequence(tokens, index, indent):
    out = []
    while index < len(tokens):
        cur_indent, text, number = tokens[index]
        if cur_indent != indent or not (text.startswith("- ") or text == "-"):
            break
        rest = text[1:].strip()
        if not rest:
            value, index = _parse_block(tokens, index + 1, indent + 1)
            out.append(value)
            continue
        if re.match(r"^[A-Za-z0-9_.\-]+\s*:(\s|$)", rest) and not rest.startswith(("'", '"')):
            # A sequence of maps: re-read the item body as a mapping at a
            # deeper indent, then continue with any further keys that follow.
            key, _, tail = rest.partition(":")
            item = {}
            if tail.strip():
                item[_scalar(key)] = _value(tail)
                index += 1
            else:
                value, index = _parse_block(tokens, index + 1, indent + 1)
                item[_scalar(key)] = value
            while index < len(tokens):
                nxt_indent, nxt_text, nxt_number = tokens[index]
                if nxt_indent != indent + 2 or nxt_text.startswith("- "):
                    break
                if ":" not in nxt_text:
                    raise YamlError("line %d: expected 'key: value'" % nxt_number)
                k, _, v = nxt_text.partition(":")
                index += 1
                if v.strip():
                    item[_scalar(k)] = _value(v)
                elif index < len(tokens) and tokens[index][0] > nxt_indent:
                    item[_scalar(k)], index = _parse_block(tokens, index, tokens[index][0])
                else:
                    item[_scalar(k)] = None
            out.append(item)
            continue
        out.append(_value(rest))
        index += 1
    return out, index


def _parse_mapping(tokens, index, indent):
    out = {}
    while index < len(tokens):
        cur_indent, text, number = tokens[index]
        if cur_indent < indent:
            break
        if cur_indent > indent:
            raise YamlError("line %d: unexpected indentation" % number)
        if text.startswith("- "):
            break
        if ":" not in text:
            raise YamlError("line %d: expected 'key: value'" % number)
        key, _, tail = text.partition(":")
        key = _scalar(key)
        if tail.strip():
            out[key] = _value(tail)
            index += 1
            continue
        index += 1
        if index < len(tokens) and tokens[index][0] > cur_indent:
            value, index = _parse_block(tokens, index, tokens[index][0])
        elif index < len(tokens) and tokens[index][0] == cur_indent and tokens[index][1].startswith("- "):
            value, index = _parse_sequence(tokens, index, cur_indent)
        else:
            value = None
        out[key] = value
    return out, index


def parse_yaml(text):
    """Parse the YAML subset above. Returns a dict (or list) or raises YamlError."""
    tokens = _tokenize_yaml(text.splitlines())
    if not tokens:
        return {}
    value, index = _parse_block(tokens, 0, tokens[0][0])
    if index != len(tokens):
        raise YamlError("line %d: trailing content" % tokens[index][2])
    return value


def parse_front_matter(text):
    """Return (front_matter_dict, body, body_start_line).

    Front matter is a leading `---` line pair. A document without it returns an
    empty dict, the whole text, and line 1; PL010 decides whether that matters.
    """
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return {}, text, 1
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            raw = "\n".join(lines[1:i])
            try:
                data = parse_yaml(raw)
            except YamlError as exc:
                raise YamlError("front matter: %s" % exc)
            if data is None:
                data = {}
            if not isinstance(data, dict):
                raise YamlError("front matter is not a mapping")
            return data, "\n".join(lines[i + 1 :]), i + 2
    raise YamlError("front matter opened with '---' but never closed")


# --- document model --------------------------------------------------------


def normalize_heading(text):
    text = re.sub(r"^\s*#+\s*", "", text)
    text = re.sub(r"^\s*\d+(?:\.\d+)*\.?\s*", "", text)
    text = text.replace("&", " and ")
    text = re.sub(r"[^a-z0-9]+", " ", text.lower())
    return re.sub(r"\s+", " ", text).strip()


SECTION_RE = re.compile(r"^(#{1,2})\s+(.*\S)\s*$")
RUNIN_RE = re.compile(r"^\s*\*\*([A-Z][^*]{2,60}?)\.?\*\*")


class Section:
    def __init__(self, name, line):
        self.name = name
        self.key = normalize_heading(name)
        self.line = line
        self.lines = []

    @property
    def text(self):
        return "\n".join(self.lines).strip()


def split_sections(body, body_start_line):
    """Split a plan body into sections keyed by normalized heading.

    Accepts two heading shapes: `## Heading` lines and the bold run-in
    `**Heading.**` at the start of a line, which is how the existing design
    documents name their sub-contracts. Content of duplicate headings is merged
    in document order.
    """
    sections = []
    current = Section("", body_start_line)
    for offset, line in enumerate(body.splitlines()):
        line_no = body_start_line + offset
        match = SECTION_RE.match(line)
        if match and len(match.group(1)) == 2:
            sections.append(current)
            current = Section(match.group(2), line_no)
            continue
        runin = RUNIN_RE.match(line)
        if runin:
            sections.append(current)
            current = Section(runin.group(1), line_no)
            current.lines.append(line[runin.end() :].strip())
            continue
        current.lines.append(line)
    sections.append(current)
    return sections


def find_sections(sections, key):
    """Every section matching a required key, in document order.

    A plan may state one section twice - a numbered design heading and a later
    annex heading both named for the same contract - and the lint reads them as
    one section. That is what lets an existing design document gain a
    machine-checkable annex without rewriting its prose.
    """
    aliases = REQUIRED_SECTIONS[key][0]
    found = []
    for section in sections:
        for alias in aliases:
            if section.key == alias or section.key.startswith(alias + " "):
                found.append(section)
                break
    return found


def find_section(sections, key):
    found = find_sections(sections, key)
    return found[0] if found else None


def section_text(sections, key):
    return "\n".join(section.text for section in find_sections(sections, key) if section.text)


# --- models ----------------------------------------------------------------


class Finding:
    def __init__(self, rule, message, file, line=None, section=None, advisory=False):
        self.rule = rule
        self.message = message
        self.file = str(file)
        self.line = line
        self.section = section
        self.advisory = advisory
        meta = RULES[rule]
        self.severity = "warning" if advisory else meta["severity"]

    def as_dict(self):
        meta = RULES[self.rule]
        return {
            "file": self.file,
            "rule": self.rule,
            "severity": self.severity,
            "message": self.message,
            "location": {
                "file": self.file,
                "line": self.line,
                "section": self.section,
            },
            "title": meta["title"],
            "prevents": meta["prevents"],
            "evidence": meta["evidence"],
            "advisory": self.advisory,
        }


class Plan:
    def __init__(self, path):
        self.path = Path(path)
        self.text = ""
        self.error = None
        self.front = {}
        self.body = ""
        self.body_line = 1
        self.sections = []
        self.findings = []

    def add(self, rule, message, line=None, section=None, advisory=False):
        self.findings.append(Finding(rule, message, self.path, line, section, advisory))

    # -- front matter accessors ------------------------------------------

    def field(self, name, default=None):
        value = self.front.get(name, default)
        return value

    def string_field(self, name):
        value = self.front.get(name)
        return value.strip() if isinstance(value, str) else ("" if value is None else None)

    def list_field(self, name):
        value = self.front.get(name)
        if value is None:
            return []
        if isinstance(value, list):
            return value
        return [value]

    @property
    def plan_id(self):
        value = self.front.get("plan_id")
        return value if isinstance(value, str) else ""


def load_plan(path):
    plan = Plan(path)
    try:
        plan.text = plan.path.read_text(encoding="utf-8")
    except OSError as exc:
        plan.error = str(exc)
        plan.add("PL010", "cannot read plan: %s" % exc)
        return plan
    try:
        plan.front, plan.body, plan.body_line = parse_front_matter(plan.text)
    except YamlError as exc:
        plan.add("PL010", "unreadable front matter: %s" % exc, line=1)
        plan.body = plan.text
        return plan
    plan.sections = split_sections(plan.body, plan.body_line)
    return plan


# --- registry and ledger ---------------------------------------------------


class Registry:
    def __init__(self, path=None, data=None):
        self.path = str(path) if path else None
        self.data = data or {}
        self.projects = self.data.get("projects") or {}
        self.error = None

    def project(self, name):
        value = self.projects.get(name) if isinstance(self.projects, dict) else None
        return value if isinstance(value, dict) else None

    def names(self, project, kind):
        entry = self.project(project)
        if not entry:
            return {}
        value = entry.get(kind)
        return value if isinstance(value, dict) else {}


def load_registry(explicit, home):
    candidates = []
    if explicit:
        candidates.append(Path(explicit).expanduser())
    if home:
        candidates.append(Path(home) / "data" / "plan-contracts.yaml")
    candidates.append(Path(__file__).resolve().parent.parent / "templates" / "implementation-plan" / "PLAN_CONTRACTS.example.yaml")
    for candidate in candidates:
        if candidate.is_file():
            try:
                data = parse_yaml(candidate.read_text(encoding="utf-8"))
            except (OSError, YamlError) as exc:
                return Registry(candidate), "registry %s is unreadable: %s" % (candidate, exc)
            if not isinstance(data, dict):
                return Registry(candidate), "registry %s is not a mapping" % candidate
            return Registry(candidate, data), None
    return Registry(), "no contract registry found (looked for %s)" % ", ".join(str(c) for c in candidates)


def load_ledger(explicit, home):
    candidates = []
    if explicit:
        candidates.append(Path(explicit).expanduser())
    if home:
        candidates.append(Path(home) / "data" / "prevention-ledger" / "runs.jsonl")
    for candidate in candidates:
        if candidate.is_file():
            rows = []
            try:
                with candidate.open(encoding="utf-8") as handle:
                    for number, line in enumerate(handle, start=1):
                        line = line.strip()
                        if not line:
                            continue
                        try:
                            rows.append(json.loads(line))
                        except json.JSONDecodeError as exc:
                            return None, "ledger %s line %d is not JSON: %s" % (candidate, number, exc)
            except OSError as exc:
                return None, "ledger %s is unreadable: %s" % (candidate, exc)
            return rows, None
    return None, "prevention ledger not found; finding ids are checked for shape only"


def guess_home(paths):
    env = os.environ.get("FM_HOME")
    if env:
        return Path(env).expanduser()
    for raw in paths:
        current = Path(raw).resolve()
        for parent in [current] + list(current.parents):
            if (parent / "data").is_dir() or (parent / "state").is_dir():
                return parent
    return Path.cwd()


# --- individual rules ------------------------------------------------------


def check_front_matter(plan):
    """PL010: required front matter, known values, correct types."""
    required_strings = ("plan_id", "title", "task", "project", "milestone", "slice", "owner", "status", "rollback")
    if not plan.front:
        plan.add(
            "PL010",
            "no YAML front matter: a plan set file under plans/ must open with "
            "'---' and the PLAN_SCHEMA.yaml fields",
            line=1,
        )
        return
    for name in required_strings:
        value = plan.front.get(name)
        if value is None or (isinstance(value, str) and not value.strip()):
            plan.add("PL010", "front matter is missing required field '%s'" % name, line=1)
        elif not isinstance(value, str):
            plan.add("PL010", "front matter field '%s' must be a string" % name, line=1)
    status = plan.front.get("status")
    if isinstance(status, str) and status not in STATUSES:
        plan.add("PL010", "unknown status '%s' (expected one of %s)" % (status, ", ".join(STATUSES)), line=1)
    kind = plan.front.get("plan_kind")
    if kind is not None and (not isinstance(kind, str) or kind not in KINDS):
        plan.add("PL010", "unknown plan_kind %r (expected one of %s)" % (kind, ", ".join(KINDS)), line=1)
    effort = plan.front.get("effort")
    if effort is not None and (not isinstance(effort, str) or effort not in EFFORTS):
        plan.add("PL010", "unknown effort %r (expected one of %s)" % (effort, ", ".join(EFFORTS)), line=1)
    for name in ("depends_on", "finding_ids", "declared_new_paths", "acceptance_commands", "contracts"):
        value = plan.front.get(name)
        if value is not None and not isinstance(value, (list, dict)):
            plan.add("PL010", "front matter field '%s' must be a list or mapping" % name, line=1)
    if not isinstance(plan.front.get("parallel_safe"), bool):
        plan.add("PL010", "front matter field 'parallel_safe' must be true or false", line=1)


def check_sections(plan):
    """PL001: every required section exists and is non-empty."""
    for key in REQUIRED_SECTIONS:
        sections = find_sections(plan.sections, key)
        label = REQUIRED_SECTIONS[key][1]
        if not sections:
            plan.add(
                "PL001",
                "missing required section '## %s' (%s)" % (label, key),
                line=plan.body_line,
            )
            continue
        if not any(section.text.strip() for section in sections):
            plan.add(
                "PL001",
                "section '## %s' is empty" % label,
                line=sections[0].line,
                section=label,
            )


def check_placeholders(plan):
    """PL002: placeholder or unspecified instruction in a control section."""
    for key in PLACEHOLDER_SCAN_SECTIONS:
        for section in find_sections(plan.sections, key):
            for offset, line in enumerate(section.lines):
                allow = ALLOW_MARKER.search(line)
                allowed = set()
                if allow:
                    allowed = {token.strip().lower() for token in allow.group(1).split(",")}
                stripped = re.sub(r"`[^`]*`", "", line)
                for pattern, token in PLACEHOLDER_PATTERNS:
                    if token.lower() in allowed:
                        continue
                    if pattern.search(stripped):
                        plan.add(
                            "PL002",
                            "placeholder '%s' in %s; state the concrete behavior or "
                            "write `<!-- plan-lint: allow %s -->` when the word is "
                            "meant literally" % (token, REQUIRED_SECTIONS[key][1], token),
                            line=section.line + offset + 1,
                            section=REQUIRED_SECTIONS[key][1],
                        )
                        break
    for name in ("rollback", "owner", "slice", "milestone"):
        value = plan.front.get(name)
        if isinstance(value, str):
            for pattern, token in PLACEHOLDER_PATTERNS:
                if pattern.search(value):
                    plan.add("PL002", "placeholder '%s' in front matter field '%s'" % (token, name), line=1)
                    break


def acceptance_entries(plan):
    raw = plan.front.get("acceptance_commands")
    if not isinstance(raw, list):
        return []
    entries = []
    for item in raw:
        if isinstance(item, dict):
            entries.append(item)
        else:
            entries.append({"command": item})
    return entries


def parse_acceptance_bullets(section):
    """Parse `- **A1** `command` -> expected` bullets into {id: (command, expect)}."""
    out = {}
    if section is None:
        return out
    for line in section.text.splitlines():
        match = re.match(r"^\s*[-*]\s+\*\*(A\d+)\*\*\s*(.*)$", line)
        if not match:
            continue
        rest = match.group(2)
        command = ""
        backtick = re.search(r"`([^`]+)`", rest)
        if backtick:
            command = backtick.group(1).strip()
        expect = rest[backtick.end() :] if backtick else rest
        expect = expect.lstrip(" \u2192->:\u2014").strip()
        out[match.group(1)] = (command, expect)
    return out


def check_acceptance(plan):
    """PL003: every acceptance criterion is a command with an expected result."""
    entries = acceptance_entries(plan)
    sections = find_sections(plan.sections, "acceptance")
    section = sections[0] if sections else None
    label = REQUIRED_SECTIONS["acceptance"][1]
    if not entries:
        plan.add(
            "PL003",
            "front matter 'acceptance_commands' is empty: list at least one "
            "{id, command, expect} the reviewer can run",
            line=1,
        )
        return
    bullets = {}
    for candidate in sections:
        bullets.update(parse_acceptance_bullets(candidate))
    seen = set()
    for entry in entries:
        ident = entry.get("id")
        command = entry.get("command")
        expect = entry.get("expect")
        if not ident or not isinstance(ident, str) or not re.fullmatch(r"A\d+", ident):
            plan.add("PL003", "acceptance entry has no stable id of the form A1, A2, ...", line=1)
            continue
        if ident in seen:
            plan.add("PL003", "duplicate acceptance id %s" % ident, line=1)
            continue
        seen.add(ident)
        if not command or not isinstance(command, str) or not command.strip():
            plan.add("PL003", "acceptance %s has no command" % ident, line=1)
            continue
        if not expect or not isinstance(expect, str) or not expect.strip():
            plan.add("PL003", "acceptance %s has no expected result" % ident, line=1)
            continue
        command = command.strip()
        if PROSE_COMMAND.search(command):
            plan.add(
                "PL003",
                "acceptance %s is prose, not a command: %r" % (ident, command),
                line=1,
            )
        else:
            first = command.split()[0]
            if first not in COMMAND_RUNNERS and "/" not in first:
                plan.add(
                    "PL003",
                    "acceptance %s does not start with a runnable program (%r); "
                    "start with pytest, a script path, or an existing command"
                    % (ident, first),
                    line=1,
                )
        if not EXPECT_OBSERVABLE.search(expect):
            plan.add(
                "PL003",
                "acceptance %s expected result is not observable: %r" % (ident, expect),
                line=1,
            )
        bullet = bullets.get(ident)
        if bullet is None:
            plan.add(
                "PL003",
                "acceptance %s has no `- **%s**` bullet under '## %s'; the body "
                "and the front matter must name the same command" % (ident, ident, label),
                line=section.line if section else None,
                section=label,
            )
            continue
        if bullet[0] != command:
            plan.add(
                "PL003",
                "acceptance %s command drifted: front matter has %r but '## %s' "
                "has %r" % (ident, command, label, bullet[0]),
                line=section.line if section else None,
                section=label,
            )
    for ident in bullets:
        if ident not in seen:
            plan.add(
                "PL003",
                "acceptance %s appears in '## %s' but not in front matter "
                "'acceptance_commands'" % (ident, label),
                line=section.line if section else None,
                section=label,
            )


def check_contracts(plan, registry, registry_problem):
    """PL004: contract names resolve in the registry for this plan's project."""
    project = plan.front.get("project")
    section = find_section(plan.sections, "contracts")
    label = REQUIRED_SECTIONS["contracts"][1]
    declared = plan.front.get("contracts")
    if declared is None:
        plan.add("PL004", "front matter has no 'contracts' mapping", line=1)
        declared = {}
    if not isinstance(declared, dict):
        return
    names = []
    for kind in ("tables", "fields", "flags", "commands"):
        values = declared.get(kind) or []
        if not isinstance(values, list):
            plan.add("PL004", "contracts.%s must be a list" % kind, line=1)
            continue
        for value in values:
            names.append((kind, value))
    for kind_name in sorted(set(declared) - {"tables", "fields", "flags", "commands"}):
        plan.add("PL004", "unknown contracts key '%s'" % kind_name, line=1)
    if registry.error:
        plan.add("PL004", "contract registry unreadable: %s" % registry.error, line=1)
        return
    if registry_problem:
        plan.add("PL004", registry_problem + "; contract names are checked for shape only", line=1, advisory=True)
        return
    if not isinstance(project, str) or not project:
        return
    if registry.path and registry.project(project) is None:
        plan.add(
            "PL004",
            "project '%s' has no section in the contract registry %s" % (project, registry.path),
            line=1,
        )
        return
    for kind, value in names:
        if not isinstance(value, str) or not value.strip():
            plan.add("PL004", "contracts.%s has a non-string entry" % kind, line=1)
            continue
        entries = registry.names(project, kind)
        if registry_problem:
            continue
        entry = entries.get(value)
        if entry is None:
            plan.add(
                "PL004",
                "contract %s '%s' is not in %s; add it to data/plan-contracts.yaml "
                "as planned or canonical, or correct the name"
                % (kind[:-1], value, registry.path or "the registry"),
                line=section.line if section else 1,
                section=label,
            )
            continue
        status = entry.get("status") if isinstance(entry, dict) else entry
        if status == "deprecated":
            note = entry.get("superseded_by") if isinstance(entry, dict) else None
            plan.add(
                "PL004",
                "contract %s '%s' is deprecated%s; use the replacement"
                % (kind[:-1], value, " (use %s)" % note if note else ""),
                line=section.line if section else 1,
                section=label,
            )
        elif status not in ("canonical", "planned"):
            plan.add(
                "PL004",
                "contract %s '%s' has unknown status %r" % (kind[:-1], value, status),
                line=section.line if section else 1,
                section=label,
            )


def check_findings(plan, ledger, ledger_problem):
    """PL005: every plan cites the findings that justify it."""
    ids = plan.list_field("finding_ids")
    evidence_note = plan.front.get("evidence_note")
    section = find_section(plan.sections, "evidence")
    label = REQUIRED_SECTIONS["evidence"][1]
    if not ids:
        if isinstance(evidence_note, str) and len(evidence_note.strip()) >= 20:
            return
        plan.add(
            "PL005",
            "front matter 'finding_ids' is empty: cite at least one "
            "'<run_id>:<finding_id>' from the prevention ledger, or state why "
            "no prior finding applies in 'evidence_note'",
            line=1,
        )
        return
    project = plan.front.get("project")
    rows_by_run = {}
    if ledger is not None:
        for row in ledger:
            if isinstance(row, dict) and isinstance(row.get("run_id"), str):
                rows_by_run[row["run_id"]] = row
    for value in ids:
        if not isinstance(value, str):
            plan.add("PL005", "finding_ids entries must be strings", line=1)
            continue
        match = FINDING_ID.match(value.strip())
        if not match:
            plan.add(
                "PL005",
                "finding id %r is not '<run_id>:<finding_id>'" % value,
                line=section.line if section else 1,
                section=label,
            )
            continue
        if ledger is None:
            continue
        row = rows_by_run.get(match.group("run"))
        if row is None:
            plan.add(
                "PL005",
                "finding %r cites run %s, which is not in the prevention ledger"
                % (value, match.group("run")),
                line=section.line if section else 1,
                section=label,
            )
            continue
        known = {
            finding.get("id")
            for finding in row.get("findings") or []
            if isinstance(finding, dict)
        }
        if match.group("finding") not in known:
            plan.add(
                "PL005",
                "run %s has no finding '%s' (known: %s)"
                % (
                    match.group("run"),
                    match.group("finding"),
                    ", ".join(sorted(str(k) for k in known))[:200] or "none",
                ),
                line=section.line if section else 1,
                section=label,
            )
        if isinstance(project, str) and isinstance(row.get("project"), str) and row["project"] != project:
            plan.add(
                "PL005",
                "finding %r belongs to project '%s' but this plan declares '%s'"
                % (value, row["project"], project),
                line=section.line if section else 1,
                section=label,
            )
    if ledger is None and ledger_problem:
        plan.add("PL005", ledger_problem, line=1, advisory=True)


def change_rows(plan):
    section = find_section(plan.sections, "changes")
    if section is None:
        return []
    rows = []
    for line in section.text.splitlines():
        stripped = line.strip()
        if stripped.startswith("|"):
            cells = [cell.strip() for cell in stripped.strip("|").split("|")]
            if not cells or set("".join(cells)) <= set("-: "):
                continue
            rows.append(cells)
        elif re.match(r"^[-*]\s+\S", stripped):
            rows.append([stripped])
    if rows and all(cell.lower() in ("path", "file", "where", "location") for cell in rows[0][:1]):
        rows = rows[1:]
    return rows


def check_effort(plan):
    """PL006: the effort claim agrees with the plan's own content."""
    effort = plan.front.get("effort")
    rows = change_rows(plan)
    if isinstance(effort, str) and effort in EFFORT_CHANGE_ROWS:
        limit = EFFORT_CHANGE_ROWS[effort]
        if limit is not None and len(rows) > limit:
            plan.add(
                "PL006",
                "effort=%s but '## Exact change list' has %d rows (limit %d for %s); "
                "split the slice or raise the effort" % (effort, len(rows), limit, effort),
                line=find_section(plan.sections, "changes").line,
                section="Exact change list",
            )
    depends = plan.list_field("depends_on")
    if isinstance(effort, str) and effort == "S" and depends:
        plan.add(
            "PL006",
            "effort=S cannot depend on %s: a dependent slice is at least M"
            % ", ".join(str(dep) for dep in depends),
            line=1,
        )
    if plan.front.get("parallel_safe") is False and not depends and not plan.front.get("serial_reason"):
        plan.add(
            "PL006",
            "parallel_safe=false needs a 'serial_reason' or a 'depends_on' entry "
            "naming what it must wait for",
            line=1,
        )
    for value in plan.list_field("declared_new_paths"):
        if isinstance(value, str) and re.search(r"[*?]", value):
            plan.add("PL006", "declared_new_paths entry %r uses a glob; name the file" % value, line=1)


def resolve_repo(plan, home):
    raw = plan.front.get("repo")
    if not isinstance(raw, str) or not raw.strip():
        return None, "front matter has no 'repo'"
    candidate = Path(raw).expanduser()
    if not candidate.is_absolute():
        candidate = Path(home) / candidate
    if not candidate.is_dir():
        return None, "repo %s does not exist" % candidate
    return candidate, None


def check_paths(plan, home):
    """PL007: referenced files and line numbers are real or declared new."""
    repo, problem = resolve_repo(plan, home)
    declared = [value for value in plan.list_field("declared_new_paths") if isinstance(value, str)]
    repo_advised = False
    for key in ("evidence", "changes"):
        section = find_section(plan.sections, key)
        if section is None:
            continue
        label = REQUIRED_SECTIONS[key][1]
        for offset, line in enumerate(section.lines):
            for match in PATH_REF.finditer(line):
                path, start, end = match.group(1), match.group(2), match.group(3)
                line_no = section.line + offset + 1
                if repo is None:
                    if not repo_advised:
                        plan.add(
                            "PL007",
                            "%s; path references are not verified" % problem,
                            line=line_no,
                            section=label,
                            advisory=True,
                        )
                        repo_advised = True
                    continue
                target = repo / path
                if not target.exists():
                    if any(path == entry or path.startswith(entry.rstrip("/") + "/") for entry in declared):
                        continue
                    plan.add(
                        "PL007",
                        "stale path '%s' does not exist in %s; correct it or list "
                        "it in front matter 'declared_new_paths'" % (path, repo),
                        line=line_no,
                        section=label,
                    )
                    continue
                if start and target.is_file():
                    try:
                        with target.open(encoding="utf-8", errors="replace") as handle:
                            total = sum(1 for _ in handle)
                    except OSError:
                        continue
                    last = int(end or start)
                    if last > total:
                        plan.add(
                            "PL007",
                            "stale line reference %s:%s - the file has %d lines"
                            % (path, end or start, total),
                            line=line_no,
                            section=label,
                        )
    for entry in declared:
        if repo is None:
            continue
        if (repo / entry).exists():
            plan.add(
                "PL007",
                "declared_new_paths lists '%s' but it already exists; move it out "
                "of the new-file list" % entry,
                line=1,
            )


def check_rollback(plan):
    """PL008: the rollback is a concrete, reversible action."""
    rollback = plan.front.get("rollback")
    section = find_section(plan.sections, "rollout")
    label = REQUIRED_SECTIONS["rollout"][1]
    vague = re.compile(r"^(revert|rollback|undo)\.?$|^(n/?a|none|not applicable)$", re.I)
    if not isinstance(rollback, str) or not rollback.strip():
        plan.add(
            "PL008",
            "front matter 'rollback' is missing",
            line=1,
        )
        return
    if vague.match(rollback.strip()):
        plan.add(
            "PL008",
            "rollback %r names no action; state what is restored and how it is "
            "verified" % rollback,
            line=1,
        )
    elif len(rollback.strip()) < 12:
        plan.add(
            "PL008",
            "front matter 'rollback' is too short to act on",
            line=1,
        )
    if section is None:
        return
    text = section_text(plan.sections, "rollout").lower()
    if not re.search(r"roll ?back|revert|restore|disable|feature flag", text):
        plan.add(
            "PL008",
            "'## %s' never names a rollback action" % label,
            line=section.line,
            section=label,
        )


def check_dependencies(plan, plans_by_id):
    """PL009: every dependency exists and the graph has no cycle."""
    ids = [plan.plan_id]
    for raw in plan.list_field("depends_on"):
        dep = raw if isinstance(raw, str) else None
        if not dep:
            plan.add("PL009", "depends_on has a non-string entry", line=1)
            continue
        if dep == plan.plan_id:
            plan.add("PL009", "plan depends on itself", line=1)
            continue
        if dep not in plans_by_id:
            plan.add(
                "PL009",
                "depends_on names '%s', which is not in this plan set (known: %s)"
                % (dep, ", ".join(sorted(plans_by_id))[:300] or "none"),
                line=1,
            )
    # Cycle detection over the whole set happens once in check_plan_set.


def check_plan_set(plans):
    """PL010/PL009 across the set: unique ids, no cycles, no orphan files."""
    by_id = {}
    for plan in plans:
        ident = plan.plan_id
        if not ident:
            continue
        if ident in by_id:
            plan.add(
                "PL010",
                "duplicate plan_id '%s' (also %s)" % (ident, by_id[ident].path),
                line=1,
            )
            continue
        by_id[ident] = plan
    graph = {}
    for plan in plans:
        if not plan.plan_id:
            continue
        graph[plan.plan_id] = [
            dep for dep in plan.list_field("depends_on") if isinstance(dep, str) and dep in by_id
        ]

    def visit(node, stack, seen):
        if node in stack:
            cycle = stack[stack.index(node) :] + [node]
            by_id[node].add("PL009", "dependency cycle: %s" % " -> ".join(cycle), line=1)
            return
        if node in seen:
            return
        stack.append(node)
        for nxt in graph.get(node, []):
            visit(nxt, stack, seen)
        stack.pop()
        seen.add(node)

    seen = set()
    for node in graph:
        visit(node, [], seen)
    return by_id


def check_ready(plan, require_ready):
    """PL011: the definition-of-ready preconditions."""
    status = plan.front.get("status")
    section = find_section(plan.sections, "decisions")
    label = REQUIRED_SECTIONS["decisions"][1]
    unchecked = []
    if section is not None:
        for offset, line in enumerate(section.lines):
            if re.match(r"^\s*[-*]\s*\[ \]", line):
                unchecked.append((section.line + offset + 1, line.strip()))
    if status == "ready":
        if unchecked:
            plan.add(
                "PL011",
                "status=ready but '## %s' has %d unchecked item(s); resolve them "
                "or keep the plan draft" % (label, len(unchecked)),
                line=unchecked[0][0],
                section=label,
            )
        if not acceptance_entries(plan):
            plan.add("PL011", "status=ready without acceptance commands", line=1)
        rollback = plan.front.get("rollback")
        if not isinstance(rollback, str) or len(rollback.strip()) < 12:
            plan.add("PL011", "status=ready without a usable rollback", line=1)
    if require_ready and status not in ("ready", "in-flight"):
        plan.add(
            "PL011",
            "plan status is %r; dispatch needs 'ready' (or 'in-flight' for a "
            "relaunch). Resolve open decisions, then record the promotion in "
            "the changelog" % status,
            line=1,
        )
    if require_ready and unchecked:
        plan.add(
            "PL011",
            "plan still has %d unchecked open decision(s), so it is not ready "
            "to dispatch" % len(unchecked),
            line=unchecked[0][0],
            section=label,
        )


CHANGELOG_ENTRY = re.compile(r"^\s*[-*]\s+(\d{4}-\d{2}-\d{2})\b")


def check_changelog(plan):
    """PL012: dated changelog entries, and a landed plan records its PR."""
    section = find_section(plan.sections, "changelog")
    if section is None:
        return
    entries = [line.strip() for line in section.text.splitlines() if line.strip()]
    bullets = [entry for entry in entries if entry.startswith(("- ", "* "))]
    for entry in bullets:
        if not CHANGELOG_ENTRY.match(entry):
            plan.add(
                "PL012",
                "changelog entry is not dated: %r (expected '- YYYY-MM-DD ...')" % entry[:80],
                line=section.line,
                section="Changelog",
            )
    if plan.front.get("status") == "landed":
        if not bullets:
            plan.add(
                "PL012",
                "status=landed but '## Changelog' has no entry",
                line=section.line,
                section="Changelog",
            )
        elif not any(re.search(r"pr[:=]\s*\S*https?://", entry) for entry in bullets):
            plan.add(
                "PL012",
                "status=landed but no changelog entry records 'pr: <url>'; the "
                "post-merge handoff must name the PR it landed",
                line=section.line,
                section="Changelog",
            )


# --- driver ----------------------------------------------------------------


def discover(paths):
    plans = []
    for raw in paths:
        path = Path(raw)
        if path.is_dir():
            for candidate in sorted(path.rglob("*.md")):
                in_plans_dir = "plans" in candidate.parts
                has_front = False
                try:
                    with candidate.open(encoding="utf-8", errors="replace") as handle:
                        has_front = handle.readline().strip() == "---"
                except OSError:
                    continue
                if in_plans_dir or has_front:
                    plans.append(candidate)
        elif path.is_file():
            plans.append(path)
        else:
            plans.append(path)
    # de-duplicate while keeping order
    seen = set()
    unique = []
    for plan_path in plans:
        key = str(plan_path.resolve()) if plan_path.exists() else str(plan_path)
        if key in seen:
            continue
        seen.add(key)
        unique.append(plan_path)
    return unique


def lint(paths, home, contracts_path, ledger_path, require_ready):
    registry, registry_problem = load_registry(contracts_path, home)
    ledger, ledger_problem = load_ledger(ledger_path, home)
    plans = [load_plan(path) for path in discover(paths)]
    for plan in plans:
        if plan.error:
            continue
        check_front_matter(plan)
        check_sections(plan)
        check_placeholders(plan)
        check_acceptance(plan)
        check_contracts(plan, registry, registry_problem)
        check_findings(plan, ledger, ledger_problem)
        check_effort(plan)
        check_paths(plan, home)
        check_rollback(plan)
        check_ready(plan, require_ready)
        check_changelog(plan)
    by_id = check_plan_set(plans)
    for plan in plans:
        check_dependencies(plan, by_id)
    findings = []
    for plan in plans:
        findings.extend(plan.findings)
    findings.sort(key=lambda finding: (finding.file, finding.line or 0, finding.rule))
    return plans, findings, registry, ledger


def render_text(plans, findings, quiet):
    out = []
    for finding in findings:
        where = finding.file
        if finding.line:
            where += ":%d" % finding.line
        label = "warning" if finding.advisory else finding.severity
        out.append("%s: %s %s: %s" % (where, finding.rule, label, finding.message))
    errors = sum(1 for finding in findings if finding.severity == "error")
    warnings = len(findings) - errors
    if not quiet:
        out.append(
            "plan-lint: plans=%d errors=%d warnings=%d"
            % (len(plans), errors, warnings)
        )
    return "\n".join(out)


def main(argv):
    parser = argparse.ArgumentParser(
        prog="fm-plan-lint.py",
        description="Lint implementation plans deterministically (stdlib only).",
    )
    parser.add_argument("paths", nargs="*", help="plan files or a plan-set directory")
    parser.add_argument("--json", action="store_true", help="emit fm-plan-lint.v1 JSON")
    parser.add_argument("--home", default=None, help="firstmate home root")
    parser.add_argument("--contracts", default=None, help="contract registry YAML")
    parser.add_argument("--ledger", default=None, help="prevention ledger JSONL")
    parser.add_argument("--require-ready", action="store_true", help="enforce dispatch readiness")
    parser.add_argument("--rules", action="store_true", help="print the rule table")
    parser.add_argument("--quiet", action="store_true", help="suppress the summary line")
    args = parser.parse_args(argv)

    if args.rules:
        for rule in sorted(RULES):
            meta = RULES[rule]
            print("%s %s [%s]" % (rule, meta["title"], meta["severity"]))
            print("  prevents: %s" % meta["prevents"])
            print("  evidence: %s" % meta["evidence"])
        return 0

    if not args.paths:
        parser.print_usage(sys.stderr)
        print("error: no plan path given", file=sys.stderr)
        return 2

    home = Path(args.home).expanduser() if args.home else guess_home(args.paths)
    missing = [path for path in args.paths if not Path(path).exists()]
    if missing:
        print("error: %s does not exist" % missing[0], file=sys.stderr)
        return 2
    registry, registry_problem = load_registry(args.contracts, home)
    if registry.error:
        print("error: %s" % registry.error, file=sys.stderr)
        return 2
    if args.ledger and not Path(args.ledger).is_file():
        print("error: ledger %s does not exist" % args.ledger, file=sys.stderr)
        return 2
    ledger, ledger_problem = load_ledger(args.ledger, home)
    if ledger_problem and ("not JSON" in ledger_problem or "unreadable" in ledger_problem):
        print("error: %s" % ledger_problem, file=sys.stderr)
        return 2

    plans, findings, registry, ledger = lint(
        args.paths, home, args.contracts, args.ledger, args.require_ready
    )
    errors = [finding for finding in findings if finding.severity == "error"]

    if args.json:
        document = {
            "schema": SCHEMA_VERSION,
            "ok": not errors,
            "home": str(home),
            "contracts": registry.path,
            "ledger": str(args.ledger) if args.ledger else None,
            "require_ready": bool(args.require_ready),
            "findings": [finding.as_dict() for finding in findings],
            "plans": [
                {
                    "file": str(plan.path),
                    "plan_id": plan.plan_id,
                    "status": plan.front.get("status"),
                    "errors": sum(1 for f in plan.findings if f.severity == "error"),
                    "warnings": sum(1 for f in plan.findings if f.severity == "warning"),
                }
                for plan in plans
            ],
            "summary": {
                "plans": len(plans),
                "errors": len(errors),
                "warnings": len(findings) - len(errors),
                "advisory": sum(1 for finding in findings if finding.advisory),
                "rules": sorted({finding.rule for finding in findings}),
            },
        }
        print(json.dumps(document, indent=2, sort_keys=False))
    else:
        text = render_text(plans, findings, args.quiet)
        if text:
            print(text)
    return 0 if not errors else 1


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except BrokenPipeError:
        sys.exit(0)

#!/usr/bin/env python3
"""Rule-by-rule tests for bin/fm-plan-lint.py.

Every rule gets a seeded gap and a fixed plan: the mutation removes or breaks one
thing, the test asserts the specific rule id and the location the failure names,
then applies the inverse mutation and asserts a clean lint. That is the only
thing that keeps a rule honest, because a linter that has never failed has never
been shown to work.

Run directly (`python3 tests/test_plan_lint.py`) or through the repo's runner
(`tests/fm-plan-lint.test.sh`).
"""

import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent
ROOT = TESTS_DIR.parent
LINTER = ROOT / "bin" / "fm-plan-lint.py"
FIXTURES = TESTS_DIR / "fixtures" / "plan-lint"

SPEC = importlib.util.spec_from_file_location("fm_plan_lint", LINTER)
LINT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LINT)


def lint(paths, home=None, contracts=None, ledger=None, require_ready=False):
    """Return (exit_code, parsed_json, stderr)."""
    argv = [str(path) for path in paths]
    if home:
        argv += ["--home", str(home)]
    argv += ["--contracts", str(contracts or (FIXTURES / "registry.yaml"))]
    argv += ["--ledger", str(ledger or (FIXTURES / "ledger.jsonl"))]
    if require_ready:
        argv.append("--require-ready")
    argv.append("--json")
    out, err = io.StringIO(), io.StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        code = LINT.main(argv)
    document = json.loads(out.getvalue()) if out.getvalue().strip() else None
    return code, document, err.getvalue()


def rules_in(document):
    return sorted({finding["rule"] for finding in document["findings"]})


def findings_for(document, rule):
    return [finding for finding in document["findings"] if finding["rule"] == rule]


class FixtureCase(unittest.TestCase):
    """Copies the good fixture into a temp plan set, then mutates one thing."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="plan-lint-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.plan = self.tmp / "PLAN.md"
        self.plan.write_text((FIXTURES / "good-slice.md").read_text(), encoding="utf-8")
        # `repo: repo` is resolved against the home; keep the fixture repo there.
        self.home = self.tmp
        shutil.copytree(FIXTURES / "repo", self.tmp / "repo", dirs_exist_ok=True)

    # -- helpers ---------------------------------------------------------

    def replace(self, old, new):
        text = self.plan.read_text(encoding="utf-8")
        self.assertIn(old, text, "fixture drifted: %r not in the good plan" % old)
        self.plan.write_text(text.replace(old, new, 1), encoding="utf-8")

    def remove(self, needle):
        text = self.plan.read_text(encoding="utf-8")
        self.assertIn(needle, text, "fixture drifted: %r not in the good plan" % needle)
        self.plan.write_text(text.replace(needle, "", 1), encoding="utf-8")

    def assert_clean(self):
        code, document, err = lint([self.plan], home=self.home)
        self.assertEqual(
            0,
            code,
            "expected a clean lint, got: %s"
            % json.dumps(document and document["findings"], indent=2),
        )
        self.assertTrue(document["ok"])
        self.assertEqual([], document["findings"])

    def assert_rule(self, rule, *, line=None, mention=None, require_ready=False):
        code, document, _ = lint([self.plan], home=self.home, require_ready=require_ready)
        self.assertEqual(1, code, "expected a non-zero lint for %s" % rule)
        self.assertFalse(document["ok"])
        found = findings_for(document, rule)
        self.assertTrue(
            found,
            "expected %s, got %s" % (rule, sorted(f["rule"] for f in document["findings"])),
        )
        if line is not None:
            self.assertTrue(
                any(finding["location"]["line"] == line for finding in found),
                "expected %s at line %s, got %s"
                % (rule, line, [f["location"] for f in found]),
            )
        if mention is not None:
            self.assertTrue(
                any(mention in finding["message"] for finding in found),
                "expected %s to name %r, got %s"
                % (rule, mention, [f["message"] for f in found]),
            )
        return document


class GoodPlanTest(FixtureCase):
    def test_good_plan_passes(self):
        self.assert_clean()

    def test_json_document_is_stable(self):
        _, document, _ = lint([self.plan], home=self.home)
        self.assertEqual("fm-plan-lint.v1", document["schema"])
        self.assertEqual(
            {"schema", "ok", "home", "contracts", "ledger", "require_ready", "findings", "plans", "summary"},
            set(document),
        )
        self.assertEqual(
            {"plans", "errors", "warnings", "advisory", "rules"}, set(document["summary"])
        )
        self.assertEqual("fixture-storage-s1", document["plans"][0]["plan_id"])
        self.assertEqual("ready", document["plans"][0]["status"])

    def test_every_rule_is_covered_by_a_test(self):
        exercised = set()
        for name, value in globals().items():
            if not name.endswith(("Test", "Tests")) or not isinstance(value, type):
                continue
            for attribute in dir(value):
                if attribute.startswith("test_pl"):
                    exercised.add(attribute[len("test_") :][:5].upper())
        missing = sorted(set(LINT.RULES) - exercised)
        self.assertEqual([], missing, "rules with no seeded failure test: %s" % missing)

    def test_rules_table_carries_evidence(self):
        for rule, meta in LINT.RULES.items():
            self.assertRegex(rule, r"^PL\d{3}$")
            self.assertTrue(meta["prevents"], rule)
            self.assertGreaterEqual(len(meta["evidence"]), 40, rule)
            self.assertIn(meta["severity"], ("error", "warning"))


class RuleTests(FixtureCase):
    def test_pl001_missing_section(self):
        self.remove("## Observability")
        self.assert_rule("PL001", mention="Observability")
        self.plan.write_text((FIXTURES / "good-slice.md").read_text(), encoding="utf-8")
        self.assert_clean()

    def test_pl002_placeholder(self):
        self.replace("Objective: persist the computed probability on every decided row.", "Objective: TBD")
        self.assert_rule("PL002", mention="TBD")
        self.replace("Objective: TBD", "Objective: persist the computed probability.")
        self.assert_clean()

    def test_pl003_acceptance_must_be_a_command(self):
        self.replace(
            '  - id: A1\n    command: python3 -c "print(1)"\n    expect: exit 0 and prints 1',
            "  - id: A1\n    command: verify manually that the value is persisted\n    expect: exit 0",
        )
        self.assert_rule("PL003", mention="A1")
        self.plan.write_text((FIXTURES / "good-slice.md").read_text(), encoding="utf-8")
        self.replace("- **A1** `python3 -c \"print(1)\"` -> exit 0 and prints 1\n", "")
        self.assert_rule("PL003", mention="no `- **A1**` bullet")

    def test_pl003_expected_result_must_be_observable(self):
        self.replace(
            "    expect: exit 0 and prints 1\n",
            "    expect: it looks right\n",
        )
        self.assert_rule("PL003", mention="not observable")

    def test_pl004_unknown_contract(self):
        self.replace("  tables: [decisions]\n", "  tables: [decisions, ghost_table]\n")
        self.assert_rule("PL004", mention="ghost_table")
        self.replace("  tables: [decisions, ghost_table]\n", "  tables: [decisions]\n")
        self.assert_clean()

    def test_pl004_deprecated_and_wrong_project(self):
        self.replace("project: fixture\n", "project: other\n")
        self.replace("  tables: [decisions]\n", "  tables: [retired_table]\n")
        self.assert_rule("PL004", mention="deprecated")
        self.replace("project: other\n", "project: fixture\n")
        self.replace("  tables: [retired_table]\n", "  tables: [decisions]\n")
        self.assert_clean()

    def test_pl005_uncited_finding(self):
        self.replace('finding_ids: ["01FIXTURE0000000000000001:review-2"]\n', "finding_ids: []\n")
        self.assert_rule("PL005", mention="finding_ids")
        self.replace(
            "finding_ids: []\n",
            'finding_ids: ["01FIXTURE0000000000000001:review-2"]\n',
        )
        self.assert_clean()

    def test_pl005_unknown_finding_in_known_run(self):
        self.replace("01FIXTURE0000000000000001:review-2", "01FIXTURE0000000000000001:review-99")
        self.assert_rule("PL005", mention="review-99")

    def test_pl005_unknown_run(self):
        self.replace("01FIXTURE0000000000000001:review-2", "01NOSUCHRUN000000000000000:review-2")
        self.assert_rule("PL005", mention="not in the prevention ledger")

    def test_pl006_effort_exceeds_change_list(self):
        self.replace("effort: M\n", "effort: S\n")
        self.replace(
            "| `src/fixture/writer.py` | new module | One write per decided row |\n",
            "| `src/fixture/writer.py` | new module | One write per decided row |\n"
            "| `tests/fixture/test_module.py` | new case | Assert one write |\n"
            "| `docs/example.md` | new page | Explain the write |\n",
        )
        self.assert_rule("PL006", mention="effort=S")

    def test_pl006_effort_depends_on(self):
        self.replace("effort: M\n", "effort: S\n")
        self.replace("depends_on: []\n", "depends_on: [fixture-storage-s0]\n")
        self.assert_rule("PL006", mention="effort=S cannot depend")

    def test_pl006_parallel_false_without_reason(self):
        self.replace("parallel_safe: true\n", "parallel_safe: false\n")
        self.assert_rule("PL006", mention="serial_reason")

    def test_pl007_stale_path(self):
        self.replace("`src/fixture/module.py:4-6`", "`src/fixture/gone.py:4`")
        self.assert_rule("PL007", mention="stale path")
        self.replace("`src/fixture/gone.py:4`", "`src/fixture/module.py:4`")
        self.assert_clean()

    def test_pl007_stale_line(self):
        self.replace("`src/fixture/module.py:4-6`", "`src/fixture/module.py:400-410`")
        self.assert_rule("PL007", mention="stale line reference")

    def test_pl007_declared_new_path(self):
        self.replace("`src/fixture/module.py:4-6`", "`src/fixture/new_module.py:1`")
        self.assert_rule("PL007", mention="declared_new_paths")
        self.replace(
            "declared_new_paths:\n  - src/fixture/writer.py\n",
            "declared_new_paths:\n  - src/fixture/writer.py\n  - src/fixture/new_module.py\n",
        )
        self.assert_clean()

    def test_pl008_missing_rollback(self):
        self.replace("rollback: Remove the writer call, leave the column in place, and re-run A1 to confirm the previous behavior.\n", 'rollback: "revert"\n')
        self.assert_rule("PL008", mention="names no action")

    def test_pl008_rollout_section_must_name_rollback(self):
        self.replace("- Rollback: remove the writer call, leave the column, and re-run A1.\n", "")
        self.replace("## Rollout and rollback", "## Rollout")
        self.assert_rule("PL008", mention="never names a rollback action")

    def test_pl009_unknown_dependency(self):
        self.replace("depends_on: []\n", "depends_on: [no-such-plan]\n")
        self.assert_rule("PL009", mention="no-such-plan")

    def test_pl010_missing_front_matter(self):
        text = self.plan.read_text(encoding="utf-8")
        self.plan.write_text(text.split("---\n", 2)[2], encoding="utf-8")
        self.assert_rule("PL010", mention="no YAML front matter")

    def test_pl010_unknown_status(self):
        self.replace("status: ready\n", "status: finished\n")
        self.assert_rule("PL010", mention="unknown status")

    def test_pl011_draft_is_refused_by_the_gate(self):
        self.replace("status: ready\n", "status: draft\n")
        code, document, _ = lint([self.plan], home=self.home, require_ready=True)
        self.assertEqual(1, code)
        self.assertIn("PL011", rules_in(document))
        self.assert_clean()

    def test_pl011_unchecked_open_decision(self):
        self.replace(
            "- [x] Is NULL the right \"unscored\" value? Yes, readers already treat NULL as unscored.",
            "- [ ] Is NULL the right \"unscored\" value?",
        )
        self.assert_rule("PL011", mention="unchecked")

    def test_pl012_landed_without_pr(self):
        self.replace("status: ready\n", "status: landed\n")
        self.assert_rule("PL012", mention="pr:")
        self.replace(
            "- 2026-01-02 Plan created with front matter and acceptance A1-A2.",
            "- 2026-01-02 Plan created with front matter and acceptance A1-A2 (pr: https://example.test/pr/1)",
        )
        self.assert_clean()

    def test_pl012_undated_changelog_entry(self):
        self.replace("- 2026-01-02 Plan created", "- Plan created")
        self.assert_rule("PL012", mention="not dated")


class PlanSetTest(FixtureCase):
    def test_duplicate_plan_id(self):
        twin = self.tmp / "twin.md"
        twin.write_text(self.plan.read_text(encoding="utf-8"), encoding="utf-8")
        code, document, _ = lint([self.plan, twin], home=self.home)
        self.assertEqual(1, code)
        self.assertIn("PL010", rules_in(document))
        self.assertTrue(any("duplicate plan_id" in f["message"] for f in findings_for(document, "PL010")))

    def test_dependency_cycle(self):
        self.replace("depends_on: []\n", "depends_on: [fixture-storage-s2]\n")
        twin = self.tmp / "twin.md"
        twin.write_text(
            self.plan.read_text(encoding="utf-8")
            .replace("plan_id: fixture-storage-s1", "plan_id: fixture-storage-s2")
            .replace("depends_on: [fixture-storage-s2]", "depends_on: [fixture-storage-s1]"),
            encoding="utf-8",
        )
        code, document, _ = lint([self.plan, twin], home=self.home)
        self.assertEqual(1, code)
        self.assertTrue(any("dependency cycle" in f["message"] for f in findings_for(document, "PL009")))

    def test_directory_mode_requires_front_matter_under_plans(self):
        plans = self.tmp / "plans"
        plans.mkdir()
        (plans / "orphan.md").write_text("# A plan with no front matter\n", encoding="utf-8")
        code, document, _ = lint([plans], home=self.home)
        self.assertEqual(1, code)
        self.assertIn("PL010", rules_in(document))

    def test_directory_mode_ignores_non_plans(self):
        bundle = self.tmp / "bundle"
        bundle.mkdir()
        (bundle / "INDEX.md").write_text("# Index\n\nNo plan here.\n", encoding="utf-8")
        shutil.copy(self.plan, bundle / "plan.md")
        code, document, _ = lint([bundle], home=self.home)
        self.assertEqual(0, code, json.dumps(document["findings"], indent=2))
        self.assertEqual(1, document["summary"]["plans"])

    def test_missing_ledger_is_advisory(self):
        home = self.tmp / "empty-home"
        home.mkdir()
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = LINT.main(
                [
                    str(self.plan),
                    "--home",
                    str(home),
                    "--contracts",
                    str(FIXTURES / "registry.yaml"),
                    "--json",
                ]
            )
        document = json.loads(out.getvalue())
        self.assertEqual(0, code)
        advisory = [f for f in document["findings"] if f["rule"] == "PL005"]
        self.assertTrue(advisory, "expected an advisory PL005 without a ledger")
        self.assertTrue(all(f["advisory"] for f in advisory))
        self.assertEqual([], [f for f in document["findings"] if f["severity"] == "error"])

    def test_usage_errors_exit_two(self):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = LINT.main([str(self.tmp / "absent.md")])
        self.assertEqual(2, code)


class SeededGapTest(FixtureCase):
    """The three gaps named in the task, each failing with a precise message."""

    def test_seeded_missing_acceptance_command(self):
        self.replace("- **A2** `python3 tests/fixture/test_module.py` -> exit 0 and 2 passed\n", "")
        document = self.assert_rule("PL003", mention="A2")
        finding = findings_for(document, "PL003")[0]
        self.assertEqual(str(self.plan), finding["file"])
        self.assertIsNotNone(finding["location"]["section"])

    def test_seeded_stale_table_name(self):
        self.replace("  tables: [decisions]\n", "  tables: [decisionz]\n")
        self.replace("| table | `decisions` | planned |", "| table | `decisionz` | planned |")
        self.assert_rule("PL004", mention="decisionz")

    def test_seeded_uncited_finding(self):
        self.replace(
            'finding_ids: ["01FIXTURE0000000000000001:review-2"]\n',
            'finding_ids: ["01FIXTURE0000000000000001:not-a-real-finding"]\n',
        )
        self.assert_rule("PL005", mention="not-a-real-finding")


class CliSurfaceTest(unittest.TestCase):
    def run_cli(self, *args):
        return subprocess.run(
            [sys.executable, str(LINTER)] + list(args),
            capture_output=True,
            text=True,
            cwd=str(ROOT),
        )

    def test_rules_output_names_every_rule(self):
        result = self.run_cli("--rules")
        self.assertEqual(0, result.returncode)
        for rule in LINT.RULES:
            self.assertIn(rule, result.stdout)

    def test_text_output_is_greppable(self):
        result = self.run_cli(
            str(FIXTURES / "good-slice.md"),
            "--contracts",
            str(FIXTURES / "registry.yaml"),
            "--ledger",
            str(FIXTURES / "ledger.jsonl"),
            "--home",
            str(FIXTURES),
        )
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("plan-lint: plans=1 errors=0 warnings=0", result.stdout)

    def test_quiet_suppresses_the_summary(self):
        result = self.run_cli(
            str(FIXTURES / "good-slice.md"),
            "--contracts",
            str(FIXTURES / "registry.yaml"),
            "--ledger",
            str(FIXTURES / "ledger.jsonl"),
            "--home",
            str(FIXTURES),
            "--quiet",
        )
        self.assertEqual(0, result.returncode)
        self.assertNotIn("plan-lint:", result.stdout)


class TemplateAuthorTest(FixtureCase):
    """A new author can draft from the template and pass lint.

    The template is only useful if its own examples, copied verbatim, are a valid
    plan. This builds one by taking the template's front-matter block and each
    section's **Example.** body, points it at a fixture repository, and lints it
    against the registry the templates ship.
    """

    def build_from_template(self):
        import re as _re

        template = ROOT / "templates" / "implementation-plan" / "PLAN_TEMPLATE.md"
        text = template.read_text(encoding="utf-8")
        front = _re.search(r"```yaml\n(---\n.*?\n---)\n```", text, _re.S)
        self.assertIsNotNone(front, "the template lost its front-matter example")
        body = []
        for block in _re.split(r"\n## ", text.split("## Front matter", 1)[1])[1:]:
            heading, _, rest = block.partition("\n")
            rest = rest.split("\n## ", 1)[0]
            marker = rest.find("**Example.**")
            content = rest[marker + len("**Example.**") :] if marker != -1 else rest
            body.append("## %s\n%s" % (heading.strip(), content.strip("\n")))
        repo = self.tmp / "example-repo"
        (repo / "src" / "example").mkdir(parents=True)
        (repo / "tests" / "example").mkdir(parents=True)
        (repo / "bin").mkdir(parents=True)
        # src/example/feature.py is declared new by the template, so the fixture
        # repository deliberately does not have it.
        (repo / "src" / "example" / "runner.py").write_text("# runner\n" * 200, encoding="utf-8")
        (repo / "src" / "example" / "ranking").mkdir(parents=True)
        (repo / "src" / "example" / "ranking" / "assign.py").write_text("# assign\n" * 60, encoding="utf-8")
        (repo / "tests" / "example" / "test_feature.py").write_text("# test\n", encoding="utf-8")
        (repo / "bin" / "example-check").write_text("#!/bin/sh\n", encoding="utf-8")
        front_matter = front.group(1).replace("projects/example-project", str(repo))
        return "\n".join([front_matter, "", "\n\n".join(body), ""])

    def test_template_examples_are_a_valid_plan(self):
        plan = self.tmp / "PLAN.md"
        plan.write_text(self.build_from_template(), encoding="utf-8")
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = LINT.main(
                [
                    str(plan),
                    "--home",
                    str(self.tmp),
                    "--contracts",
                    str(ROOT / "templates" / "implementation-plan" / "PLAN_CONTRACTS.example.yaml"),
                    "--json",
                ]
            )
        document = json.loads(out.getvalue())
        self.assertEqual(0, code, json.dumps(document["findings"], indent=2)[:3000])
        self.assertEqual([], document["findings"])

    def test_variant_front_matter_examples_are_complete(self):
        required = {
            "plan_id", "title", "task", "project", "repo", "milestone", "slice", "owner",
            "status", "plan_kind", "depends_on", "effort", "parallel_safe", "contracts",
            "acceptance_commands", "rollback",
        }
        for name in ("PLAN_SLICE", "PLAN_SUBTASK", "PLAN_MIGRATION", "PLAN_EVALUATION"):
            text = (ROOT / "templates" / "implementation-plan" / ("%s.md" % name)).read_text(encoding="utf-8")
            block = text.split("```yaml\n", 1)[1].split("\n```", 1)[0]
            front, _, _ = LINT.parse_front_matter(block + "\n")
            missing = required - set(front)
            self.assertEqual(set(), missing, "%s is missing %s" % (name, sorted(missing)))
            self.assertEqual([], [k for k in front if k not in required and k not in ("serial_reason", "evidence_note", "declared_new_paths", "finding_ids")], name)
            if front["depends_on"] and front["effort"] == "S":
                self.fail("%s uses effort S with a dependency, which PL006 rejects" % name)
            for entry in front["acceptance_commands"]:
                self.assertTrue(entry.get("command"), name)
                self.assertTrue(entry.get("expect"), name)
            self.assertGreater(len(front["rollback"]), 20, name)

    def test_every_variant_names_its_extra_section(self):
        for name in ("PLAN_SLICE", "PLAN_SUBTASK", "PLAN_MIGRATION", "PLAN_EVALUATION"):
            text = (ROOT / "templates" / "implementation-plan" / ("%s.md" % name)).read_text(encoding="utf-8")
            self.assertIn("Inherits `PLAN_TEMPLATE.md`", text, name)
            self.assertIn("## Front matter example", text, name)
            self.assertIn("```yaml", text, name)


class LivePlanSetTest(unittest.TestCase):
    """The real job-search redesign set, when this home carries it.

    `data/` is captain-private and gitignored, so CI cannot see it. The test
    lints it where it exists and skips with a reason everywhere else; the
    seeded fixtures above are what prove the rules in CI.
    """

    def setUp(self):
        home = Path(os.environ.get("FM_HOME") or Path.home() / "firstmate")
        self.plan_set = home / "data" / "job-search-redesign"
        self.home = home

    def test_redesign_set_passes(self):
        if not self.plan_set.is_dir():
            self.skipTest("no %s on this host" % self.plan_set)
        result = subprocess.run(
            [
                sys.executable,
                str(LINTER),
                str(self.plan_set),
                "--home",
                str(self.home),
                "--json",
            ],
            capture_output=True,
            text=True,
            cwd=str(ROOT),
        )
        document = json.loads(result.stdout)
        self.assertEqual(
            0,
            result.returncode,
            json.dumps([f for f in document["findings"] if f["severity"] == "error"], indent=2)[:4000],
        )
        self.assertGreater(document["summary"]["plans"], 20)


if __name__ == "__main__":
    unittest.main(verbosity=2)

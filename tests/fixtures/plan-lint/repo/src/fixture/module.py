"""Fixture module for plan-lint tests."""

VERDICTS = ("include", "review", "veto")


def decide(row):
    """Return the verdict for one row.

    The probability is computed here and then dropped: no caller persists it,
    which is the defect the fixture plan's current-state evidence cites.
    """
    if not row:
        return {"verdict": "veto", "p_fit": None}
    return {"verdict": "include", "p_fit": 0.5}

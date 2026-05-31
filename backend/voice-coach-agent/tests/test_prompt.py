from coach.context import CoachContext
from coach.prompt import build_system_prompt, build_opener, COACH_PERSONA


def test_system_prompt_includes_persona_and_entry_text():
    ctx = CoachContext(entry_type="text", entry_date="May 30",
                       entry_text="I keep avoiding the hard conversation.")
    p = build_system_prompt(ctx)
    assert COACH_PERSONA.strip()[:20] in p
    assert "hard conversation" in p
    assert "May 30" in p


def test_system_prompt_handles_empty_entry():
    p = build_system_prompt(CoachContext(entry_text=""))
    assert "haven't written" in p.lower() or "nothing written" in p.lower()


def test_system_prompt_notes_truncation():
    ctx = CoachContext(entry_text="partial...", truncated=True)
    assert "portion" in build_system_prompt(ctx).lower()


def test_opener_references_writing_when_present():
    ctx = CoachContext(entry_text="I keep avoiding it.")
    assert "?" in build_opener(ctx)  # opens with a question


def test_opener_is_open_ended_when_empty():
    assert "?" in build_opener(CoachContext(entry_text=""))

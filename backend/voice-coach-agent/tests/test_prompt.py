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


def test_same_prompt_builder_accepts_background_brief():
    prompt = build_system_prompt(
        CoachContext(entry_text="I keep circling the decision."),
        {"revision": 2, "recommended_next_move": "Name the feared cost."},
    )
    assert "Current silent strategist brief" in prompt
    assert "Name the feared cost" in prompt
    assert "get_coaching_brief" in prompt


def test_opener_references_writing_when_present():
    ctx = CoachContext(entry_text="I keep avoiding it.")
    assert "?" in build_opener(ctx)  # opens with a question


def test_opener_is_open_ended_when_empty():
    assert "?" in build_opener(CoachContext(entry_text=""))


def test_chat_handoff_and_selected_question_drive_the_voice_opener():
    ctx = CoachContext(
        entry_text="A current note.",
        chat_history="Julian: I want to decide.\n\nFreewrite AI: Name the cost of waiting.",
        starting_question="What does waiting cost you now?",
    )
    prompt = build_system_prompt(ctx)
    assert "continuing from this text chat" in prompt
    assert "Name the cost of waiting" in prompt
    assert build_opener(ctx) == "What does waiting cost you now?"

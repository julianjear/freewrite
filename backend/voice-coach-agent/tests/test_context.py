import json
from coach.context import parse_context, cap_entry_text, MAX_ENTRY_CHARS, CoachContext


def test_parse_valid_metadata():
    meta = json.dumps({
        "userId": "user-abc",
        "context": {
            "entryType": "text",
            "entryDate": "May 30",
            "entryText": "I keep avoiding it.",
            "hasTranscript": False,
            "chatHistory": "Julian: I am stuck.\n\nFreewrite AI: What is the choice?",
            "startingQuestion": "What would you choose without fear?",
            "truncated": False,
            "modality": "voice",
        },
    })
    ctx = parse_context(meta)
    assert isinstance(ctx, CoachContext)
    assert ctx.entry_type == "text"
    assert ctx.entry_text == "I keep avoiding it."
    assert ctx.entry_date == "May 30"
    assert "I am stuck" in ctx.chat_history
    assert ctx.starting_question == "What would you choose without fear?"


def test_parse_missing_or_bad_metadata_returns_empty():
    assert parse_context(None).entry_text == ""
    assert parse_context("{not json").entry_text == ""
    assert parse_context("{}").entry_type == "text"
    assert parse_context("[]").entry_text == ""
    assert parse_context('{"context":"not-an-object"}').entry_text == ""


def test_cap_entry_text_keeps_tail():
    long = "a" * (MAX_ENTRY_CHARS + 50) + "TAIL"
    capped, truncated = cap_entry_text(long)
    assert truncated is True
    assert capped.endswith("TAIL")
    assert len(capped) <= MAX_ENTRY_CHARS

"""Pure context parsing — no livekit import, so it unit-tests offline.

Mirrors Jungle's `meta = json.loads(participant.metadata); meta["context"]`.
"""
from __future__ import annotations

import json
from dataclasses import dataclass

# A second safety net behind the Worker's byte cap (the Worker already caps to
# ~6 KB; this guards against any oversized text reaching the prompt builder).
MAX_ENTRY_CHARS = 6000
MAX_CHAT_CHARS = 5000
MAX_QUESTION_CHARS = 1200


@dataclass
class CoachContext:
    entry_type: str = "text"
    entry_date: str = ""
    entry_text: str = ""
    has_transcript: bool = False
    chat_history: str = ""
    starting_question: str = ""
    truncated: bool = False


def cap_entry_text(text: str) -> tuple[str, bool]:
    if text is None:
        return "", False
    if len(text) <= MAX_ENTRY_CHARS:
        return text, False
    return text[-MAX_ENTRY_CHARS:], True


def parse_context(metadata: str | None) -> CoachContext:
    if not metadata:
        return CoachContext()
    try:
        meta = json.loads(metadata)
    except (json.JSONDecodeError, TypeError):
        return CoachContext()
    ctx = meta.get("context") or {}
    text, truncated = cap_entry_text(str(ctx.get("entryText") or ""))
    chat_history = str(ctx.get("chatHistory") or "")[-MAX_CHAT_CHARS:]
    starting_question = str(ctx.get("startingQuestion") or "")[:MAX_QUESTION_CHARS]
    return CoachContext(
        entry_type="video" if ctx.get("entryType") == "video" else "text",
        entry_date=str(ctx.get("entryDate") or ""),
        entry_text=text,
        has_transcript=bool(ctx.get("hasTranscript")),
        chat_history=chat_history,
        starting_question=starting_question,
        truncated=bool(ctx.get("truncated")) or truncated,
    )

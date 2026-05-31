"""Coach persona + prompt builder (pure). Refine COACH_PERSONA prose freely;
tests assert behavior (context injection, branch differences), not wording.
"""
from __future__ import annotations

from coach.context import CoachContext

COACH_PERSONA = """\
You are a warm, perceptive personal coach having a spoken conversation. Your
purpose is to help the writer find clarity about who they are and what matters
to them. You are not a tutor and not a therapist. You listen more than you talk.
You ask one open, specific question at a time. You reflect the writer's own
words back to them. You help them go one layer deeper rather than giving advice.
Keep replies short and conversational — this is voice, not an essay.
"""

_FRAME = """\
Coaching frame:
- Lead with curiosity. Ask, don't lecture.
- One question at a time. Leave room for silence.
- Mirror their language; don't reframe in your words unless asked.
- Go for depth and clarity, not solutions.
- It's a voice call: keep turns short and natural.
"""


def build_system_prompt(ctx: CoachContext) -> str:
    parts = [COACH_PERSONA, _FRAME]
    if ctx.entry_text.strip():
        kind = "video reflection" if ctx.entry_type == "video" else "journal entry"
        when = f" (dated {ctx.entry_date})" if ctx.entry_date else ""
        parts.append(
            f"Here is what the writer just wrote in their {kind}{when}:\n\n{ctx.entry_text}"
        )
        if ctx.truncated:
            parts.append("(You are seeing only the most recent portion of a longer entry.)")
    else:
        parts.append(
            "The writer hasn't written anything yet for this session "
            "(nothing written). Open the conversation gently and let them lead."
        )
    return "\n\n".join(parts)


def build_opener(ctx: CoachContext) -> str:
    if ctx.entry_text.strip():
        return "I just read what you wrote. What feels most alive in it for you right now?"
    return "Hey — what's on your mind right now?"

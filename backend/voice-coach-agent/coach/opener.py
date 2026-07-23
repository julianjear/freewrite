"""Deliver the scripted call opener for each voice architecture."""
from __future__ import annotations

from collections.abc import Awaitable, Callable
from typing import Any

from coach.config import VoiceSessionConfig

TelemetryPublish = Callable[[str, str, dict[str, Any]], Awaitable[None]]


async def deliver_opener(
    session: Any,
    config: VoiceSessionConfig,
    opener: str,
    publish: TelemetryPublish,
) -> None:
    if config.profile.architecture == "cascade":
        # Fixed opener bypasses the LLM in the cascade and reaches TTS faster.
        await session.say(opener)
    elif config.profile.provider != "google":
        # AgentSession.generate_reply returns an awaitable SpeechHandle. Waiting
        # for it keeps the job entrypoint alive until the realtime model has
        # actually generated and played the scripted greeting.
        await session.generate_reply(
            instructions=f"Open this live call now. Say exactly this and nothing else: {opener}"
        )
    else:
        # Gemini 3.1 Live explicitly ignores generate_reply and mid-session
        # client-content updates. It starts in listening mode and answers the
        # first user turn; pretending to send an opener creates a silent error.
        await publish(
            "lifecycle",
            "opener",
            {"status": "awaiting-user", "reason": "Gemini Live generate_reply limitation"},
        )

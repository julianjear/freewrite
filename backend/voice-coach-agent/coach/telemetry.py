"""Small, provider-neutral telemetry envelope sent to the macOS dev console."""
from __future__ import annotations

import dataclasses
import json
import logging
import time
import uuid
from datetime import UTC, datetime
from enum import Enum
from typing import Any

from livekit import rtc

from coach.config import VoiceSessionConfig

logger = logging.getLogger("freewrite-coach.telemetry")
TELEMETRY_TOPIC = "freewrite.voice.telemetry"

# Public list prices as of 2026-07-18. They are deliberately estimates: plan
# discounts, cached tokens, regional pricing, and provider changes can differ.
LLM_PRICES_PER_MILLION: dict[str, tuple[float, float]] = {
    "gemini-3.5-flash": (1.50, 9.00),
    "gemini-3.1-flash-lite": (0.25, 1.50),
    "gemini-3-flash-preview": (0.50, 3.00),
    "gemini-2.5-flash": (0.30, 2.50),
    "gemini-3.1-pro-preview": (2.00, 12.00),
    "gpt-5.6-terra": (2.50, 15.00),
    "claude-haiku-4-5": (1.00, 5.00),
}
REALTIME_TOKEN_PRICES: dict[str, tuple[float, float, float, float]] = {
    # text input, text output, audio input, audio output / 1M tokens
    "gpt-realtime-2.1": (4.00, 24.00, 32.00, 64.00),
    "gpt-realtime-2.1-mini": (0.60, 2.40, 10.00, 20.00),
    "gemini-3.1-flash-live-preview": (0.75, 4.50, 3.00, 12.00),
}
DEEPGRAM_PER_MINUTE = {"nova-3": 0.0058, "flux-general-en": 0.0065}
ELEVENLABS_PER_CHARACTER = 0.05 / 1000


def jsonable(value: Any) -> Any:
    if dataclasses.is_dataclass(value):
        return {k: jsonable(v) for k, v in dataclasses.asdict(value).items()}
    if hasattr(value, "model_dump"):
        return jsonable(value.model_dump())
    if isinstance(value, dict):
        return {str(k): jsonable(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [jsonable(v) for v in value]
    if isinstance(value, Enum):
        return value.value
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    return str(value)


def usage_cost_usd(usage: Any, config: VoiceSessionConfig) -> float:
    return sum(usage_cost_breakdown_usd(usage, config).values())


def usage_cost_breakdown_usd(usage: Any, config: VoiceSessionConfig) -> dict[str, float]:
    """Estimate public-list-price cost from LiveKit's measured usage units."""
    breakdown = {
        "stt": 0.0,
        "llmUncachedInput": 0.0,
        "llmCachedInput": 0.0,
        "llmOutput": 0.0,
        "tts": 0.0,
    }
    profile = config.profile
    for item in usage.model_usage:
        kind = getattr(item, "type", "")
        if kind == "stt_usage":
            model = "flux-general-en" if config.turn_strategy == "flux" else "nova-3"
            breakdown["stt"] += (item.audio_duration / 60) * DEEPGRAM_PER_MINUTE[model]
        elif kind == "tts_usage":
            breakdown["tts"] += item.characters_count * ELEVENLABS_PER_CHARACTER
        elif kind == "llm_usage" and profile.architecture == "realtime":
            if profile.provider == "xai":
                breakdown["llmOutput"] += (item.session_duration / 60) * 0.05
            elif prices := REALTIME_TOKEN_PRICES.get(profile.model):
                cached_text = getattr(item, "input_cached_text_tokens", 0)
                cached_audio = getattr(item, "input_cached_audio_tokens", 0)
                uncached_text = max(0, item.input_text_tokens - cached_text)
                uncached_audio = max(0, item.input_audio_tokens - cached_audio)
                breakdown["llmUncachedInput"] += (
                    uncached_text * prices[0] + uncached_audio * prices[2]
                ) / 1_000_000
                # OpenAI publishes a 90% cache-read discount. Other realtime
                # providers are conservatively priced at normal input rates.
                multiplier = 0.1 if profile.provider == "openai" else 1.0
                breakdown["llmCachedInput"] += (
                    cached_text * prices[0] + cached_audio * prices[2]
                ) * multiplier / 1_000_000
                breakdown["llmOutput"] += (
                    item.output_text_tokens * prices[1] + item.output_audio_tokens * prices[3]
                ) / 1_000_000
        elif kind == "llm_usage" and (prices := LLM_PRICES_PER_MILLION.get(profile.model)):
            cached = getattr(item, "input_cached_tokens", 0)
            uncached = max(0, item.input_tokens - cached)
            breakdown["llmUncachedInput"] += uncached * prices[0] / 1_000_000
            breakdown["llmCachedInput"] += cached * prices[0] * 0.1 / 1_000_000
            breakdown["llmOutput"] += item.output_tokens * prices[1] / 1_000_000
    return breakdown


class TelemetryPublisher:
    def __init__(self, room: rtc.Room, session_id: str, config: VoiceSessionConfig):
        self._room = room
        self._session_id = session_id
        self._config = config
        self._sequence = 0

    async def publish(self, event_type: str, stage: str, detail: dict[str, Any]) -> None:
        self._sequence += 1
        envelope = {
            "version": 1,
            "id": str(uuid.uuid4()),
            "sequence": self._sequence,
            "sessionId": self._session_id,
            "eventType": event_type,
            "stage": stage,
            "timestamp": datetime.now(UTC).isoformat(),
            "monotonicSeconds": time.monotonic(),
            "detail": jsonable(detail),
        }
        logger.info("telemetry %s", json.dumps(envelope, separators=(",", ":")))
        if not self._config.observability_enabled:
            return
        try:
            await self._room.local_participant.publish_data(
                json.dumps(envelope, separators=(",", ":")).encode("utf-8"),
                reliable=True,
                topic=TELEMETRY_TOPIC,
            )
        except Exception:
            # Observability must never break the call.
            logger.exception("failed to publish telemetry event type=%s", event_type)

    async def publish_usage(self, usage: Any) -> None:
        # Keep the final usage update immediately preceding disconnect so the
        # persisted after-call estimate is based on the fullest metered data.
        breakdown = usage_cost_breakdown_usd(usage, self._config)
        await self.publish(
            "metric", "session-usage",
            {
                "models": jsonable(usage.model_usage),
                "estimatedCostUSD": sum(breakdown.values()),
                "costBreakdownUSD": breakdown,
                "costKind": "cumulative",
            },
        )

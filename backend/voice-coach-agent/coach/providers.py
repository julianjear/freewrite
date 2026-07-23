"""Provider factories for cascade and native realtime voice profiles."""
from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Any

from google.genai import types as google_types
from openai.types.realtime import RealtimeReasoning
from openai.types.realtime.realtime_truncation_retention_ratio import RealtimeTruncationRetentionRatio
from livekit.agents.inference import TurnDetector
from livekit.plugins import anthropic, deepgram, elevenlabs, google, openai, silero, xai

from coach.config import VoiceSessionConfig

DEFAULT_VOICE_ID = "EST9Ui6982FZPSi7gCHi"


@dataclass(frozen=True)
class SessionComponents:
    session_kwargs: dict[str, Any]
    profile_label: str


def missing_environment(config: VoiceSessionConfig) -> list[str]:
    return [name for name in config.profile.requires_env if not os.environ.get(name)]


def _google_thinking(config: VoiceSessionConfig) -> google_types.ThinkingConfig:
    model = config.profile.model
    if model == "gemini-2.5-flash":
        budgets = {"minimal": 0, "low": 512, "medium": 2048}
        return google_types.ThinkingConfig(thinking_budget=budgets[config.reasoning_effort])
    levels = {
        "minimal": google_types.ThinkingLevel.MINIMAL,
        "low": google_types.ThinkingLevel.LOW,
        "medium": google_types.ThinkingLevel.MEDIUM,
    }
    return google_types.ThinkingConfig(thinking_level=levels[config.reasoning_effort])


def _cascade_llm(config: VoiceSessionConfig):
    profile = config.profile
    if profile.provider == "google":
        return google.LLM(
            model=profile.model,
            api_key=os.environ["GOOGLE_GEMINI_API_KEY"],
            thinking_config=_google_thinking(config),
            temperature=0.7,
            max_output_tokens=220,
        )
    if profile.provider == "openai":
        return openai.LLM(
            model=profile.model,
            api_key=os.environ["OPENAI_API_KEY"],
            reasoning_effort=config.reasoning_effort,
            verbosity="low",
            max_completion_tokens=220,
        )
    if profile.provider == "anthropic":
        return anthropic.LLM(
            model=profile.model,
            api_key=os.environ["ANTHROPIC_API_KEY"],
            temperature=0.7,
            max_tokens=220,
        )
    raise ValueError(f"unsupported cascade provider: {profile.provider}")


def _realtime_model(config: VoiceSessionConfig, instructions: str):
    profile = config.profile
    if profile.provider == "openai":
        return openai.realtime.RealtimeModel(
            model=profile.model,
            voice=os.environ.get("COACH_OPENAI_VOICE", "marin"),
            api_key=os.environ["OPENAI_API_KEY"],
            input_audio_transcription={"model": "gpt-realtime-whisper", "language": "en"},
            input_audio_noise_reduction="near_field",
            reasoning=RealtimeReasoning(effort=config.reasoning_effort),
            truncation=RealtimeTruncationRetentionRatio(
                type="retention_ratio", retention_ratio=0.8
            ),
        )
    if profile.provider == "google":
        return google.realtime.RealtimeModel(
            model=profile.model,
            instructions=instructions,
            api_key=os.environ["GOOGLE_GEMINI_API_KEY"],
            voice=os.environ.get("COACH_GEMINI_VOICE", "Puck"),
            input_audio_transcription=google_types.AudioTranscriptionConfig(),
            output_audio_transcription=google_types.AudioTranscriptionConfig(),
            context_window_compression=google_types.ContextWindowCompressionConfig(
                sliding_window=google_types.SlidingWindow()
            ),
            session_resumption=google_types.SessionResumptionConfig(transparent=True),
            thinking_config=_google_thinking(config),
        )
    if profile.provider == "xai":
        return xai.realtime.RealtimeModel(
            model=profile.model,
            voice=os.environ.get("COACH_XAI_VOICE", "Ara"),
            api_key=os.environ["XAI_API_KEY"],
        )
    raise ValueError(f"unsupported realtime provider: {profile.provider}")


def build_session_components(config: VoiceSessionConfig, instructions: str) -> SessionComponents:
    missing = missing_environment(config)
    if missing:
        raise RuntimeError("missing provider credentials: " + ", ".join(missing))

    profile = config.profile
    if profile.architecture == "realtime":
        return SessionComponents(
            session_kwargs={
                "llm": _realtime_model(config, instructions),
                "turn_handling": {"turn_detection": "realtime_llm"},
            },
            profile_label=f"{profile.provider}/{profile.model}",
        )

    if config.turn_strategy == "flux":
        stt = deepgram.STTv2(
            model="flux-general-en",
            eot_timeout_ms=7000,
            eager_eot_threshold=0.6,
            eot_threshold=0.8,
        )
        turn_detection: Any = "stt"
    else:
        stt = deepgram.STT(
            model="nova-3",
            language="multi",
            smart_format=True,
            filler_words=True,
        )
        turn_detection = TurnDetector()

    return SessionComponents(
        session_kwargs={
            "stt": stt,
            "llm": _cascade_llm(config),
            "tts": elevenlabs.TTS(
                voice_id=os.environ.get("COACH_VOICE_ID", DEFAULT_VOICE_ID),
                model="eleven_flash_v2_5",
            ),
            "vad": silero.VAD.load(),
            "turn_handling": {
                "turn_detection": turn_detection,
                "endpointing": {"min_delay": 0.3, "max_delay": 3.0},
                "interruption": {
                    "false_interruption_timeout": 1.5,
                    "resume_false_interruption": True,
                },
                # Start the LLM while endpoint confidence is settling, but do
                # not synthesize audio until the turn is confirmed.
                "preemptive_generation": {"enabled": True, "preemptive_tts": False},
            },
        },
        profile_label=(
            f"deepgram/{'flux-general-en' if config.turn_strategy == 'flux' else 'nova-3'}"
            f" -> {profile.provider}/{profile.model} -> elevenlabs/eleven_flash_v2_5"
        ),
    )

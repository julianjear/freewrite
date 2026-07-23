"""Versioned voice-session configuration shared with the app and token Worker.

The client chooses a *profile* and a small number of explicit tuning controls.
This module is the server-side authority: it rejects unknown combinations
instead of silently running a different (and misleading) benchmark.
"""
from __future__ import annotations

import json
from dataclasses import asdict, dataclass
from typing import Any, Literal

Architecture = Literal["cascade", "realtime"]
ReasoningEffort = Literal["minimal", "low", "medium"]
SupervisorEffort = Literal["low", "medium", "high", "xhigh", "max"]
TurnStrategy = Literal["livekit-audio", "flux"]


@dataclass(frozen=True)
class VoiceProfile:
    id: str
    architecture: Architecture
    provider: str
    model: str
    stt_model: str | None = None
    tts_model: str | None = None
    turn_strategy: TurnStrategy | None = None
    requires_env: tuple[str, ...] = ()
    dynamic_instructions: bool = True


PROFILES: dict[str, VoiceProfile] = {
    # Cascade: Nova-3 + LiveKit's acoustic/semantic EOT detector + Eleven Flash
    # is the production default. Only the conversational LLM changes here.
    "cascade-gemini-3.5-flash": VoiceProfile(
        "cascade-gemini-3.5-flash", "cascade", "google", "gemini-3.5-flash",
        "nova-3", "eleven_flash_v2_5", "livekit-audio",
        ("GOOGLE_GEMINI_API_KEY", "DEEPGRAM_API_KEY", "ELEVEN_API_KEY"),
    ),
    "cascade-gemini-3.1-flash-lite": VoiceProfile(
        "cascade-gemini-3.1-flash-lite", "cascade", "google", "gemini-3.1-flash-lite",
        "nova-3", "eleven_flash_v2_5", "livekit-audio",
        ("GOOGLE_GEMINI_API_KEY", "DEEPGRAM_API_KEY", "ELEVEN_API_KEY"),
    ),
    "cascade-gemini-3-flash-preview": VoiceProfile(
        "cascade-gemini-3-flash-preview", "cascade", "google", "gemini-3-flash-preview",
        "nova-3", "eleven_flash_v2_5", "livekit-audio",
        ("GOOGLE_GEMINI_API_KEY", "DEEPGRAM_API_KEY", "ELEVEN_API_KEY"),
    ),
    "cascade-gemini-2.5-flash": VoiceProfile(
        "cascade-gemini-2.5-flash", "cascade", "google", "gemini-2.5-flash",
        "nova-3", "eleven_flash_v2_5", "livekit-audio",
        ("GOOGLE_GEMINI_API_KEY", "DEEPGRAM_API_KEY", "ELEVEN_API_KEY"),
    ),
    "cascade-gpt-5.6-terra": VoiceProfile(
        "cascade-gpt-5.6-terra", "cascade", "openai", "gpt-5.6-terra",
        "nova-3", "eleven_flash_v2_5", "livekit-audio",
        ("OPENAI_API_KEY", "DEEPGRAM_API_KEY", "ELEVEN_API_KEY"),
    ),
    "cascade-claude-haiku-4.5": VoiceProfile(
        "cascade-claude-haiku-4.5", "cascade", "anthropic", "claude-haiku-4-5",
        "nova-3", "eleven_flash_v2_5", "livekit-audio",
        ("ANTHROPIC_API_KEY", "DEEPGRAM_API_KEY", "ELEVEN_API_KEY"),
    ),
    # Native speech-to-speech. Gemini currently rejects dynamic instruction/
    # history updates after its first turn, so the background brief is exposed
    # through a tool for that profile instead of pretending injection succeeded.
    "realtime-gpt-2.1": VoiceProfile(
        "realtime-gpt-2.1", "realtime", "openai", "gpt-realtime-2.1",
        requires_env=("OPENAI_API_KEY",),
    ),
    "realtime-gpt-2.1-mini": VoiceProfile(
        "realtime-gpt-2.1-mini", "realtime", "openai", "gpt-realtime-2.1-mini",
        requires_env=("OPENAI_API_KEY",),
    ),
    "realtime-gemini-3.1-flash-live-preview": VoiceProfile(
        "realtime-gemini-3.1-flash-live-preview", "realtime", "google",
        "gemini-3.1-flash-live-preview", requires_env=("GOOGLE_GEMINI_API_KEY",),
        dynamic_instructions=False,
    ),
    "realtime-grok-think-fast": VoiceProfile(
        "realtime-grok-think-fast", "realtime", "xai", "grok-voice-think-fast-1.0",
        requires_env=("XAI_API_KEY",),
    ),
}

DEFAULT_PROFILE_ID = "cascade-gemini-3.5-flash"
SUPPORTED_SUPERVISORS = {
    "gemini-3.1-pro-preview",
    "gemini-3.5-flash",
    "claude-sonnet-5",
    "claude-opus-4-8",
    "gpt-5.6-sol",
}


@dataclass(frozen=True)
class VoiceSessionConfig:
    version: int = 1
    profile_id: str = DEFAULT_PROFILE_ID
    reasoning_effort: ReasoningEffort = "low"
    supervisor_enabled: bool = True
    supervisor_model: str = "gemini-3.1-pro-preview"
    supervisor_effort: SupervisorEffort = "high"
    supervisor_interval_seconds: int = 30
    observability_enabled: bool = True
    # Advanced A/B switch. It is valid only for cascade profiles; it replaces
    # Nova + LiveKit TurnDetector with Flux's integrated EOT state machine.
    turn_strategy: TurnStrategy = "livekit-audio"

    @property
    def profile(self) -> VoiceProfile:
        return PROFILES[self.profile_id]

    def to_public_dict(self) -> dict[str, Any]:
        value = asdict(self)
        value.update(
            architecture=self.profile.architecture,
            provider=self.profile.provider,
            model=self.profile.model,
            sttModel=("flux-general-en" if self.turn_strategy == "flux" else self.profile.stt_model),
            ttsModel=self.profile.tts_model,
        )
        return value


def parse_voice_config(value: Any) -> VoiceSessionConfig:
    if not isinstance(value, dict):
        return VoiceSessionConfig()

    version = value.get("version", 1)
    if version != 1:
        raise ValueError(f"unsupported voice config version: {version}")
    profile_id = value.get("profileId", DEFAULT_PROFILE_ID)
    if profile_id not in PROFILES:
        raise ValueError(f"unsupported voice profile: {profile_id}")

    reasoning = value.get("reasoningEffort", "low")
    if reasoning not in ("minimal", "low", "medium"):
        raise ValueError(f"unsupported reasoning effort: {reasoning}")

    supervisor_model = value.get("supervisorModel", "gemini-3.1-pro-preview")
    if supervisor_model not in SUPPORTED_SUPERVISORS:
        raise ValueError(f"unsupported supervisor model: {supervisor_model}")

    supervisor_effort = value.get("supervisorEffort", "high")
    allowed_efforts = ("low", "medium", "high") if supervisor_model.startswith("gemini-") else ("low", "medium", "high", "xhigh", "max")
    if supervisor_effort not in allowed_efforts:
        raise ValueError(f"unsupported supervisor effort for {supervisor_model}: {supervisor_effort}")

    interval = value.get("supervisorIntervalSeconds", 30)
    if not isinstance(interval, int) or isinstance(interval, bool) or interval not in (15, 20, 30):
        raise ValueError("supervisor interval must be 15, 20, or 30 seconds")

    turn_strategy = value.get("turnStrategy", "livekit-audio")
    if turn_strategy not in ("livekit-audio", "flux"):
        raise ValueError(f"unsupported turn strategy: {turn_strategy}")
    if PROFILES[profile_id].architecture != "cascade" and turn_strategy != "livekit-audio":
        raise ValueError("Flux can only be used with a cascade profile")

    return VoiceSessionConfig(
        version=1,
        profile_id=profile_id,
        reasoning_effort=reasoning,
        supervisor_enabled=value.get("supervisorEnabled", True) is True,
        supervisor_model=supervisor_model,
        supervisor_effort=supervisor_effort,
        supervisor_interval_seconds=interval,
        observability_enabled=value.get("observabilityEnabled", True) is True,
        turn_strategy=turn_strategy,
    )


def parse_metadata_config(metadata: str | None) -> VoiceSessionConfig:
    """Read the versioned voice config from LiveKit participant metadata.

    Missing or non-JSON metadata remains backwards compatible with the default
    profile. Structurally valid JSON is authoritative, so malformed config
    values raise a clear error instead of silently selecting another model.
    """
    if not metadata:
        return VoiceSessionConfig()
    try:
        value = json.loads(metadata)
    except (TypeError, json.JSONDecodeError):
        return VoiceSessionConfig()
    if not isinstance(value, dict):
        raise ValueError("participant metadata must be a JSON object")

    voice_config = value.get("voiceConfig")
    if voice_config is not None and not isinstance(voice_config, dict):
        raise ValueError("voiceConfig must be a JSON object")
    return parse_voice_config(voice_config)


def rejected_metadata_config_detail(metadata: str | None) -> dict[str, Any]:
    """Return only rejected public selections, without implying a fallback."""
    try:
        value = json.loads(metadata or "")
    except (TypeError, json.JSONDecodeError):
        return {}
    if not isinstance(value, dict) or not isinstance(value.get("voiceConfig"), dict):
        return {}
    config = value["voiceConfig"]
    public_keys = (
        "version",
        "profileId",
        "reasoningEffort",
        "supervisorEnabled",
        "supervisorModel",
        "supervisorEffort",
        "supervisorIntervalSeconds",
        "turnStrategy",
    )
    return {
        f"requested{key[0].upper()}{key[1:]}": config[key]
        for key in public_keys
        if key in config and isinstance(config[key], (str, int, bool))
    }

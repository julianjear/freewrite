import re
from pathlib import Path

import pytest

from coach.config import PROFILES, VoiceSessionConfig
from coach.providers import build_session_components


@pytest.mark.parametrize("profile_id", sorted(PROFILES))
def test_every_profile_factory_constructs(monkeypatch, profile_id):
    for name in ("GOOGLE_GEMINI_API_KEY", "OPENAI_API_KEY", "ANTHROPIC_API_KEY",
                 "XAI_API_KEY", "DEEPGRAM_API_KEY", "ELEVEN_API_KEY"):
        monkeypatch.setenv(name, "test-key")
    monkeypatch.setattr("coach.providers.silero.VAD.load", lambda: object())

    components = build_session_components(
        VoiceSessionConfig(profile_id=profile_id, supervisor_enabled=False),
        "Shared test instructions",
    )

    assert components.profile_label
    assert "llm" in components.session_kwargs
    if PROFILES[profile_id].architecture == "realtime":
        assert components.session_kwargs["turn_handling"]["turn_detection"] == "realtime_llm"
    else:
        assert {"stt", "tts", "vad"} <= components.session_kwargs.keys()
        assert "turn_handling" in components.session_kwargs


def test_profile_ids_stay_identical_across_python_worker_and_app():
    repo = Path(__file__).resolve().parents[3]
    worker = (repo / "backend/voice-token-worker/src/context.ts").read_text()
    swift = (repo / "freewrite/Voice/VoiceConfiguration.swift").read_text()

    worker_ids = set(re.findall(r'^\s+"((?:cascade|realtime)-[^"]+)":\s*\[', worker, re.MULTILINE))
    swift_ids = set(re.findall(r'id:\s*"((?:cascade|realtime)-[^"]+)"', swift))

    assert worker_ids == set(PROFILES)
    assert swift_ids == set(PROFILES)

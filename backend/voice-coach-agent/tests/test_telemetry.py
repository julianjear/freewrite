from dataclasses import dataclass
from types import SimpleNamespace

import pytest

from coach.config import VoiceSessionConfig
from coach.telemetry import jsonable, usage_cost_breakdown_usd, usage_cost_usd


def usage(*items):
    return SimpleNamespace(model_usage=list(items))


def test_jsonable_converts_livekit_style_metric_dataclasses():
    @dataclass
    class Detail:
        tokens: int

    @dataclass
    class Metric:
        ttft: float
        nested: Detail

    assert jsonable(Metric(ttft=0.42, nested=Detail(tokens=3))) == {
        "ttft": 0.42,
        "nested": {"tokens": 3},
    }


def test_cascade_usage_cost_combines_stt_llm_and_tts():
    total = usage_cost_usd(
        usage(
            SimpleNamespace(type="stt_usage", audio_duration=60),
            SimpleNamespace(type="llm_usage", input_tokens=1_000_000, output_tokens=1_000_000),
            SimpleNamespace(type="tts_usage", characters_count=1_000),
        ),
        VoiceSessionConfig(),
    )
    assert total == pytest.approx(0.0058 + 1.50 + 9.00 + 0.05)


def test_realtime_usage_cost_uses_text_and_audio_token_buckets():
    total = usage_cost_usd(
        usage(SimpleNamespace(
            type="llm_usage",
            input_text_tokens=1_000_000,
            output_text_tokens=1_000_000,
            input_audio_tokens=1_000_000,
            output_audio_tokens=1_000_000,
        )),
        VoiceSessionConfig(profile_id="realtime-gpt-2.1", supervisor_enabled=False),
    )
    assert total == pytest.approx(4 + 24 + 32 + 64)


def test_cached_input_is_broken_out_and_discounted_for_openai():
    values = usage_cost_breakdown_usd(
        usage(SimpleNamespace(
            type="llm_usage",
            input_text_tokens=1_000_000,
            input_cached_text_tokens=500_000,
            input_audio_tokens=0,
            input_cached_audio_tokens=0,
            output_text_tokens=0,
            output_audio_tokens=0,
        )),
        VoiceSessionConfig(profile_id="realtime-gpt-2.1", supervisor_enabled=False),
    )
    assert values["llmUncachedInput"] == pytest.approx(2.0)
    assert values["llmCachedInput"] == pytest.approx(0.2)


def test_xai_realtime_usage_cost_is_session_minutes():
    total = usage_cost_usd(
        usage(SimpleNamespace(type="llm_usage", session_duration=120)),
        VoiceSessionConfig(profile_id="realtime-grok-think-fast", supervisor_enabled=False),
    )
    assert total == pytest.approx(0.10)

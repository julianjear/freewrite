import pytest

from coach.config import parse_voice_config
from coach.context import CoachContext
from types import SimpleNamespace

from coach.deliberation import (
    AnthropicBriefAnalyzer, CoachingBrief, DeliberationCoordinator, OpenAIBriefAnalyzer,
    _strip_json_fence,
)


class StubAnalyzer:
    async def analyze(self, transcript, previous):
        assert "I feel stuck" in transcript
        return CoachingBrief(
            summary="They feel stuck.",
            themes=["avoidance"],
            direction="Toward naming the feared consequence.",
            recommended_next_move="Ask what they believe will happen if they act.",
            candidate_questions=["What are you afraid would happen?"],
            risks=["Advice too soon"],
            confidence=0.8,
        ), {"model": "stub", "duration": 0.01, "promptTokens": 10, "outputTokens": 5}


class StubAgent:
    def __init__(self):
        self.instructions = None

    async def update_instructions(self, instructions):
        self.instructions = instructions


@pytest.mark.asyncio
async def test_background_brief_is_published_and_injected():
    events = []

    async def publish(event_type, stage, detail):
        events.append((event_type, stage, detail))

    config = parse_voice_config({"supervisorIntervalSeconds": 15})
    coordinator = DeliberationCoordinator(
        config, StubAnalyzer(), publish, CoachContext(entry_text="A journal entry")
    )
    agent = StubAgent()
    coordinator.bind_agent(agent)
    coordinator.add_message("user", "I feel stuck")
    await coordinator.analyze_now()

    assert coordinator.latest is not None
    assert coordinator.latest.revision == 1
    assert any(event[0] == "supervisor" for event in events)
    assert "Current silent strategist brief" in agent.instructions
    brief_event = next(event for event in events if event[0] == "supervisor")
    assert brief_event[2]["contextDelivery"] == "applied-to-next-response"
    assert events.index(brief_event) > next(
        index for index, event in enumerate(events) if event[1] == "supervisor-injection"
    )


@pytest.mark.asyncio
async def test_does_not_reanalyze_without_new_messages():
    calls = 0

    class CountingAnalyzer(StubAnalyzer):
        async def analyze(self, transcript, previous):
            nonlocal calls
            calls += 1
            return await super().analyze(transcript, previous)

    async def publish(*_):
        pass

    coordinator = DeliberationCoordinator(
        parse_voice_config(None), CountingAnalyzer(), publish, CoachContext()
    )
    coordinator.add_message("user", "I feel stuck")
    await coordinator.analyze_now()
    await coordinator.analyze_now()
    assert calls == 1


@pytest.mark.asyncio
async def test_back_to_back_identical_turns_reach_the_strategist():
    transcripts = []

    class CapturingAnalyzer(StubAnalyzer):
        async def analyze(self, transcript, previous):
            transcripts.append(transcript)
            return await super().analyze(transcript, previous)

    async def publish(*_):
        pass

    coordinator = DeliberationCoordinator(
        parse_voice_config(None), CapturingAnalyzer(), publish, CoachContext()
    )
    coordinator.add_message("user", "I feel stuck")
    coordinator.add_message("user", "I feel stuck")
    await coordinator.analyze_now()

    assert transcripts[0].splitlines() == [
        "user: I feel stuck",
        "user: I feel stuck",
    ]


@pytest.mark.asyncio
async def test_failed_snapshot_waits_for_a_new_turn_before_retrying():
    calls = 0
    events = []

    class FailingAnalyzer:
        async def analyze(self, transcript, previous):
            nonlocal calls
            calls += 1
            raise RuntimeError("provider unavailable")

    async def publish(*event):
        events.append(event)

    coordinator = DeliberationCoordinator(
        parse_voice_config(None), FailingAnalyzer(), publish, CoachContext()
    )
    coordinator.add_message("user", "I feel stuck")
    await coordinator.analyze_now()
    await coordinator.analyze_now()
    assert calls == 1

    coordinator.add_message("user", "There is one new thing.")
    await coordinator.analyze_now()
    assert calls == 2
    assert [event[1] for event in events] == ["supervisor", "supervisor"]


@pytest.mark.asyncio
async def test_does_not_analyze_scripted_opener_without_a_user_turn():
    calls = 0

    class CountingAnalyzer(StubAnalyzer):
        async def analyze(self, transcript, previous):
            nonlocal calls
            calls += 1
            return await super().analyze(transcript, previous)

    async def publish(*_):
        pass

    coordinator = DeliberationCoordinator(
        parse_voice_config(None), CountingAnalyzer(), publish, CoachContext()
    )
    coordinator.add_message("assistant", "What feels most alive in your writing?")
    await coordinator.analyze_now()
    assert calls == 0


@pytest.mark.asyncio
async def test_gemini_live_reports_tool_context_fallback():
    events = []

    async def publish(*event):
        events.append(event)

    config = parse_voice_config({"profileId": "realtime-gemini-3.1-flash-live-preview"})
    coordinator = DeliberationCoordinator(config, StubAnalyzer(), publish, CoachContext())
    coordinator.bind_agent(StubAgent())
    coordinator.add_message("user", "I feel stuck")
    await coordinator.analyze_now()

    brief = next(event for event in events if event[0] == "supervisor")
    assert brief[2]["contextDelivery"] == "tool-fallback"
    assert any(event[1] == "supervisor-injection" for event in events)


def _brief_json():
    return CoachingBrief(
        summary="They feel stuck.", themes=["avoidance"], direction="Name the fear.",
        recommended_next_move="Ask one grounded question.", candidate_questions=["What feels risky?"],
        risks=["Advice too soon"], confidence=0.8,
    ).model_dump_json()


@pytest.mark.parametrize("value", [
    '```json\n{"summary":"hello"}\n```',
    '```{"summary":"hello"}```',
])
def test_strip_json_fence_handles_multiline_and_single_line_blocks(value):
    assert _strip_json_fence(value) == '{"summary":"hello"}'


@pytest.mark.asyncio
async def test_anthropic_adapter_uses_adaptive_thinking_and_structured_output():
    captured = {}

    async def create(**kwargs):
        captured.update(kwargs)
        return SimpleNamespace(
            content=[SimpleNamespace(type="text", text=_brief_json())],
            usage=SimpleNamespace(input_tokens=12, output_tokens=8),
        )

    client = SimpleNamespace(messages=SimpleNamespace(create=create))
    brief, metrics = await AnthropicBriefAnalyzer("claude-opus-4-8", "x", "max", client).analyze("user: hi", None)
    assert brief.confidence == 0.8
    assert captured["thinking"] == {"type": "adaptive", "display": "omitted"}
    assert captured["output_config"]["effort"] == "max"
    assert captured["output_config"]["format"]["type"] == "json_schema"
    assert metrics["provider"] == "anthropic"


@pytest.mark.asyncio
async def test_openai_adapter_uses_selected_reasoning_effort_and_schema():
    captured = {}
    expected = CoachingBrief.model_validate_json(_brief_json())

    async def parse(**kwargs):
        captured.update(kwargs)
        return SimpleNamespace(
            output_parsed=expected,
            usage=SimpleNamespace(input_tokens=15, output_tokens=9),
        )

    client = SimpleNamespace(responses=SimpleNamespace(parse=parse))
    brief, metrics = await OpenAIBriefAnalyzer("gpt-5.6-sol", "x", "xhigh", client).analyze("user: hi", None)
    assert brief.summary == expected.summary
    assert captured["reasoning"] == {"effort": "xhigh", "summary": "auto"}
    assert captured["text_format"] is CoachingBrief
    assert metrics["provider"] == "openai"

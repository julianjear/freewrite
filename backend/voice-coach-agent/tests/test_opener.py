import pytest

from coach.config import VoiceSessionConfig
from coach.opener import deliver_opener


class ReplyHandle:
    def __init__(self):
        self.awaited = False

    def __await__(self):
        async def wait():
            self.awaited = True
            return self

        return wait().__await__()


class Session:
    def __init__(self):
        self.handle = ReplyHandle()
        self.instructions = None
        self.spoken = None

    def generate_reply(self, *, instructions):
        self.instructions = instructions
        return self.handle

    async def say(self, text):
        self.spoken = text


@pytest.mark.asyncio
async def test_realtime_opener_waits_for_generated_speech():
    session = Session()
    events = []

    async def publish(*event):
        events.append(event)

    await deliver_opener(
        session,
        VoiceSessionConfig(profile_id="realtime-gpt-2.1", supervisor_enabled=False),
        "Hello Julian.",
        publish,
    )

    assert session.handle.awaited is True
    assert session.instructions == (
        "Open this live call now. Say exactly this and nothing else: Hello Julian."
    )
    assert events == []


@pytest.mark.asyncio
async def test_cascade_opener_uses_direct_speech():
    session = Session()

    async def publish(*_):
        raise AssertionError("cascade opener should not publish a fallback event")

    await deliver_opener(
        session,
        VoiceSessionConfig(profile_id="cascade-gemini-3.5-flash"),
        "Hello Julian.",
        publish,
    )

    assert session.spoken == "Hello Julian."
    assert session.instructions is None


@pytest.mark.asyncio
async def test_gemini_live_opener_reports_awaiting_user():
    session = Session()
    events = []

    async def publish(*event):
        events.append(event)

    await deliver_opener(
        session,
        VoiceSessionConfig(
            profile_id="realtime-gemini-3.1-flash-live-preview",
            supervisor_enabled=False,
        ),
        "Hello Julian.",
        publish,
    )

    assert session.instructions is None
    assert events == [
        (
            "lifecycle",
            "opener",
            {
                "status": "awaiting-user",
                "reason": "Gemini Live generate_reply limitation",
            },
        )
    ]

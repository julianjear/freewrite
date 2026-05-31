"""Freewrite Voice Coach — LiveKit agent entrypoint.

Thin glue over the unit-tested `coach/` package. Mirrors Jungle's read pattern:
reads the per-session context the Cloudflare Worker put in the JWT metadata,
builds the coach system prompt, and runs the Deepgram->LLM->ElevenLabs loop.
"""
from __future__ import annotations

import logging
import os

from dotenv import load_dotenv
from livekit import agents
from livekit.agents import Agent, AgentSession, JobContext, WorkerOptions
from livekit.plugins import deepgram, elevenlabs, silero
from livekit.plugins.turn_detector.multilingual import MultilingualModel

from coach.context import parse_context
from coach.prompt import build_system_prompt, build_opener

load_dotenv()
logger = logging.getLogger("freewrite-coach")

AGENT_NAME = os.environ.get("COACH_AGENT_NAME", "freewrite-coach")


def _build_llm():
    """Spec section 5.4. DEFAULT = Option 2: Gemini via Cloudflare AI Gateway
    (OpenAI-compatible base_url) so voice LLM spend is observable in Cloudflare.

    Switch options by editing this function only:
      - Option 1 (native Gemini):   from livekit.plugins import google
                                     return google.LLM(model=os.environ["GEMINI_MODEL"])
      - Option 3 (Claude via CF):    model="anthropic/claude-...."
    """
    from livekit.plugins import openai

    return openai.LLM(
        model=os.environ.get("COACH_LLM_MODEL", "google-ai-studio/gemini-2.5-flash"),
        base_url=os.environ["CF_AI_GATEWAY_URL"],  # .../v1/<acct>/<gateway>/compat
        api_key=os.environ["CF_AI_GATEWAY_KEY"],
    )


async def entrypoint(ctx: JobContext) -> None:
    await ctx.connect()
    participant = await ctx.wait_for_participant()

    coach_ctx = parse_context(participant.metadata)
    system_prompt = build_system_prompt(coach_ctx)
    opener = build_opener(coach_ctx)
    logger.info(
        "coach session room=%s entry_type=%s has_text=%s",
        ctx.room.name,
        coach_ctx.entry_type,
        bool(coach_ctx.entry_text),
    )

    session = AgentSession(
        stt=deepgram.STT(model="nova-3", language="multi"),
        llm=_build_llm(),
        tts=elevenlabs.TTS(),
        vad=silero.VAD.load(),
        turn_detection=MultilingualModel(),
    )

    await session.start(agent=Agent(instructions=system_prompt), room=ctx.room)
    await session.generate_reply(
        instructions=f"Greet the writer. Say exactly: {opener}"
    )


def _request_fnc(req: agents.JobRequest):
    # Only serve rooms we minted (defensive, mirrors Jungle).
    if req.room and req.room.name and req.room.name.startswith("freewrite-"):
        return req.accept(name=AGENT_NAME)
    return req.reject()


if __name__ == "__main__":
    agents.cli.run_app(
        WorkerOptions(
            entrypoint_fnc=entrypoint,
            agent_name=AGENT_NAME,
            request_fnc=_request_fnc,
        )
    )

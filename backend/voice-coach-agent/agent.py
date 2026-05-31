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
from livekit.plugins import deepgram, elevenlabs, google, silero
from livekit.plugins.turn_detector.multilingual import MultilingualModel

from coach.context import parse_context
from coach.prompt import build_system_prompt, build_opener

load_dotenv()
logger = logging.getLogger("freewrite-coach")

AGENT_NAME = os.environ.get("COACH_AGENT_NAME", "freewrite-coach")

# ElevenLabs voice for the coach. Single source of truth — change here.
# (The elevenlabs plugin reads the API key from ELEVEN_API_KEY — note the
# ELEVEN_ prefix, NOT ELEVENLABS_; this trips people up.)
VOICE_ID = os.environ.get("COACH_VOICE_ID", "EST9Ui6982FZPSi7gCHi")


def _build_llm():
    """Native Gemini — same stack as Jungle (spec section 5.4, Option 1).

    Reads GOOGLE_GEMINI_API_KEY (Gemini Developer API key). The model defaults
    to gemini-2.5-flash and can be overridden per-deploy via COACH_LLM_MODEL.

    Future: to route through Cloudflare AI Gateway for cost observability, swap
    this to `openai.LLM(base_url=<CF gateway>/compat, api_key=<CF key>)`.
    """
    return google.LLM(
        model=os.environ.get("COACH_LLM_MODEL", "gemini-2.5-flash"),
        api_key=os.environ["GOOGLE_GEMINI_API_KEY"],
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
        tts=elevenlabs.TTS(voice_id=VOICE_ID),
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

"""Freewrite Voice Coach — configurable LiveKit voice-agent entrypoint."""
from __future__ import annotations

import asyncio
import logging
import os

from dotenv import load_dotenv
from livekit import agents
from livekit.agents import Agent, AgentSession, JobContext, WorkerOptions
from livekit.agents.llm import ChatMessage

from coach.config import VoiceSessionConfig, parse_metadata_config
from coach.artifacts import VoiceArtifactPublisher
from coach.context import parse_context
from coach.deliberation import DeliberationCoordinator, create_brief_analyzer
from coach.opener import deliver_opener
from coach.prompt import build_opener, build_system_prompt
from coach.providers import build_session_components
from coach.telemetry import TelemetryPublisher

load_dotenv()
logger = logging.getLogger("freewrite-coach")
AGENT_NAME = os.environ.get("COACH_AGENT_NAME", "freewrite-coach")


async def entrypoint(ctx: JobContext) -> None:
    await ctx.connect()
    participant = await ctx.wait_for_participant()

    try:
        config = parse_metadata_config(participant.metadata)
    except (TypeError, ValueError) as exc:
        config = VoiceSessionConfig()
        telemetry = TelemetryPublisher(ctx.room, ctx.room.name, config)
        logger.exception("invalid voice configuration")
        await telemetry.publish(
            "error",
            "configuration",
            {
                "message": str(exc),
                "profileId": config.profile_id,
                "supervisorModel": config.supervisor_model,
            },
        )
        # Keep the participant alive briefly so the reliable packet can reach
        # the app before this failed job tears down.
        await asyncio.sleep(0.25)
        raise
    coach_ctx = parse_context(participant.metadata)
    system_prompt = build_system_prompt(coach_ctx)
    telemetry = TelemetryPublisher(ctx.room, ctx.room.name, config)

    analyzer = None
    try:
        components = build_session_components(config, system_prompt)
        if config.supervisor_enabled:
            analyzer = create_brief_analyzer(config)
    except Exception as exc:
        logger.exception("coach configuration failed")
        await telemetry.publish(
            "error", "configuration",
            {"message": str(exc), "profileId": config.profile_id, "supervisorModel": config.supervisor_model},
        )
        # Give the reliable data packet a bounded opportunity to leave before
        # the failed job tears down its RTC participant.
        await asyncio.sleep(0.25)
        raise
    coordinator = DeliberationCoordinator(
        config=config,
        analyzer=analyzer,
        publish=telemetry.publish,
        base_context=coach_ctx,
    )
    artifacts = VoiceArtifactPublisher(ctx.room, ctx.room.name, telemetry.publish)
    coach_agent = Agent(
        instructions=system_prompt,
        tools=[coordinator.tool(), artifacts.image_search_tool()],
    )
    coordinator.bind_agent(coach_agent)

    session = AgentSession(**components.session_kwargs)

    @session.on("session_usage_updated")
    def _on_usage(event) -> None:
        asyncio.create_task(telemetry.publish_usage(event.usage))

    @session.on("conversation_item_added")
    def _on_conversation_item(event) -> None:
        item = event.item
        if not isinstance(item, ChatMessage):
            return
        text = item.text_content or item.raw_text_content
        if not text:
            return
        coordinator.add_message(str(item.role), text)
        asyncio.create_task(
            telemetry.publish(
                "transcript", "conversation",
                {"role": str(item.role), "text": text, "interrupted": item.interrupted},
            )
        )
        if item.metrics:
            asyncio.create_task(
                telemetry.publish(
                    "metric", "turn-latency",
                    {"role": str(item.role), **dict(item.metrics)},
                )
            )

    @session.on("eot_prediction")
    def _on_eot(event) -> None:
        asyncio.create_task(
            telemetry.publish(
                "turn", "eot-prediction",
                {
                    "probability": event.probability,
                    "threshold": event.threshold,
                    "inferenceDuration": event.inference_duration,
                    "delay": event.delay,
                },
            )
        )

    @session.on("error")
    def _on_error(event) -> None:
        asyncio.create_task(
            telemetry.publish(
                "error", "agent-session",
                {
                    "message": str(event.error),
                    "source": type(event.source).__name__,
                    "recoverable": bool(getattr(event.error, "recoverable", False)),
                },
            )
        )

    async def _shutdown() -> None:
        await coordinator.stop()
        # LiveKit invokes shutdown callbacks after the RTC engine can already be
        # closed. Publishing here creates a false observability error; the
        # session-close reason remains available in LiveKit's durable report.

    ctx.add_shutdown_callback(_shutdown)

    logger.info(
        "coach session room=%s profile=%s pipeline=%s entry_type=%s has_text=%s",
        ctx.room.name,
        config.profile_id,
        components.profile_label,
        coach_ctx.entry_type,
        bool(coach_ctx.entry_text),
    )

    await session.start(agent=coach_agent, room=ctx.room)
    await telemetry.publish(
        "config", "session",
        {**config.to_public_dict(), "pipelineLabel": components.profile_label},
    )
    await telemetry.publish("lifecycle", "session", {"status": "ready"})
    coordinator.start()

    await deliver_opener(session, config, build_opener(coach_ctx), telemetry.publish)


def _request_fnc(req: agents.JobRequest):
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

"""Background strategic reflection that never blocks the conversational model."""
from __future__ import annotations

import asyncio
import json
import logging
import os
from collections.abc import Awaitable, Callable
from datetime import UTC, datetime
from typing import Any

from google import genai
from google.genai import types
from anthropic import AsyncAnthropic
from openai import AsyncOpenAI
from livekit.agents import Agent, llm
from pydantic import BaseModel, Field

from coach.config import VoiceSessionConfig
from coach.prompt import build_system_prompt

logger = logging.getLogger("freewrite-coach.deliberation")


class CoachingBrief(BaseModel):
    revision: int = 0
    generated_at: str = ""
    summary: str = Field(description="One concise sentence about where the conversation is now")
    themes: list[str] = Field(max_length=5)
    direction: str = Field(description="Likely direction or unresolved tension")
    recommended_next_move: str = Field(description="One specific conversational move")
    candidate_questions: list[str] = Field(max_length=3)
    risks: list[str] = Field(max_length=3, description="Ways the fast coach could mishandle this moment")
    confidence: float = Field(ge=0, le=1)


SUPERVISOR_INSTRUCTIONS = """\
You are a silent senior conversation strategist advising a live voice coach.
Analyze the dialogue's trajectory, emotional subtext, contradictions, and the
single highest-leverage next move. Return only the requested structured brief.
Do not produce hidden chain-of-thought. Do not write a response to the person.
Prefer a grounded recommendation based on their exact words. Flag uncertainty.
"""


class GeminiBriefAnalyzer:
    def __init__(self, model: str, api_key: str, effort: str = "high"):
        self.model = model
        self.effort = effort
        self._client = genai.Client(api_key=api_key)

    async def analyze(self, transcript: str, previous: CoachingBrief | None) -> tuple[CoachingBrief, dict[str, Any]]:
        prompt = "Conversation so far:\n\n" + transcript[-14_000:]
        if previous:
            prompt += "\n\nPrevious brief (update it; do not merely repeat it):\n" + previous.model_dump_json()
        started = asyncio.get_running_loop().time()
        response = await self._client.aio.models.generate_content(
            model=self.model,
            contents=prompt,
            config=types.GenerateContentConfig(
                system_instruction=SUPERVISOR_INSTRUCTIONS,
                response_mime_type="application/json",
                response_schema=CoachingBrief,
                thinking_config=types.ThinkingConfig(
                    thinking_level=getattr(types.ThinkingLevel, self.effort.upper())
                ),
                temperature=0.35,
                # Gemini counts internal thinking against this ceiling. A small
                # cap can spend the whole budget deliberating and truncate the
                # JSON before it reaches the first real field.
                max_output_tokens=4096,
            ),
        )
        duration = asyncio.get_running_loop().time() - started
        if response.parsed:
            brief = response.parsed
        else:
            brief = CoachingBrief.model_validate_json(response.text or "{}")
        usage = getattr(response, "usage_metadata", None)
        metrics = {
            "model": self.model,
            "provider": "google",
            "effort": self.effort,
            "duration": duration,
            "promptTokens": getattr(usage, "prompt_token_count", 0) or 0,
            "outputTokens": getattr(usage, "candidates_token_count", 0) or 0,
            "thoughtsTokens": getattr(usage, "thoughts_token_count", 0) or 0,
        }
        return brief, metrics


class AnthropicBriefAnalyzer:
    def __init__(self, model: str, api_key: str, effort: str, client: Any | None = None):
        self.model = model
        self.effort = effort
        self._client = client or AsyncAnthropic(api_key=api_key)

    async def analyze(self, transcript: str, previous: CoachingBrief | None) -> tuple[CoachingBrief, dict[str, Any]]:
        prompt = _analysis_prompt(transcript, previous)
        started = asyncio.get_running_loop().time()
        response = await self._client.messages.create(
            model=self.model,
            max_tokens=4096,
            system=SUPERVISOR_INSTRUCTIONS,
            messages=[{"role": "user", "content": prompt}],
            thinking={"type": "adaptive", "display": "omitted"},
            output_config={
                "effort": self.effort,
                "format": {
                    "type": "json_schema",
                    "schema": CoachingBrief.model_json_schema(),
                },
            },
        )
        duration = asyncio.get_running_loop().time() - started
        text = "".join(block.text for block in response.content if getattr(block, "type", None) == "text")
        brief = CoachingBrief.model_validate_json(_strip_json_fence(text))
        return brief, {
            "model": self.model, "provider": "anthropic", "effort": self.effort,
            "duration": duration,
            "promptTokens": getattr(response.usage, "input_tokens", 0) or 0,
            "outputTokens": getattr(response.usage, "output_tokens", 0) or 0,
            "thoughtsTokens": 0,
        }


class OpenAIBriefAnalyzer:
    def __init__(self, model: str, api_key: str, effort: str, client: Any | None = None):
        self.model = model
        self.effort = effort
        self._client = client or AsyncOpenAI(api_key=api_key)

    async def analyze(self, transcript: str, previous: CoachingBrief | None) -> tuple[CoachingBrief, dict[str, Any]]:
        started = asyncio.get_running_loop().time()
        response = await self._client.responses.parse(
            model=self.model,
            instructions=SUPERVISOR_INSTRUCTIONS,
            input=_analysis_prompt(transcript, previous),
            reasoning={"effort": self.effort, "summary": "auto"},
            text_format=CoachingBrief,
            max_output_tokens=4096,
            store=False,
        )
        duration = asyncio.get_running_loop().time() - started
        if response.output_parsed is None:
            raise ValueError("OpenAI strategist returned no structured coaching brief")
        usage = response.usage
        return response.output_parsed, {
            "model": self.model, "provider": "openai", "effort": self.effort,
            "duration": duration,
            "promptTokens": getattr(usage, "input_tokens", 0) or 0,
            "outputTokens": getattr(usage, "output_tokens", 0) or 0,
            "thoughtsTokens": 0,
        }


def _analysis_prompt(transcript: str, previous: CoachingBrief | None) -> str:
    prompt = "Conversation so far:\n\n" + transcript[-14_000:]
    if previous:
        prompt += "\n\nPrevious brief (update it; do not merely repeat it):\n" + previous.model_dump_json()
    return prompt


def _strip_json_fence(value: str) -> str:
    value = value.strip()
    if value.startswith("```"):
        value = value[3:]
        if value.lower().startswith("json"):
            value = value[4:]
        if value.endswith("```"):
            value = value[:-3]
    return value.strip()


def create_brief_analyzer(config: VoiceSessionConfig) -> Any:
    model, effort = config.supervisor_model, config.supervisor_effort
    if model.startswith("gemini-"):
        key = os.environ.get("GOOGLE_GEMINI_API_KEY")
        if not key: raise RuntimeError("GOOGLE_GEMINI_API_KEY is required for the selected strategist")
        return GeminiBriefAnalyzer(model, key, effort)
    if model.startswith("claude-"):
        key = os.environ.get("ANTHROPIC_API_KEY")
        if not key: raise RuntimeError("ANTHROPIC_API_KEY is required for the selected strategist")
        return AnthropicBriefAnalyzer(model, key, effort)
    if model.startswith("gpt-"):
        key = os.environ.get("OPENAI_API_KEY")
        if not key: raise RuntimeError("OPENAI_API_KEY is required for the selected strategist")
        return OpenAIBriefAnalyzer(model, key, effort)
    raise ValueError(f"unsupported strategist model: {model}")


Publish = Callable[[str, str, dict[str, Any]], Awaitable[None]]


class DeliberationCoordinator:
    def __init__(
        self,
        config: VoiceSessionConfig,
        analyzer: Any | None,
        publish: Publish,
        base_context: Any,
    ):
        self.config = config
        self.analyzer = analyzer
        self.publish = publish
        self.base_context = base_context
        self.latest: CoachingBrief | None = None
        self._messages: list[tuple[str, str]] = []
        self._revision = 0
        self._analyzed_message_count = 0
        self._task: asyncio.Task[None] | None = None
        self._agent: Agent | None = None
        self._dynamic_updates_enabled = config.profile.dynamic_instructions

    def bind_agent(self, agent: Agent) -> None:
        self._agent = agent

    def add_message(self, role: str, text: str) -> None:
        text = text.strip()
        if text and (not self._messages or self._messages[-1] != (role, text)):
            self._messages.append((role, text))

    def start(self) -> None:
        if self.config.supervisor_enabled and self.analyzer and not self._task:
            self._task = asyncio.create_task(self._run(), name="freewrite-deliberation")

    async def stop(self) -> None:
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
            self._task = None

    async def analyze_now(self) -> None:
        if not self.analyzer or len(self._messages) == self._analyzed_message_count:
            return
        # Do not spend a slow-model call analyzing only the scripted opener.
        # The strategist exists to react to the person's conversation, so wait
        # until at least one genuine user turn is present.
        if not any(role.lower().endswith("user") for role, _ in self._messages):
            return
        # Capture the boundary before a slow provider call. A turn arriving
        # during analysis must remain eligible for the next interval.
        message_count = len(self._messages)
        transcript = "\n".join(
            f"{role}: {text}" for role, text in self._messages[:message_count]
        )
        try:
            brief, metrics = await self.analyzer.analyze(transcript, self.latest)
            self._revision += 1
            brief.revision = self._revision
            brief.generated_at = datetime.now(UTC).isoformat()
            self.latest = brief
            self._analyzed_message_count = message_count
            delivery = await self._inject_brief()
            payload = brief.model_dump()
            payload["metrics"] = metrics
            input_price, output_price = {
                "gemini-3.1-pro-preview": (2.00, 12.00),
                "gemini-3.5-flash": (1.50, 9.00),
                "claude-sonnet-5": (3.00, 15.00),
                "claude-opus-4-8": (5.00, 25.00),
                "gpt-5.6-sol": (5.00, 30.00),
            }[self.config.supervisor_model]
            payload["estimatedCostUSD"] = (
                metrics.get("promptTokens", 0) * input_price
                + (metrics.get("outputTokens", 0) + metrics.get("thoughtsTokens", 0)) * output_price
            ) / 1_000_000
            payload["costKind"] = "event"
            payload.update(
                model=self.config.supervisor_model,
                provider=metrics.get("provider", "unknown"),
                effort=self.config.supervisor_effort,
                analysisDuration=metrics.get("duration", 0),
                contextDelivery=delivery["status"],
                contextDeliveryDetail=delivery,
            )
            await self.publish("supervisor", "brief", payload)
        except Exception as exc:
            # Do not bill/re-log the same failed transcript forever. A newly
            # appended conversation turn makes the next interval eligible.
            self._analyzed_message_count = message_count
            logger.exception("background deliberation failed")
            await self.publish("error", "supervisor", {"message": str(exc)})

    async def _inject_brief(self) -> dict[str, Any]:
        if not self.latest or not self._agent:
            return {"status": "not-ready"}
        if not self._dynamic_updates_enabled:
            detail = {
                "status": "tool-fallback", "revision": self.latest.revision,
                "reason": "provider does not support reliable mid-session instruction updates",
                "tool": "get_coaching_brief",
            }
            await self.publish("lifecycle", "supervisor-injection", detail)
            return detail
        try:
            await self._agent.update_instructions(
                build_system_prompt(self.base_context, self.latest.model_dump())
            )
            detail = {"status": "applied-to-next-response", "revision": self.latest.revision}
            await self.publish("lifecycle", "supervisor-injection", detail)
            return detail
        except Exception as exc:
            # Some realtime providers (notably Gemini Live after turn one) do
            # not support instruction updates. Disable retries; the tool below
            # remains the provider-neutral fallback.
            self._dynamic_updates_enabled = False
            await self.publish(
                "error", "supervisor-injection",
                {"message": str(exc), "fallback": "get_coaching_brief tool"},
            )
            return {"status": "tool-fallback", "revision": self.latest.revision, "reason": str(exc)}

    async def _run(self) -> None:
        while True:
            await asyncio.sleep(self.config.supervisor_interval_seconds)
            await self.analyze_now()

    def tool(self):
        @llm.function_tool(
            name="get_coaching_brief",
            description=(
                "Read the silent senior strategist's latest brief before making a deeper "
                "interpretation or changing conversational direction. Do not call for every short reply."
            ),
        )
        async def get_coaching_brief() -> str:
            if not self.latest:
                return json.dumps({"status": "not_ready", "guidance": "Stay present and keep listening."})
            return self.latest.model_dump_json()

        return get_coaching_brief

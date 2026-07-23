"""Out-of-band visual artifacts for the live voice canvas."""
from __future__ import annotations

import asyncio
import json
import urllib.parse
import urllib.request
import uuid
from collections.abc import Awaitable, Callable
from typing import Any

from livekit.agents import llm

ARTIFACT_TOPIC = "freewrite.voice.artifact"


def _search_wikimedia(query: str) -> dict[str, str] | None:
    params = urllib.parse.urlencode({"q": query, "limit": "12"})
    request = urllib.request.Request(
        f"https://api.wikimedia.org/core/v1/commons/search/page?{params}",
        headers={
            "User-Agent": "FreewriteVoice/1.0",
            "Accept": "application/json",
        },
    )
    with urllib.request.urlopen(request, timeout=12) as response:
        payload = json.loads(response.read(96 * 1024))
    for page in payload.get("pages") or []:
        key = str(page.get("key") or "")
        thumbnail = str((page.get("thumbnail") or {}).get("url") or "")
        if not key.startswith("File:") or not thumbnail:
            continue
        if not key.lower().endswith((".jpg", ".jpeg", ".png", ".webp", ".gif")):
            continue
        larger = thumbnail.replace("/60px-", "/900px-")
        source = "https://commons.wikimedia.org/wiki/" + urllib.parse.quote(
            key.replace(" ", "_")
        )
        return {
            "title": str(page.get("title") or key).removeprefix("File:"),
            "imageUrl": larger,
            "thumbnailUrl": larger,
            "sourceUrl": source,
        }
    return None


class VoiceArtifactPublisher:
    def __init__(
        self,
        room: Any,
        session_id: str,
        publish_telemetry: Callable[[str, str, dict[str, Any]], Awaitable[None]],
    ) -> None:
        self._room = room
        self._session_id = session_id
        self._publish_telemetry = publish_telemetry

    async def _publish(self, artifact: dict[str, Any]) -> None:
        envelope = {
            "version": 1,
            "sessionId": self._session_id,
            "id": f"artifact-{uuid.uuid4()}",
            **artifact,
        }
        await self._room.local_participant.publish_data(
            json.dumps(envelope, separators=(",", ":")).encode("utf-8"),
            reliable=True,
            topic=ARTIFACT_TOPIC,
        )

    def image_search_tool(self):
        @llm.function_tool(
            name="image_search",
            description=(
                "Search for and show one useful public reference image on the person's "
                "voice canvas. Use only when a visual materially helps the live reflection."
            ),
        )
        async def image_search(query: str) -> str:
            clean = query.strip()[:240]
            if not clean:
                return json.dumps({"status": "error", "message": "query is required"})
            started = asyncio.get_running_loop().time()
            try:
                image = await asyncio.to_thread(_search_wikimedia, clean)
                elapsed = asyncio.get_running_loop().time() - started
                if not image:
                    await self._publish_telemetry(
                        "tool", "image_search",
                        {"status": "empty", "query": clean, "duration": elapsed},
                    )
                    return json.dumps({"status": "empty", "query": clean})
                await self._publish({"kind": "image", "image": image})
                await self._publish_telemetry(
                    "tool", "image_search",
                    {
                        "status": "success", "query": clean,
                        "title": image["title"], "duration": elapsed,
                        "artifactPublished": True,
                    },
                )
                return json.dumps({
                    "status": "shown_on_canvas",
                    "title": image["title"],
                    "source": "Wikimedia Commons",
                })
            except Exception as exc:
                await self._publish_telemetry(
                    "tool", "image_search",
                    {"status": "error", "query": clean, "message": str(exc)[:240]},
                )
                return json.dumps({"status": "error", "message": "image search failed"})

        return image_search

"""Headless end-to-end probe for the freewrite-coach voice pipeline.

Simulates the macOS app without any human or audio hardware:
  1. Mints a LiveKit token locally (same metadata shape the Cloudflare Worker
     embeds, same `freewrite-` room prefix, same explicit agent dispatch).
  2. Joins the room and publishes a (near-silent) mic track like the app does.
  3. Waits for the coach agent to join, watches `lk.agent.state`, subscribes to
     the agent's audio, and measures RMS energy of what it says.
  4. Prints received transcription text if the agent streams any.

PASS = agent joined AND spoke audibly (peak RMS above threshold).
Exit codes: 0 pass, 1 agent never joined, 2 joined but no audio track,
3 audio track but silent, 4 setup error.

Run:  ./.venv/bin/python tools/e2e_probe.py
"""
from __future__ import annotations

import asyncio
import json
import os
import sys
import time

import numpy as np
from dotenv import load_dotenv
from livekit import api, rtc

AGENT_NAME = "freewrite-coach"
SAMPLE_RATE = 48_000
JOIN_TIMEOUT = 20        # s for the agent participant to appear
AUDIO_TIMEOUT = 25       # s for the agent's audio track after join
LISTEN_SECONDS = 12      # how long we record agent audio for RMS
SPEECH_RMS_THRESHOLD = 200  # int16 RMS; real TTS speech peaks in the thousands

ENTRY_TEXT = (
    "I keep circling the same question in my journal: whether to keep my job "
    "or go all in on my own product. Today I wrote that I feel most alive on "
    "the days I build my own thing."
)


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def mint_token(room_name: str) -> str:
    metadata = json.dumps({
        "userId": "e2e-probe",
        "context": {
            "entryType": "text",
            "entryDate": "Jul 9",
            "entryText": ENTRY_TEXT,
            "hasTranscript": False,
            "truncated": False,
            "modality": "voice",
        },
    })
    return (
        api.AccessToken(os.environ["LIVEKIT_API_KEY"], os.environ["LIVEKIT_API_SECRET"])
        .with_identity("e2e-probe")
        .with_name("E2E Probe")
        .with_metadata(metadata)
        .with_grants(api.VideoGrants(
            room_join=True, room=room_name,
            can_publish=True, can_subscribe=True, can_publish_data=True,
        ))
        .with_room_config(api.RoomConfiguration(
            agents=[api.RoomAgentDispatch(agent_name=AGENT_NAME)],
        ))
        .to_jwt()
    )


async def main() -> int:
    load_dotenv(os.path.join(os.path.dirname(__file__), "..", ".env"))
    url = os.environ["LIVEKIT_URL"]
    room_name = f"freewrite-e2e-probe-{int(time.time())}"
    log(f"room={room_name} url={url}")

    room = rtc.Room()
    agent_joined = asyncio.Event()
    agent_audio: asyncio.Queue[rtc.AudioStream] = asyncio.Queue()
    states: list[str] = []
    transcripts: list[str] = []

    @room.on("participant_connected")
    def _on_participant(p: rtc.RemoteParticipant) -> None:
        log(f"participant joined: identity={p.identity} kind={p.kind}")
        if p.identity.startswith("agent") or p.kind == rtc.ParticipantKind.PARTICIPANT_KIND_AGENT:
            agent_joined.set()

    @room.on("participant_attributes_changed")
    def _on_attrs(changed: dict, p: rtc.Participant) -> None:
        if "lk.agent.state" in changed:
            states.append(changed["lk.agent.state"])
            log(f"lk.agent.state -> {changed['lk.agent.state']}")

    @room.on("track_subscribed")
    def _on_track(track: rtc.Track, pub: rtc.RemoteTrackPublication, p: rtc.RemoteParticipant) -> None:
        log(f"track subscribed: kind={track.kind} from {p.identity}")
        if track.kind == rtc.TrackKind.KIND_AUDIO:
            agent_audio.put_nowait(rtc.AudioStream(track))

    def _on_transcript(reader, participant_identity):
        async def read():
            text = await reader.read_all()
            if text.strip():
                transcripts.append(text.strip())
                log(f"transcript[{participant_identity}]: {text.strip()[:120]}")
        asyncio.create_task(read())

    try:
        room.register_text_stream_handler("lk.transcription", _on_transcript)
    except Exception as e:  # older SDKs
        log(f"(transcription handler unavailable: {e})")

    log("connecting…")
    await room.connect(url, mint_token(room_name))
    log(f"connected as {room.local_participant.identity}")

    # Publish a mic-like track (very quiet noise so VAD sees a live track).
    source = rtc.AudioSource(SAMPLE_RATE, 1)
    track = rtc.LocalAudioTrack.create_audio_track("microphone", source)
    await room.local_participant.publish_track(
        track, rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE)
    )
    log("mic track published")

    stop_feed = asyncio.Event()

    async def feed_silence() -> None:
        frame = rtc.AudioFrame.create(SAMPLE_RATE, 1, SAMPLE_RATE // 100)  # 10ms
        data = np.frombuffer(frame.data, dtype=np.int16)
        while not stop_feed.is_set():
            data[:] = (np.random.randn(len(data)) * 3).astype(np.int16)  # ~silence
            await source.capture_frame(frame)

    feeder = asyncio.create_task(feed_silence())

    try:
        # Some servers dispatch the agent before we attach listeners — check
        # existing participants too.
        for p in room.remote_participants.values():
            log(f"already present: {p.identity}")
            agent_joined.set()

        log(f"waiting up to {JOIN_TIMEOUT}s for agent to join…")
        try:
            await asyncio.wait_for(agent_joined.wait(), JOIN_TIMEOUT)
        except asyncio.TimeoutError:
            log("FAIL: agent never joined the room (is the worker running/registered? dispatch name right?)")
            return 1
        log("agent joined ✓")

        log(f"waiting up to {AUDIO_TIMEOUT}s for agent audio track…")
        try:
            stream = await asyncio.wait_for(agent_audio.get(), AUDIO_TIMEOUT)
        except asyncio.TimeoutError:
            log(f"FAIL: agent joined but published no audio. states={states} "
                "(TTS key broken? check /tmp/freewrite-coach.log)")
            return 2
        log("agent audio track subscribed ✓ — listening…")

        peak_rms = 0.0
        total = 0
        deadline = time.time() + LISTEN_SECONDS
        async for event in stream:
            samples = np.frombuffer(event.frame.data, dtype=np.int16).astype(np.float64)
            if len(samples):
                rms = float(np.sqrt(np.mean(samples**2)))
                peak_rms = max(peak_rms, rms)
                total += len(samples)
            if time.time() > deadline:
                break

        log(f"listened: {total/SAMPLE_RATE:.1f}s of audio, peak RMS={peak_rms:.0f}, "
            f"states={states}")
        if transcripts:
            log(f"agent said: {' | '.join(t[:160] for t in transcripts[:3])}")

        if peak_rms >= SPEECH_RMS_THRESHOLD:
            log("PASS ✓ — the coach joined and SPOKE (audible TTS audio received)")
            return 0
        log("FAIL: audio track present but silent — check TTS (ELEVEN_API_KEY) in agent log")
        return 3
    finally:
        stop_feed.set()
        feeder.cancel()
        await room.disconnect()


if __name__ == "__main__":
    try:
        raise SystemExit(asyncio.run(main()))
    except KeyboardInterrupt:
        raise SystemExit(4)

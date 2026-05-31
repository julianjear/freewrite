# Dockerfile for the Freewrite voice-coach agent.
#
# LiveKit Cloud's `lk agent deploy` builds the deployed image from THIS file.
# Every local module agent.py imports MUST be COPY'd in, or the container
# crashes at startup with ModuleNotFoundError. agent.py imports the local
# `coach/` package — so it's copied below. (Pattern + the download-files step
# mirror Jungle's proven agent Dockerfile.)

FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

# Install deps first so the pip layer caches across code changes.
COPY requirements.txt ./
RUN pip install -r requirements.txt

# Copy the agent entrypoint + the local coach package it imports.
COPY agent.py ./
COPY coach/ ./coach/

# Pre-download plugin model files (turn-detector ONNX, Silero VAD) into the
# image. Without this the agent crashes at startup with a missing-model error.
RUN python agent.py download-files

# Register with the LiveKit project at $LIVEKIT_URL and wait for job dispatches
# matching the room-name filter in agent.py:_request_fnc.
CMD ["python", "agent.py", "start"]

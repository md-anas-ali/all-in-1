# =========================================================
# ONE container = n8n + video-edit (ffmpeg) + tts (edge-tts)
# Render-এ ১টাই web service হিসেবে ডিপ্লয় হয় -> ১টাই instance-hour
# গোনা হয় (Monthly Included Usage কম খরচ হয়)।
# Target: 512MB RAM / 0.1 CPU (Render free/starter instance)
# =========================================================

FROM node:20-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------
# System packages — ffmpeg এখানেই একবার ইনস্টল হয়, video-edit
# সার্ভিস এই একই বাইনারি ব্যবহার করে (আলাদা ffmpeg-static ডাউনলোড
# করে না, তাতে ডুপ্লিকেট বাইনারি জমে জায়গা/মেমরি নষ্ট হতো না)
# ---------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    python3-venv \
    ffmpeg \
    fontconfig \
    fonts-dejavu-core \
    curl \
    ca-certificates \
    tini \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------
# Python virtual environment (edge-tts CLI fallback + tts service +
# yt-dlp/pillow/bs4 যা workflow script/scene ধাপে দরকার হতে পারে)
# ---------------------------------------------------------
RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

RUN pip install --no-cache-dir --upgrade pip setuptools wheel && \
    pip install --no-cache-dir \
    requests \
    python-dotenv \
    yt-dlp \
    edge-tts \
    pillow \
    beautifulsoup4 \
    lxml \
    fastapi \
    "uvicorn[standard]" \
    pydantic

# ---------------------------------------------------------
# n8n (stable version, Node 20 compatible)
#
# Pinned to the latest 1.x line on purpose — DO NOT bump to n8n 2.x
# without a manual migration pass. n8n 2.0 disables the
# ExecuteCommand node by default (security change), and this repo's
# workflow (My_workflow_4.json) relies on ExecuteCommand for cleanup,
# ffmpeg/audio-duration probing, image/voice validation, SRT
# building, and thumbnail generation. Upgrading straight to 2.x would
# silently break most of the render pipeline.
# ---------------------------------------------------------
ARG N8N_VERSION=1.120.0
RUN npm install -g n8n@${N8N_VERSION}

# ---------------------------------------------------------
# App user + directories
# ---------------------------------------------------------
RUN useradd -m -s /bin/bash n8n && \
    mkdir -p /home/n8n/.n8n /home/n8n/video-edit /home/n8n/tts && \
    chown -R n8n:n8n /home/n8n /opt/venv

# ---------------------------------------------------------
# video-edit microservice — install deps as root (npm cache dir is
# root-owned by default), then hand ownership to the n8n user
# ---------------------------------------------------------
COPY video-edit/package.json /home/n8n/video-edit/package.json
RUN cd /home/n8n/video-edit && npm install --omit=dev --no-audit --no-fund && \
    chown -R n8n:n8n /home/n8n/video-edit

COPY video-edit/server.js /home/n8n/video-edit/server.js

# ---------------------------------------------------------
# tts microservice (optional — see ENABLE_TTS_SERVICE below)
# ---------------------------------------------------------
COPY tts/main.py /home/n8n/tts/main.py
RUN chown -R n8n:n8n /home/n8n/tts

# ---------------------------------------------------------
# Startup script — launches video-edit + (optional) tts in the
# background on internal-only ports, then runs n8n in the foreground
# ---------------------------------------------------------
COPY start.sh /home/n8n/start.sh
RUN chown n8n:n8n /home/n8n/start.sh && chmod +x /home/n8n/start.sh

USER n8n
WORKDIR /home/n8n

# ---------------------------------------------------------
# Core n8n settings
# ---------------------------------------------------------
ENV N8N_HOST=0.0.0.0
ENV N8N_PORT=5678
ENV N8N_DATA_FOLDER=/home/n8n/.n8n

# ---------------------------------------------------------
# Internal-only ports for the bundled microservices
# (never exposed to the internet — only n8n inside this same
# container talks to them, over 127.0.0.1)
# ---------------------------------------------------------
ENV VIDEO_EDIT_PORT=3001
ENV TTS_PORT=3002
ENV ENABLE_TTS_SERVICE=false
ENV RENDER_VIDEO_EDIT_URL=http://127.0.0.1:3001
ENV RENDER_TTS_URL=http://127.0.0.1:3002

# ---------------------------------------------------------
# Memory budget across all 3 processes sharing one 512MB box:
#   n8n main:        ~200MB heap cap
#   video-edit node: ~96MB heap cap  (ffmpeg itself runs as a
#                     separate OS process, outside this heap)
#   tts (python):     ~40-70MB typical, only if enabled
#   OS + buffers:     remainder
#
# NOTE: kept at 200 rather than raised (e.g. to 256) on purpose.
# --max-old-space-size only caps the JS heap; actual RSS runs higher
# than the heap figure, and ffmpeg's own process memory (outside this
# cap entirely) also has to fit in what's left of the 512MB box. A
# bigger cap doesn't reserve more RAM up front, but it does let n8n
# grow further before Node's own GC/OOM guard kicks in — which means
# the *container* OOM-killer (no graceful recovery, just a hard kill)
# becomes more likely to be the thing that stops it instead. Leaving
# headroom here is what keeps that from happening.
# ---------------------------------------------------------
ENV NODE_OPTIONS=--max-old-space-size=200
ENV VIDEO_EDIT_NODE_OPTIONS=--max-old-space-size=96

ENV N8N_RUNNERS_ENABLED=false
ENV N8N_DIAGNOSTICS_ENABLED=false
ENV N8N_VERSION_NOTIFICATIONS_ENABLED=false
ENV N8N_TEMPLATES_ENABLED=false
ENV N8N_CONCURRENCY_PRODUCTION_LIMIT=1
ENV OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=false

# ---------------------------------------------------------
# Execution data: what gets saved, and pruning.
#
# FIX: the previous env vars here (N8N_PRUNING_ENABLED,
# N8N_PRUNING_EXECUTION_DATA_MAX_AGE) are not real n8n settings —
# n8n ignores env vars it doesn't recognize, so pruning was silently
# NOT running despite the intent. The correct variable names are
# EXECUTIONS_DATA_PRUNE / EXECUTIONS_DATA_MAX_AGE (hours). Verified
# against current n8n docs (docs.n8n.io/hosting/scaling/execution-data).
# ---------------------------------------------------------
ENV EXECUTIONS_DATA_PRUNE=true
ENV EXECUTIONS_DATA_MAX_AGE=24
ENV EXECUTIONS_DATA_PRUNE_MAX_COUNT=200
ENV EXECUTIONS_DATA_SAVE_ON_SUCCESS=none
ENV EXECUTIONS_DATA_SAVE_ON_ERROR=all
ENV EXECUTIONS_DATA_SAVE_ON_PROGRESS=false
ENV EXECUTIONS_DATA_SAVE_MANUAL_EXECUTIONS=false

# ---------------------------------------------------------
# Execution timeout ceiling. The workflow itself now sets
# settings.executionTimeout=900s (see workflow/My_workflow_4.json) —
# this pipeline targets a ~20-40s short (5 scenes, ~20-24s of voice),
# so a run that's still going after 15 minutes is stuck, not just
# slow. Without a hard stop, a wedged execution keeps holding onto
# n8n's ~200MB heap and any open ffmpeg process for as long as it
# hangs — on a 512MB box that's exactly the failure mode to avoid.
# EXECUTIONS_TIMEOUT_MAX must be >= the workflow's own value or n8n
# would clamp it down.
# ---------------------------------------------------------
ENV EXECUTIONS_TIMEOUT_MAX=1200

# ---------------------------------------------------------
# Binary data mode: this is the single biggest RAM-spike fix for this
# workflow. By default n8n holds binary data (images, audio, the
# rendered video files it reads/writes via the Read/Write File and
# HTTP Request nodes) IN MEMORY as it passes between nodes. A single
# scene's image+audio is small, but the final concatenated video
# binary flowing through "Read Final Video" / YouTube Upload can be
# tens of MB held in the n8n process's memory on top of everything
# else. `filesystem` mode makes n8n stream binaries to/from disk
# instead, keeping them out of the 200MB heap cap above.
# ---------------------------------------------------------
ENV N8N_DEFAULT_BINARY_DATA_MODE=filesystem
ENV N8N_SECURE_COOKIE=false

HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD curl -f http://localhost:5678/healthz || exit 1

EXPOSE 5678

CMD ["tini", "--", "/home/n8n/start.sh"]

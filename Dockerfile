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
#
# fc-cache -f at the end builds the fontconfig cache at build time
# instead of on the first runtime subtitle-burn call — without it,
# libass's first /concat request (the one that burns SRT subtitles)
# would trigger a full font directory scan at runtime, extra disk I/O
# right when a render is already using the most RAM it will use.
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
    && rm -rf /var/lib/apt/lists/* \
    && fc-cache -f

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
# Left OFF on purpose, not an oversight: My_workflow_4.json's voice step
# never calls this HTTP service — it shells out to the `edge-tts` CLI
# directly (see the executeCommand node, and the workflow's own
# "ALL-IN-ONE REPO UPDATE" sticky note). Flipping this to true would
# start a 3rd process (uvicorn + fastapi + edge-tts, ~40-70MB RSS) that
# nothing in the pipeline would ever hit — pure RAM spent for zero
# benefit on a box where every MB is budgeted. If a future workflow
# version is changed to call tts/main.py over HTTP instead, set this to
# true then (and re-check the memory budget above still fits).
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
#
# --max-semi-space-size caps V8's young-generation (new-space) size on
# top of the old-space cap above. Left at its default, new-space scales
# up automatically as max-old-space-size grows, which costs RSS that
# doesn't buy anything on a 0.1-CPU box — nothing here is fast enough
# to benefit from a big young generation. Pinning it small forces more
# frequent minor GCs (a bit more CPU) in exchange for a lower memory
# ceiling — the right trade here: slow is fine, OOM is not.
# ---------------------------------------------------------
ENV NODE_OPTIONS="--max-old-space-size=200 --max-semi-space-size=16"
ENV VIDEO_EDIT_NODE_OPTIONS="--max-old-space-size=96 --max-semi-space-size=8"

# ---------------------------------------------------------
# libuv's thread pool (used for DNS lookups, file I/O, crypto, zlib)
# defaults to 4 threads PER Node process. Each thread reserves its own
# stack, and with 2 Node processes in this container (n8n + video-edit)
# that's up to 8 threads doing real work no faster than the box's 0.1
# vCPU can schedule them anyway. Capping it to 2 trims that fixed
# per-process overhead without changing correctness — nothing here is
# CPU-parallel-sensitive.
# ---------------------------------------------------------
ENV UV_THREADPOOL_SIZE=2

# ---------------------------------------------------------
# Postgres connection pool. n8n's default pool is sized for
# higher-concurrency deployments; this box runs
# N8N_CONCURRENCY_PRODUCTION_LIMIT=1 (one execution at a time), so it
# never needs more than a couple of connections. Each idle pooled
# connection still holds its own small buffers — shrinking the pool
# trims that for no loss of throughput here.
# ---------------------------------------------------------
ENV DB_POSTGRESDB_POOL_SIZE=2

ENV N8N_RUNNERS_ENABLED=false
ENV N8N_DIAGNOSTICS_ENABLED=false
ENV N8N_VERSION_NOTIFICATIONS_ENABLED=false
ENV N8N_TEMPLATES_ENABLED=false
ENV N8N_CONCURRENCY_PRODUCTION_LIMIT=1
ENV OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=false
ENV N8N_METRICS=false

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

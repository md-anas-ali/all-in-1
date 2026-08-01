#!/bin/bash
# Launches all bundled services inside ONE container:
#  - video-edit (ffmpeg render helper)  -> internal port only
#  - tts (edge-tts REST API, optional)  -> internal port only
#  - n8n                                -> foreground, owns PORT/5678
#
# Only n8n's port is exposed by Render. video-edit and tts are reached
# by n8n over 127.0.0.1, so nothing outside this container can ever
# call them directly.

set -u

# ---------------------------------------------------------------------
# Crash-loop guard: if a child process (video-edit / tts) keeps dying
# immediately, retry with backoff instead of a tight `while true`
# restart loop that would peg the CPU and hide the real error under
# a wall of restart spam. After MAX_CRASHES rapid failures in a row,
# stop retrying that process and log loudly (it stays down instead
# of taking the whole container into a restart storm).
# ---------------------------------------------------------------------
MAX_CRASHES="${SUPERVISOR_MAX_CRASHES:-10}"

supervise() {
  local name="$1"; shift
  local crashes=0
  local backoff=3
  while true; do
    local start_ts
    start_ts=$(date +%s)
    "$@"
    local exit_code=$?
    local end_ts
    end_ts=$(date +%s)
    local ran_for=$((end_ts - start_ts))

    # A process that stayed up for a while before dying is treated as
    # a fresh problem, not part of a crash loop — reset the counter.
    if [ "$ran_for" -ge 30 ]; then
      crashes=0
      backoff=3
    fi

    crashes=$((crashes + 1))
    echo "[start.sh] ${name} exited (code ${exit_code}) after ${ran_for}s — crash ${crashes}/${MAX_CRASHES}" >&2

    if [ "$crashes" -ge "$MAX_CRASHES" ]; then
      echo "[start.sh] ${name} crash-looped ${MAX_CRASHES} times in a row — giving up on it. n8n will keep running; jobs that depend on ${name} will fail until this is fixed and the service is redeployed." >&2
      return 1
    fi

    echo "[start.sh] restarting ${name} in ${backoff}s..." >&2
    sleep "$backoff"
    # exponential backoff, capped at 30s
    if [ "$backoff" -lt 30 ]; then
      backoff=$((backoff * 2))
      [ "$backoff" -gt 30 ] && backoff=30
    fi
  done
}

echo "[start.sh] launching video-edit on 127.0.0.1:${VIDEO_EDIT_PORT:-3001}"
(
  cd /home/n8n/video-edit
  export NODE_OPTIONS="${VIDEO_EDIT_NODE_OPTIONS:---max-old-space-size=96}"
  export API_KEY="${RENDER_VIDEO_EDIT_API_KEY:-}"
  export FFMPEG_PATH="${FFMPEG_PATH:-ffmpeg}"
  supervise "video-edit" node server.js
) &

if [ "${ENABLE_TTS_SERVICE:-false}" = "true" ]; then
  echo "[start.sh] launching tts on 127.0.0.1:${TTS_PORT:-3002}"
  (
    cd /home/n8n/tts
    export API_KEY="${RENDER_TTS_API_KEY:-}"
    supervise "tts" uvicorn main:app --host 127.0.0.1 --port "${TTS_PORT:-3002}" --workers 1
  ) &
else
  echo "[start.sh] tts service disabled (ENABLE_TTS_SERVICE=false) — n8n's built-in edge-tts CLI is used instead"
fi

# ---------------------------------------------------------------------
# Wait for video-edit's /health before handing off to n8n. n8n starts
# accepting traffic immediately once it's up, so without this gate the
# very first render job triggered right after boot can hit video-edit
# before it has finished starting (or before ffmpeg/node warms up),
# causing a spurious "connection refused" failure early in a run.
# Bounded wait — never blocks the container forever if video-edit
# failed to start at all; n8n still comes up either way.
# ---------------------------------------------------------------------
echo "[start.sh] waiting for video-edit to become ready..."
READY_WAIT_SECS="${VIDEO_EDIT_READY_TIMEOUT:-25}"
video_edit_ready=false
for i in $(seq 1 "$READY_WAIT_SECS"); do
  if curl -fsS -o /dev/null "http://127.0.0.1:${VIDEO_EDIT_PORT:-3001}/health"; then
    video_edit_ready=true
    break
  fi
  sleep 1
done
if [ "$video_edit_ready" = true ]; then
  echo "[start.sh] video-edit is ready"
else
  echo "[start.sh] video-edit did not become ready within ${READY_WAIT_SECS}s — starting n8n anyway, but render jobs will fail until video-edit recovers" >&2
fi

echo "[start.sh] launching n8n in foreground"
exec n8n start

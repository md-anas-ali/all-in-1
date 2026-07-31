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

echo "[start.sh] launching video-edit on 127.0.0.1:${VIDEO_EDIT_PORT:-3001}"
(
  cd /home/n8n/video-edit
  export NODE_OPTIONS="${VIDEO_EDIT_NODE_OPTIONS:---max-old-space-size=96}"
  export API_KEY="${RENDER_VIDEO_EDIT_API_KEY:-}"
  export FFMPEG_PATH="${FFMPEG_PATH:-ffmpeg}"
  while true; do
    node server.js
    echo "[start.sh] video-edit exited, restarting in 3s..." >&2
    sleep 3
  done
) &

if [ "${ENABLE_TTS_SERVICE:-false}" = "true" ]; then
  echo "[start.sh] launching tts on 127.0.0.1:${TTS_PORT:-3002}"
  (
    cd /home/n8n/tts
    export API_KEY="${RENDER_TTS_API_KEY:-}"
    while true; do
      uvicorn main:app --host 127.0.0.1 --port "${TTS_PORT:-3002}" --workers 1
      echo "[start.sh] tts exited, restarting in 3s..." >&2
      sleep 3
    done
  ) &
else
  echo "[start.sh] tts service disabled (ENABLE_TTS_SERVICE=false) — n8n's built-in edge-tts CLI is used instead"
fi

echo "[start.sh] launching n8n in foreground"
exec n8n start

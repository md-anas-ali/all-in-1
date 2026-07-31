"""
Viral TTS Service
------------------
Free, low-resource (fits Render free tier: ~512MB RAM / 0.1 CPU / no GPU) TTS
microservice built on `edge-tts` (Microsoft Edge's neural voices).

Why edge-tts instead of a local neural model (Piper etc.)?
- It does NOT run the neural model on your server. It just streams text to
  Microsoft's public Edge "Read Aloud" service over a websocket and pipes the
  mp3 audio back. That means near-zero CPU/RAM usage on your side (no GPU,
  no model loading) -> fits comfortably in 400-450MB RAM / 0.1 CPU.
- It has 300+ natural, expressive neural voices (many accents, styles) which
  is why it's the go-to free option for YouTube Shorts / faceless channels
  (entertainment, mystery, tech, facts, space niches etc.) -> "viral friendly".
- 100% free, no API key required from Microsoft's side.

Endpoints:
  GET  /health         -> liveness check (also good as an UptimeRobot keep-alive ping)
  GET  /voices          -> curated + optional full voice list
  POST /tts              -> generate speech, returns raw mp3 bytes
"""

import io
import os
from typing import Optional

import edge_tts
from fastapi import FastAPI, Header, HTTPException
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel, Field

app = FastAPI(title="Viral TTS Service", version="1.0.0")

# Set this as an env var on Render (Environment tab) to protect your public
# URL from being used by strangers. If left empty, auth is disabled.
API_KEY = os.getenv("API_KEY", "")

# A curated shortlist of voices that work well for narration-heavy,
# entertainment/viral Shorts content. Use /voices?full=true to see all 300+.
RECOMMENDED_VOICES = {
    "en-US-GuyNeural": "Male, energetic — general narration / facts / tech",
    "en-US-EricNeural": "Male, deep — documentary / mystery tone",
    "en-US-ChristopherNeural": "Male, authoritative — news / explainer style",
    "en-US-DavisNeural": "Male, very expressive — great for dramatic hooks",
    "en-US-TonyNeural": "Male, punchy, confident — hook-heavy Shorts",
    "en-US-JennyNeural": "Female, warm & clear — general purpose",
    "en-US-AriaNeural": "Female, expressive, supports style tags — versatile",
    "en-US-AnaNeural": "Female, youthful, energetic",
    "en-GB-RyanNeural": "Male, British — documentary / space / mystery tone",
    "en-GB-SoniaNeural": "Female, British — clean narration",
    "en-AU-WilliamNeural": "Male, Australian — casual, energetic",
}


class TTSRequest(BaseModel):
    text: str = Field(..., min_length=1, max_length=6000)
    voice: str = Field(default="en-US-GuyNeural")
    rate: str = Field(default="+0%", description="Speed, e.g. +15%, -10%")
    pitch: str = Field(default="+0Hz", description="Pitch, e.g. +5Hz, -5Hz")
    volume: str = Field(default="+0%", description="Volume, e.g. +10%, -10%")


def check_auth(x_api_key: Optional[str]) -> None:
    if API_KEY and x_api_key != API_KEY:
        raise HTTPException(status_code=401, detail="Invalid or missing X-API-KEY header")


@app.get("/health")
async def health():
    # Keep this endpoint doing ZERO work — it's what Render's health check
    # and your UptimeRobot keep-alive ping will hit every few minutes.
    return {"status": "ok"}


@app.get("/voices")
async def voices(full: bool = False, x_api_key: Optional[str] = Header(default=None)):
    check_auth(x_api_key)
    if full:
        all_voices = await edge_tts.list_voices()
        return JSONResponse(content=all_voices)
    return RECOMMENDED_VOICES


@app.post("/tts")
async def tts(payload: TTSRequest, x_api_key: Optional[str] = Header(default=None)):
    check_auth(x_api_key)

    try:
        communicate = edge_tts.Communicate(
            text=payload.text,
            voice=payload.voice,
            rate=payload.rate,
            pitch=payload.pitch,
            volume=payload.volume,
        )

        audio_chunks = bytearray()
        async for chunk in communicate.stream():
            if chunk["type"] == "audio":
                audio_chunks.extend(chunk["data"])

        if not audio_chunks:
            raise HTTPException(
                status_code=502,
                detail="TTS engine returned no audio. Check the 'voice' name and 'text'.",
            )

        audio_stream = io.BytesIO(bytes(audio_chunks))
        return StreamingResponse(
            audio_stream,
            media_type="audio/mpeg",
            headers={"Content-Disposition": "attachment; filename=speech.mp3"},
        )
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"TTS generation failed: {str(e)}")

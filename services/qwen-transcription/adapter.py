"""
Qwen3-ASR adapter (vLLM backend) — Vexa-compatible.

Architecture (production / best-practice):
    bot ──► THIS adapter (:8084, CPU) ──► vLLM OpenAI server (:8000, GPU, batched)
                              │
                              └► ctc-forced-aligner (MMS, Turkish word timestamps)

vLLM does the heavy ASR with batching/async/concurrency. This thin adapter:
  - normalizes any audio to 16k mono wav (ffmpeg)
  - drops too-short chunks (garbled drafts) below MIN_AUDIO_SEC
  - forwards the audio to vLLM's /v1/audio/transcriptions for the TEXT
  - runs the MMS forced aligner for Turkish word-level timestamps
  - returns the SAME JSON shape Vexa's bot expects (segments[].words[])

Why split: vLLM's OpenAI server is the optimized serving path; Turkish word
timestamps aren't supported by Qwen's own aligner, so we add MMS here.
"""
import os
import time
import tempfile
import logging
import subprocess
from typing import Optional

import httpx
import soundfile as sf
import torch
from fastapi import FastAPI, File, UploadFile, Form, HTTPException, Request, Depends
from fastapi.security import APIKeyHeader

logging.basicConfig(level=getattr(logging, os.getenv("LOG_LEVEL", "INFO").upper(), logging.INFO))
logger = logging.getLogger("qwen-adapter")

VLLM_URL     = os.getenv("VLLM_URL", "http://qwen-vllm:8000/v1/audio/transcriptions")
VLLM_MODEL   = os.getenv("VLLM_MODEL", "Qwen/Qwen3-ASR-1.7B")
ALIGN_ID     = os.getenv("ALIGN_MODEL", "MahmoudAshraf/mms-300m-1130-forced-aligner")
ALIGN_DEVICE = os.getenv("ALIGN_DEVICE", "cpu")          # CPU keeps the GPU free for vLLM
API_TOKEN    = os.getenv("API_TOKEN", "").strip()
DEFAULT_LANG = os.getenv("DEFAULT_LANG", "tr").lower()
MIN_AUDIO_SEC = float(os.getenv("MIN_AUDIO_SEC", "1.2"))  # drop garbled short drafts
HTTP_TIMEOUT = float(os.getenv("VLLM_TIMEOUT", "60"))

# ISO-639-1 -> ISO-639-3 (for the MMS aligner)
ALIGN_LANG = {
    "tr": "tur", "en": "eng", "de": "deu", "fr": "fra", "es": "spa", "ru": "rus",
    "ar": "ara", "it": "ita", "pt": "por", "nl": "nld", "fa": "fas", "el": "ell",
    "pl": "pol", "ro": "ron", "hu": "hun", "cs": "ces", "sv": "swe",
}

app = FastAPI(title="Qwen3-ASR adapter (vLLM)")
api_key_header = APIKeyHeader(name="X-API-Key", auto_error=False)
align_model = None
align_tokenizer = None
_client: Optional[httpx.AsyncClient] = None


@app.on_event("startup")
def _load():
    global align_model, align_tokenizer, _client
    _client = httpx.AsyncClient(timeout=HTTP_TIMEOUT)
    try:
        from ctc_forced_aligner import load_alignment_model
        logger.info("Loading aligner %s on %s ...", ALIGN_ID, ALIGN_DEVICE)
        align_model, align_tokenizer = load_alignment_model(
            ALIGN_DEVICE, model_path=ALIGN_ID,
            dtype=torch.float16 if ALIGN_DEVICE != "cpu" else torch.float32,
        )
        logger.info("Aligner ready.")
    except Exception as e:
        logger.warning("Aligner load failed (%s) — words[] will be empty.", e)
        align_model = None
    logger.info("Adapter ready. vLLM=%s model=%s", VLLM_URL, VLLM_MODEL)


def _auth(request: Request, api_key: Optional[str]):
    if not API_TOKEN:
        return
    if api_key and api_key == API_TOKEN:
        return
    auth = request.headers.get("Authorization", "")
    if auth.startswith("Bearer ") and auth[7:].strip() == API_TOKEN:
        return
    raise HTTPException(status_code=401, detail="Invalid or missing API key")


@app.get("/health")
async def health():
    vllm_ok = False
    try:
        r = await _client.get(VLLM_URL.replace("/v1/audio/transcriptions", "/health"))
        vllm_ok = r.status_code == 200
    except Exception:
        pass
    return {
        "status": "healthy" if vllm_ok else "degraded",
        "vllm": vllm_ok, "vllm_url": VLLM_URL,
        "aligner": align_model is not None, "align_device": ALIGN_DEVICE,
    }


def _to_wav16k(src: str) -> str:
    dst = src + ".16k.wav"
    try:
        subprocess.run(["ffmpeg", "-nostdin", "-y", "-i", src, "-ar", "16000", "-ac", "1", "-f", "wav", dst],
                       check=True, capture_output=True, timeout=30)
        return dst
    except Exception as e:
        logger.warning("ffmpeg transcode failed (%s) — using raw", e)
        return src


def _align_words(path: str, text: str, lang_iso: str):
    if align_model is None or not text:
        return []
    try:
        from ctc_forced_aligner import (
            load_audio, generate_emissions, preprocess_text,
            get_alignments, get_spans, postprocess_results,
        )
        lang3 = ALIGN_LANG.get(lang_iso, "tur")
        wav = load_audio(path, align_model.dtype, align_model.device)
        emissions, stride = generate_emissions(align_model, wav, batch_size=4)
        tokens_starred, text_starred = preprocess_text(text, romanize=True, language=lang3)
        segs, scores, blank = get_alignments(emissions, tokens_starred, align_tokenizer)
        spans = get_spans(tokens_starred, segs, blank)
        wts = postprocess_results(text_starred, spans, stride, scores)
        return [{
            "word": " " + str(w.get("text", "")).strip(),
            "start": round(float(w.get("start", 0.0)), 2),
            "end": round(float(w.get("end", 0.0)), 2),
            "probability": float(w.get("score", 0.9)),
        } for w in wts]
    except Exception as e:
        logger.warning("alignment failed: %s", e)
        return []


@app.post("/v1/audio/transcriptions")
async def transcribe(
    request: Request,
    file: UploadFile = File(...),
    model: str = Form("whisper-1"),
    language: Optional[str] = Form(None),
    response_format: str = Form("verbose_json"),
    timestamp_granularities: Optional[str] = Form(None),
    api_key: Optional[str] = Depends(api_key_header),
):
    _auth(request, api_key)
    data = await file.read()
    with tempfile.NamedTemporaryFile(suffix=".in", delete=False) as tmp:
        tmp.write(data)
        raw = tmp.name
    path = _to_wav16k(raw)
    lang_iso = (language or "").lower().strip() or DEFAULT_LANG
    try:
        try:
            wav, sr = sf.read(path)
            duration = round(len(wav) / float(sr), 2) if sr else 0.0
        except Exception:
            duration = 0.0

        # Drop garbled short drafts — they pollute the transcript.
        if duration and duration < MIN_AUDIO_SEC:
            logger.info("REQ in=%dB dur=%.1fs SKIPPED (< %.1fs)", len(data), duration, MIN_AUDIO_SEC)
            return {"text": "", "language": lang_iso, "language_probability": 0.0,
                    "duration": duration, "engine": "qwen3-asr-vllm", "segments": []}

        # --- forward to vLLM for the TEXT ---
        t0 = time.time()
        text = ""
        try:
            with open(path, "rb") as fh:
                files = {"file": ("audio.wav", fh, "audio/wav")}
                form = {"model": VLLM_MODEL, "response_format": "json"}
                if lang_iso:
                    form["language"] = lang_iso
                resp = await _client.post(VLLM_URL, files=files, data=form)
            if resp.status_code == 200:
                text = (resp.json().get("text") or "").strip()
            else:
                logger.error("vLLM %s: %s", resp.status_code, resp.text[:200])
        except Exception as e:
            logger.error("vLLM forward failed: %s", e)
        t_asr = time.time() - t0

        t1 = time.time()
        words = _align_words(path, text, lang_iso) if text else []
        t_align = time.time() - t1

        logger.info("REQ in=%dB dur=%.1fs lang=%s asr=%.2fs align=%.2fs words=%d text=%r",
                    len(data), duration, lang_iso, t_asr, t_align, len(words),
                    (text[:120] + ("…" if len(text) > 120 else "")))

        segments = []
        if text:
            segments = [{
                "id": 0, "seek": 0, "start": 0.0, "end": duration,
                "text": " " + text, "tokens": [], "temperature": 0.0,
                "avg_logprob": -0.1, "compression_ratio": 1.0, "no_speech_prob": 0.0,
                "audio_start": 0.0, "audio_end": duration, "words": words,
            }]
        return {
            "text": text, "language": lang_iso,
            "language_probability": 0.99 if text else 0.0,
            "duration": duration, "engine": "qwen3-asr-vllm", "segments": segments,
        }
    finally:
        for p in (raw, path):
            try:
                os.unlink(p)
            except Exception:
                pass

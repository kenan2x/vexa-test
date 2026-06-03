"""
Qwen3-ASR transcription service — Vexa-compatible drop-in for the Whisper one.

Exposes the same OpenAI-style endpoint Vexa's bot already speaks:
    POST /v1/audio/transcriptions   (multipart: file, model, language, ...)
and returns the SAME JSON shape (text, language, language_probability,
duration, segments[].words[]), so the bot needs zero changes.

Pipeline:
    audio -> Qwen3-ASR (text, great Turkish)
          -> ctc-forced-aligner (MMS, Turkish word-level timestamps)
          -> assemble Vexa schema

Turkish has no native Qwen timestamps, so the aligner fills words[]. If the
aligner fails, we still return the text with empty words[] (transcription keeps
working; only per-word speaker attribution degrades).
"""
import os
import tempfile
import logging
import threading
from typing import Optional

import torch
import soundfile as sf
from fastapi import FastAPI, File, UploadFile, Form, HTTPException, Request, Depends
from fastapi.security import APIKeyHeader

logging.basicConfig(level=getattr(logging, os.getenv("LOG_LEVEL", "INFO").upper(), logging.INFO))
logger = logging.getLogger("qwen-asr")

MODEL_ID   = os.getenv("QWEN_MODEL", "Qwen/Qwen3-ASR-1.7B")
ALIGN_ID   = os.getenv("ALIGN_MODEL", "MahmoudAshraf/mms-300m-1130-forced-aligner")
DEVICE     = os.getenv("DEVICE", "cuda:0")
API_TOKEN  = os.getenv("API_TOKEN", "").strip()
DEFAULT_LANG = os.getenv("DEFAULT_LANG", "tr").lower()   # used when caller sends none

# ISO-639-1 -> Qwen language name
QWEN_LANG = {
    "tr": "Turkish", "en": "English", "de": "German", "fr": "French", "es": "Spanish",
    "ru": "Russian", "ar": "Arabic", "it": "Italian", "pt": "Portuguese", "nl": "Dutch",
    "zh": "Chinese", "ja": "Japanese", "ko": "Korean", "fa": "Persian", "el": "Greek",
    "pl": "Polish", "ro": "Romanian", "hu": "Hungarian", "cs": "Czech", "sv": "Swedish",
}
# ISO-639-1 -> ISO-639-3 (for the MMS aligner)
ALIGN_LANG = {
    "tr": "tur", "en": "eng", "de": "deu", "fr": "fra", "es": "spa", "ru": "rus",
    "ar": "ara", "it": "ita", "pt": "por", "nl": "nld", "fa": "fas", "el": "ell",
    "pl": "pol", "ro": "ron", "hu": "hun", "cs": "ces", "sv": "swe",
}

app = FastAPI(title="Qwen3-ASR (Vexa-compatible)")
_gpu_lock = threading.Lock()          # serialize GPU access (single model instance)
api_key_header = APIKeyHeader(name="X-API-Key", auto_error=False)

asr_model = None
align_model = None
align_tokenizer = None


@app.on_event("startup")
def _load_models():
    global asr_model, align_model, align_tokenizer
    from qwen_asr import Qwen3ASRModel
    logger.info("Loading ASR %s on %s ...", MODEL_ID, DEVICE)
    asr_model = Qwen3ASRModel.from_pretrained(MODEL_ID, dtype=torch.bfloat16, device_map=DEVICE)
    logger.info("ASR ready. Loading aligner %s ...", ALIGN_ID)
    try:
        from ctc_forced_aligner import load_alignment_model
        dev = "cuda" if "cuda" in DEVICE else "cpu"
        align_model, align_tokenizer = load_alignment_model(dev, model_path=ALIGN_ID, dtype=torch.float16)
        logger.info("Aligner ready.")
    except Exception as e:
        logger.warning("Aligner failed to load (%s) — words[] will be empty until fixed.", e)
        align_model, align_tokenizer = None, None
    logger.info("Startup complete.")


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
def health():
    return {
        "status": "healthy" if asr_model is not None else "unhealthy",
        "model": MODEL_ID,
        "device": DEVICE,
        "gpu_available": torch.cuda.is_available(),
        "aligner": align_model is not None,
    }


def _align_words(path: str, text: str, lang_iso: str):
    """Return Vexa-shaped words[] via the MMS forced aligner. Fail-soft -> []."""
    if align_model is None or not text:
        return []
    try:
        from ctc_forced_aligner import (
            load_audio, generate_emissions, preprocess_text,
            get_alignments, get_spans, postprocess_results,
        )
        lang3 = ALIGN_LANG.get(lang_iso, "tur")
        with _gpu_lock:
            wav = load_audio(path, align_model.dtype, align_model.device)
            emissions, stride = generate_emissions(align_model, wav, batch_size=4)
        tokens_starred, text_starred = preprocess_text(text, romanize=True, language=lang3)
        segs, scores, blank = get_alignments(emissions, tokens_starred, align_tokenizer)
        spans = get_spans(tokens_starred, segs, blank)
        wts = postprocess_results(text_starred, spans, stride, scores)
        out = []
        for w in wts:
            out.append({
                "word": " " + str(w.get("text", "")).strip(),
                "start": round(float(w.get("start", 0.0)), 2),
                "end": round(float(w.get("end", 0.0)), 2),
                "probability": float(w.get("score", 0.9)),
            })
        return out
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
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        tmp.write(data)
        path = tmp.name
    try:
        try:
            wav, sr = sf.read(path)
            duration = round(len(wav) / float(sr), 2) if sr else 0.0
        except Exception:
            duration = 0.0

        lang_iso = (language or "").lower().strip() or None
        qwen_lang = QWEN_LANG.get(lang_iso) if lang_iso else None

        with _gpu_lock:
            results = asr_model.transcribe(audio=path, language=qwen_lang)
        text = (getattr(results[0], "text", "") or "").strip()
        detected = (getattr(results[0], "language", None) or lang_iso or DEFAULT_LANG)
        lang_out = _to_iso1(detected)

        words = _align_words(path, text, lang_iso or lang_out or DEFAULT_LANG) if text else []

        segments = []
        if text:
            segments = [{
                "id": 0, "seek": 0, "start": 0.0, "end": duration,
                "text": " " + text, "tokens": [], "temperature": 0.0,
                "avg_logprob": -0.1, "compression_ratio": 1.0, "no_speech_prob": 0.0,
                "audio_start": 0.0, "audio_end": duration, "words": words,
            }]

        return {
            "text": text,
            "language": lang_out,
            "language_probability": 0.99,
            "duration": duration,
            "segments": segments,
        }
    finally:
        try:
            os.unlink(path)
        except Exception:
            pass


def _to_iso1(lang) -> str:
    """Normalize Qwen's language (name or code) to an ISO-639-1 code."""
    if not lang:
        return DEFAULT_LANG
    s = str(lang).lower()
    if len(s) == 2:
        return s
    name_to_iso = {v.lower(): k for k, v in QWEN_LANG.items()}
    return name_to_iso.get(s, DEFAULT_LANG)

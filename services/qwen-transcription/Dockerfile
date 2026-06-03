# Qwen3-ASR transcription service (Vexa-compatible), models baked in for offline runtime.
#
# BUILD THIS ON A MACHINE WITH INTERNET + ideally the GPU box itself (native
# amd64 + CUDA, fast). It downloads ~6 GB of model weights at build time; at
# runtime HF_HUB_OFFLINE=1 means zero network.
#
#   docker build -t vexa-qwen-asr:offline \
#     --build-arg QWEN_MODEL=Qwen/Qwen3-ASR-1.7B \
#     -f services/qwen-transcription/Dockerfile services/qwen-transcription
#
# Smaller/safer on tight VRAM: --build-arg QWEN_MODEL=Qwen/Qwen3-ASR-0.6B

FROM pytorch/pytorch:2.5.1-cuda12.1-cudnn9-runtime

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    git ffmpeg libsndfile1 curl build-essential \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# ── Bake the models FIRST (download at build; runtime needs no network) ──────
# Kept before COPY main.py so code changes don't re-download the 6 GB of weights.
ARG QWEN_MODEL=Qwen/Qwen3-ASR-1.7B
ARG ALIGN_MODEL=MahmoudAshraf/mms-300m-1130-forced-aligner
RUN python -c "from huggingface_hub import snapshot_download as d; d('${QWEN_MODEL}'); d('${ALIGN_MODEL}'); print('models baked')"

COPY main.py .

ENV QWEN_MODEL=${QWEN_MODEL} \
    ALIGN_MODEL=${ALIGN_MODEL} \
    HF_HUB_OFFLINE=1 \
    TRANSFORMERS_OFFLINE=1 \
    HF_HUB_DISABLE_TELEMETRY=1 \
    DO_NOT_TRACK=1 \
    DEVICE=cuda:0 \
    DEFAULT_LANG=tr

HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
    CMD curl -f http://localhost:8000/health || exit 1

EXPOSE 8000

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]

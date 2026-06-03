# Qwen3-ASR via vLLM (production path)

Faster, batched, async serving — replaces the single-instance transformers
service. Two containers:

```
bot ──► qwen-asr (adapter, :8084, CPU) ──► qwen-vllm (:8000, GPU, batched ASR)
                       │
                       └► MMS forced aligner (Turkish word timestamps, CPU)
```

- **qwen-vllm** — official vLLM OpenAI server (`vllm serve Qwen/Qwen3-ASR-1.7B
  --max-model-len 4096 --gpu-memory-utilization 0.6 --enforce-eager`). Model baked
  in for offline. Does the heavy ASR with batching/concurrency.
- **qwen-adapter** (container name `qwen-asr`, port 8084) — thin CPU FastAPI:
  ffmpeg-normalizes audio, drops too-short drafts (`MIN_AUDIO_SEC`), forwards to
  vLLM for text, runs the MMS aligner for Turkish word timestamps, returns the
  Vexa JSON shape. **Same name/port as before** → the compose stack's
  `QWEN_TRANSCRIPTION_SERVICE_URL=…:8084/…` keeps working unchanged.

## ⚠️ Validation note
vLLM support for Qwen3-ASR is brand-new (Jan 2026). This follows the official
docs, but the vLLM serving (model architecture, the `language` field, response
shape) **must be validated on the GPU** — it can't be tested without CUDA. If
`vllm serve` errors with "unknown model", switch `FROM` in `Dockerfile.vllm` to
the official `qwenllm/qwen3-asr:latest` (bundles vLLM + the model). Expect 1–2
iterations on the serve command.

## Build (on the GPU box)
```bash
bash services/qwen-transcription/build.vllm.sh          # proxy auto; override with PROXY=...
```

## Run
```bash
cd services/qwen-transcription
GPU_DEVICE_ID=0 API_TOKEN=<token> docker compose -f docker-compose.vllm.yml up -d
docker logs -f qwen-vllm        # wait for "Application startup complete"
curl -s http://localhost:8084/health     # expect "vllm":true,"aligner":true
```

## Test (Turkish + word timestamps)
```bash
curl -s -X POST http://localhost:8084/v1/audio/transcriptions \
  -H "X-API-Key: <token>" \
  -F file=@../transcription-service/tests/tr_test.wav \
  -F model=whisper-1 -F language=tr \
  -F response_format=verbose_json -F timestamp_granularities=word | python3 -m json.tool
```

## Tuning
- `GPU_MEM_UTIL` — raise toward `0.9` when the GPU is free (more KV cache / batching).
- `MAX_MODEL_LEN` — 4096 is plenty for meeting chunks.
- `MIN_AUDIO_SEC` — drop garbled short drafts (default 1.2s).
- `ALIGN_DEVICE=cuda` — move the aligner to GPU if you prefer (needs VRAM headroom).

## vs the old single-container service
The transformers service (`docker-compose.yml`, `Dockerfile`) still exists as a
simple fallback. This vLLM path is for throughput/latency under real load.

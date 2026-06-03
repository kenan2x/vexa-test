# Qwen3-ASR transcription service (Vexa-compatible)

Drop-in alternative to the Whisper `transcription-service`. Same OpenAI-style
endpoint (`POST /v1/audio/transcriptions`) and the **same response JSON**
(`text`, `language`, `segments[].words[]`), so Vexa's bot points at it unchanged.

```
audio ──► Qwen3-ASR-1.7B (text, strong Turkish)
       ──► ctc-forced-aligner (MMS, Turkish word-level timestamps)
       ──► Vexa-shaped JSON
```

- Model: `Qwen/Qwen3-ASR-1.7B` (Apache-2.0). Use `Qwen/Qwen3-ASR-0.6B` for tighter VRAM.
- Aligner: `MahmoudAshraf/mms-300m-1130-forced-aligner` — gives Turkish word timestamps.
- Aligner is **fail-soft**: if it errors, text still returns (words[] empty) so transcription keeps working.

## ⚠️ License note
The default MMS aligner model is **CC-BY-NC 4.0 (non-commercial)**. Fine for
evaluation. For commercial use, swap `ALIGN_MODEL` for a permissively-licensed
Turkish CTC model, or drop the aligner (lose per-word Teams attribution).

## Build (on a machine WITH internet — ideally the GPU box itself)

Native amd64 + CUDA build is fast; it downloads ~6 GB of weights and bakes them in.
```bash
git clone https://github.com/kenan2x/vexa-test.git && cd vexa-test
docker build -t vexa-qwen-asr:offline \
  --build-arg QWEN_MODEL=Qwen/Qwen3-ASR-1.7B \
  -f services/qwen-transcription/Dockerfile services/qwen-transcription
```

## Run (GPU box)
```bash
cd services/qwen-transcription
GPU_DEVICE_ID=0 API_TOKEN=<choose-a-token> docker compose up -d
docker logs -f qwen-asr        # wait for "Startup complete."
```

## Test
```bash
# health — expect "gpu_available":true,"aligner":true
curl -s http://localhost:8084/health

# Turkish transcription + word timestamps (reuse the Whisper repo's sample)
curl -s -X POST http://localhost:8084/v1/audio/transcriptions \
  -H "X-API-Key: <token>" \
  -F file=@../transcription-service/tests/tr_test.wav \
  -F model=whisper-1 -F language=tr \
  -F response_format=verbose_json -F timestamp_granularities=word | python3 -m json.tool
```
Expect the Turkish sentence in `text`, `language:"tr"`, and `segments[0].words[]`
populated with `start`/`end` per word.

## Point Vexa at it
On the compose server's `.env`:
```
TRANSCRIPTION_SERVICE_URL=http://<qwen-gpu-ip>:8084/v1/audio/transcriptions
TRANSCRIPTION_SERVICE_TOKEN=<same token>
```
Then re-run / restart the stack. The bot won't notice the difference — same contract.

## Notes
- First request loads/JITs; subsequent ones are faster.
- Single GPU, requests serialized (one model instance). For throughput, switch to
  the vLLM backend later (`vllm serve` exposes the same OpenAI endpoint).
- VRAM: 1.7B (~4 GB) + aligner (~1.2 GB) + overhead → ~6–7 GB. Use 0.6B if tight.

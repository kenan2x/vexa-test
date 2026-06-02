# Offline single-GPU transcription (Turkish, large-v3)

Self-contained transcription service for an **air-gapped GPU server** — the
Whisper `large-v3` model is baked into the image, so the runtime needs **zero
internet**. Built on a Mac, shipped via GitHub Container Registry (ghcr.io).

- Image: `ghcr.io/kenan2x/vexa-transcription:large-v3-offline` (linux/amd64)
- Model: `large-v3` + `int8` (~3 GB baked in; ~3-4 GB VRAM at runtime)
- Validated offline (`--network none`): Turkish text + word-level timestamps OK

## Files

| File | Purpose |
|------|---------|
| `Dockerfile.offline` | GPU/amd64 image, bakes the model in (build on Mac) |
| `Dockerfile.cpu.offline` | CPU/arm64 image — local validation only |
| `docker-compose.offline.yml` | 1 worker pinned to one GPU, no model volume, offline |
| `nginx.offline.conf` | single-upstream load balancer |
| `tests/tr_test.wav` | 11s Turkish sample for the smoke test |

---

## On the GPU server

### 0. Prerequisites (one time)
- NVIDIA driver installed (`nvidia-smi` works)
- `nvidia-container-toolkit` installed (so Docker can see the GPU)
- Free GPU index is **0** (set `GPU_DEVICE_ID` otherwise)

### 1. Pull the image (during the internet/bring-up window)
```bash
docker pull ghcr.io/kenan2x/vexa-transcription:large-v3-offline
```
> If the package is private, first: `echo <GITHUB_TOKEN> | docker login ghcr.io -u kenan2x --password-stdin`

### 2. Get the compose + nginx config
```bash
git clone https://github.com/kenan2x/vexa-test.git
cd vexa-test/services/transcription-service
```

### 3. Bring it up (no internet needed from here on)
```bash
GPU_DEVICE_ID=0 API_TOKEN=<choose-a-token> \
  docker compose -f docker-compose.offline.yml up -d
```
`API_TOKEN` is the shared secret; the main Vexa stack must send the same value
as `TRANSCRIPTION_SERVICE_TOKEN`.

---

## Test it

```bash
# 1. Health — expect "device":"cuda","gpu_available":true
curl -s http://localhost:8083/health

# 2. GPU is actually used — expect the python worker in the process list
docker exec transcription-worker-1 nvidia-smi

# 3. Turkish transcription + word timestamps
curl -s -X POST http://localhost:8083/v1/audio/transcriptions \
  -H "X-API-Key: <token>" \
  -F file=@tests/tr_test.wav \
  -F model=whisper-1 \
  -F response_format=verbose_json \
  -F timestamp_granularities=word | python3 -m json.tool
```

Expected text:
> "Merhaba arkadaşlar, bugünkü toplantıda yeni transkripsiyon servisini
> konuşacağız. Bu sistem Türkçe konuşmaları gerçek zamanlı olarak yazıya döküyor."

`language` should be `"tr"`, and every `segments[].words[]` entry should carry
`start`/`end` — that word timing is what the Vexa bot uses to attribute speech
to speakers on Teams.

---

## Wire the main Vexa stack to this (on the OTHER server)

In the compose stack's `.env`:
```
TRANSCRIPTION_SERVICE_URL=http://<this-gpu-server-ip>:8083/v1/audio/transcriptions
TRANSCRIPTION_SERVICE_TOKEN=<same value as API_TOKEN above>
```
Open port **8083** on the GPU server only to the compose server.

---

## Rebuild the image (on a machine WITH internet, e.g. Mac)

```bash
# from services/transcription-service/
docker buildx build --builder multiplatform --platform linux/amd64 \
  -f Dockerfile.offline --build-arg MODEL_SIZE=large-v3 \
  -t ghcr.io/kenan2x/vexa-transcription:large-v3-offline --push .
```
To try a different model, change `--build-arg MODEL_SIZE=` (e.g. `large-v3-turbo`
for speed). The model is downloaded at build time and frozen into the image.

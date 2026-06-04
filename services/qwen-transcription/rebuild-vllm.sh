#!/usr/bin/env bash
# Rebuild the vLLM image (with audio decode libs), restart the stack with a sane
# GPU budget, wait for startup, then health-check + run a Turkish test transcription.
# Run on the GPU box:
#   API_TOKEN=<token> bash services/qwen-transcription/rebuild-vllm.sh
# Optional env: PROXY, GPU_DEVICE_ID (0), GPU_MEM_UTIL (0.15), SKIP_BUILD=1
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CTX="$ROOT/services/qwen-transcription"
PROXY="${PROXY:-http://10.20.1.140:8080}"
GPU_DEVICE_ID="${GPU_DEVICE_ID:-0}"
GPU_MEM_UTIL="${GPU_MEM_UTIL:-0.15}"
API_TOKEN="${API_TOKEN:-}"
[ -z "$API_TOKEN" ] && { echo "✗ API_TOKEN gerekli (QWEN_TRANSCRIPTION_SERVICE_TOKEN ile aynı olmalı)."; echo "  Kullanım: API_TOKEN=<token> bash $0"; exit 1; }

# 1) Build vLLM image (proxy build-time only). Adapter unchanged → skip it.
if [ "${SKIP_BUILD:-0}" != "1" ]; then
  echo "== [1/4] vLLM image build (proxy=$PROXY, audio libs dahil) =="
  docker build -t vexa-qwen-vllm:offline \
    --build-arg HTTP_PROXY="$PROXY" --build-arg HTTPS_PROXY="$PROXY" \
    --build-arg http_proxy="$PROXY" --build-arg https_proxy="$PROXY" \
    --build-arg NO_PROXY=localhost,127.0.0.1 \
    -f "$CTX/Dockerfile.vllm" "$CTX" || {
      echo "✗ build başarısız. 'unknown model' hatası varsa Dockerfile.vllm'de FROM'u"
      echo "  qwenllm/qwen3-asr:latest yap."; exit 1; }
else
  echo "== [1/4] build atlandı (SKIP_BUILD=1) =="
fi

# 2) Recreate the stack with the GPU budget.
echo "== [2/4] compose up (GPU=$GPU_DEVICE_ID, mem_util=$GPU_MEM_UTIL) =="
cd "$CTX"
GPU_DEVICE_ID="$GPU_DEVICE_ID" GPU_MEM_UTIL="$GPU_MEM_UTIL" API_TOKEN="$API_TOKEN" \
  docker compose -f docker-compose.vllm.yml up -d --force-recreate || { echo "✗ compose up başarısız"; exit 1; }

# 3) Wait for vLLM to finish loading (model load can take a few minutes).
echo "== [3/4] vLLM başlatılıyor bekleniyor (max ~5dk) =="
for i in $(seq 1 60); do
  if docker logs qwen-vllm 2>&1 | grep -q "Application startup complete"; then
    echo "  ✓ vLLM hazır"; break; fi
  if docker logs qwen-vllm 2>&1 | grep -qiE "Free memory on device|less than desired|raise ValueError"; then
    echo "  ✗ vLLM başlangıç hatası — son loglar:"; docker logs --tail 15 qwen-vllm; exit 1; fi
  sleep 5
  [ "$i" = "60" ] && { echo "  ✗ zaman aşımı — son loglar:"; docker logs --tail 20 qwen-vllm; exit 1; }
done

# 4) Health + a real Turkish test transcription end-to-end through the adapter.
echo "== [4/4] health + Türkçe test =="
echo "-- health (8084) --"
curl -s --max-time 10 http://localhost:8084/health; echo
WAV="$ROOT/services/transcription-service/tests/tr_test.wav"
if [ -f "$WAV" ]; then
  echo "-- transcription ($WAV) --"
  curl -s --max-time 120 -X POST http://localhost:8084/v1/audio/transcriptions \
    -H "X-API-Key: $API_TOKEN" \
    -F file=@"$WAV" -F model=whisper-1 -F language=tr \
    -F response_format=verbose_json -F timestamp_granularities=word \
    | python3 -c "import sys,json;d=json.load(sys.stdin);print('lang:',d.get('language'));print('text:',(d.get('text') or '').strip());w=(d.get('segments') or [{}])[0].get('words') or d.get('words') or [];print('words#:',len(w));print('ilk word:',w[0] if w else '—')" 2>/dev/null \
    || { echo "(JSON parse edilemedi, ham çıktı:)"; curl -s -X POST http://localhost:8084/v1/audio/transcriptions -H "X-API-Key: $API_TOKEN" -F file=@"$WAV" -F model=whisper-1 -F language=tr -F response_format=verbose_json; }
else
  echo "  (test wav yok: $WAV — health yeterli)"
fi
echo
echo "✓ Bitti. text Türkçe ve words# > 0 ise vLLM yolu çalışıyor. Bot ile canlı deneyebilirsin."

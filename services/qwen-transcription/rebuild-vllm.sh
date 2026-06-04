#!/usr/bin/env bash
# ONE command to (git pull →) build → restart → wait → health + Turkish test.
# Run on the GPU box:
#   API_TOKEN=<token> bash services/qwen-transcription/rebuild-vllm.sh
#
# Common variants:
#   ONLY_ADAPTER=1 ...   # rebuild just the adapter (vLLM image already good)
#   ONLY_VLLM=1    ...   # rebuild just the vLLM image
#   SKIP_BUILD=1   ...   # no build, just restart + test
#   NO_PULL=1      ...   # don't git pull first
# Optional env: PROXY, GPU_DEVICE_ID (0), GPU_MEM_UTIL (0.15)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CTX="$ROOT/services/qwen-transcription"

# --- git pull first, then re-exec the (possibly updated) script once ---
if [ "${NO_PULL:-0}" != "1" ] && [ "${_PULLED:-0}" != "1" ]; then
  echo "== git pull =="
  git -C "$ROOT" pull --ff-only || echo "  (pull atlandı/başarısız — mevcut kodla devam)"
  export _PULLED=1
  exec bash "$0" "$@"
fi

PROXY="${PROXY:-http://10.20.1.140:8080}"
GPU_DEVICE_ID="${GPU_DEVICE_ID:-0}"
GPU_MEM_UTIL="${GPU_MEM_UTIL:-0.15}"

# API_TOKEN: from env, else try the compose .env on this box.
API_TOKEN="${API_TOKEN:-}"
if [ -z "$API_TOKEN" ]; then
  for f in "$ROOT/.env" "$CTX/.env"; do
    [ -f "$f" ] && API_TOKEN="$(grep -E '^(QWEN_TRANSCRIPTION_SERVICE_TOKEN|API_TOKEN)=' "$f" | head -1 | cut -d= -f2-)"
    [ -n "$API_TOKEN" ] && { echo "API_TOKEN $f içinden alındı"; break; }
  done
fi
[ -z "$API_TOKEN" ] && { echo "✗ API_TOKEN gerekli (QWEN_TRANSCRIPTION_SERVICE_TOKEN ile aynı)."; echo "  Kullanım: API_TOKEN=<token> bash $0"; exit 1; }

bp() { echo "--build-arg HTTP_PROXY=$PROXY --build-arg HTTPS_PROXY=$PROXY --build-arg http_proxy=$PROXY --build-arg https_proxy=$PROXY --build-arg NO_PROXY=localhost,127.0.0.1"; }

DO_VLLM=1; DO_ADAPTER=1
[ "${ONLY_ADAPTER:-0}" = "1" ] && DO_VLLM=0
[ "${ONLY_VLLM:-0}" = "1" ]    && DO_ADAPTER=0
[ "${SKIP_BUILD:-0}" = "1" ]   && { DO_VLLM=0; DO_ADAPTER=0; }

# 1) Builds (proxy build-time only)
if [ "$DO_VLLM" = "1" ]; then
  echo "== [1a] vLLM image build =="
  docker build -t vexa-qwen-vllm:offline $(bp) -f "$CTX/Dockerfile.vllm" "$CTX" || {
    echo "✗ vLLM build başarısız. 'unknown model' hatası varsa Dockerfile.vllm'de FROM'u qwenllm/qwen3-asr:latest yap."; exit 1; }
fi
if [ "$DO_ADAPTER" = "1" ]; then
  echo "== [1b] adapter image build (torch pinli + VAD + Türkçe aligner) =="
  docker build -t vexa-qwen-adapter:offline $(bp) -f "$CTX/Dockerfile.adapter" "$ROOT" || { echo "✗ adapter build başarısız"; exit 1; }
fi
[ "$DO_VLLM" = "0" ] && [ "$DO_ADAPTER" = "0" ] && echo "== build atlandı =="

# 2) Recreate the stack
echo "== [2] compose up (GPU=$GPU_DEVICE_ID, mem_util=$GPU_MEM_UTIL) =="
cd "$CTX"
GPU_DEVICE_ID="$GPU_DEVICE_ID" GPU_MEM_UTIL="$GPU_MEM_UTIL" API_TOKEN="$API_TOKEN" \
  docker compose -f docker-compose.vllm.yml up -d --force-recreate || { echo "✗ compose up başarısız"; exit 1; }

# 3) Wait for vLLM to finish loading
echo "== [3] vLLM başlatılıyor bekleniyor (max ~5dk) =="
for i in $(seq 1 60); do
  if docker logs qwen-vllm 2>&1 | grep -q "Application startup complete"; then echo "  ✓ vLLM hazır"; break; fi
  if docker logs qwen-vllm 2>&1 | grep -qiE "Free memory on device|less than desired"; then
    echo "  ✗ vLLM GPU bellek hatası — GPU_MEM_UTIL düşür. Son loglar:"; docker logs --tail 12 qwen-vllm; exit 1; fi
  sleep 5
  [ "$i" = "60" ] && { echo "  ✗ zaman aşımı — son loglar:"; docker logs --tail 20 qwen-vllm; exit 1; }
done
# adapter VAD durumu
echo "-- adapter (qwen-asr) startup --"
docker logs qwen-asr 2>&1 | grep -iE "Silero VAD ready|VAD load failed|Aligner ready|Aligner load failed|Adapter ready" | tail -5

# 4) Health + a real Turkish test
echo "== [4] health + Türkçe test =="
echo "-- health (8084) --"; curl -s --max-time 10 http://localhost:8084/health; echo
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
echo "✓ Bitti. health'te \"vad\":true ve text Türkçe + words#>0 ise hazır. GUI'den 4dk'lık sesi gönderip dene."

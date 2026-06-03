#!/usr/bin/env bash
# Build the vLLM + adapter images behind the proxy. Run on the GPU box.
#   bash services/qwen-transcription/build.vllm.sh
#   PROXY=http://10.20.1.140:8080 bash services/qwen-transcription/build.vllm.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CTX="$ROOT/services/qwen-transcription"
PROXY="${PROXY:-http://10.20.1.140:8080}"

PXY=()
if [ -n "$PROXY" ]; then
  PXY=(--build-arg HTTP_PROXY="$PROXY" --build-arg HTTPS_PROXY="$PROXY"
       --build-arg http_proxy="$PROXY" --build-arg https_proxy="$PROXY"
       --build-arg NO_PROXY=localhost,127.0.0.1)
fi
echo "proxy = $PROXY (build-time only)"

echo "== [1/2] vLLM image (Qwen modeli gömülü) =="
docker build -t vexa-qwen-vllm:offline "${PXY[@]}" -f "$CTX/Dockerfile.vllm" "$CTX" || {
  echo "✗ vLLM build başarısız. 'unknown model' hatası varsa Dockerfile.vllm'de FROM'u"
  echo "  qwenllm/qwen3-asr:latest yap (resmî image, Qwen3-ASR garanti destekli)."; exit 1; }

echo "== [2/2] adapter image (CPU + Türkçe aligner) =="
docker build -t vexa-qwen-adapter:offline "${PXY[@]}" -f "$CTX/Dockerfile.adapter" "$ROOT" || { echo "✗ adapter build başarısız"; exit 1; }

echo
echo "✓ İki image hazır. Çalıştır:"
echo "  cd $CTX"
echo "  GPU_DEVICE_ID=0 API_TOKEN=<token> docker compose -f docker-compose.vllm.yml up -d"
echo "  docker logs -f qwen-vllm     # 'Application startup complete' bekle (model yükleme uzun sürebilir)"
echo "  docker logs -f qwen-asr      # adapter"
echo "  curl -s http://localhost:8084/health"

#!/usr/bin/env bash
# Build the Qwen3-ASR image behind the corporate proxy.
# Proxy is build-time only (pip / git / model download) — it does NOT end up in
# the runtime image.
#
# Usage (from repo root):
#   bash services/qwen-transcription/build.sh
#   PROXY=http://10.20.1.140:8080 bash services/qwen-transcription/build.sh
#   QWEN_MODEL=Qwen/Qwen3-ASR-0.6B bash services/qwen-transcription/build.sh   # tighter VRAM
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CTX="$ROOT/services/qwen-transcription"
PROXY="${PROXY:-http://10.20.1.140:8080}"     # the proxy seen in the gateway env; override if different
QWEN_MODEL="${QWEN_MODEL:-Qwen/Qwen3-ASR-1.7B}"
TAG="${TAG:-vexa-qwen-asr:offline}"

echo "== Building $TAG =="
echo "  proxy      = $PROXY   (build-time only)"
echo "  qwen model = $QWEN_MODEL"
echo "  context    = $CTX"
echo

PXY_ARGS=()
if [ -n "$PROXY" ]; then
  PXY_ARGS=(
    --build-arg HTTP_PROXY="$PROXY"
    --build-arg HTTPS_PROXY="$PROXY"
    --build-arg http_proxy="$PROXY"
    --build-arg https_proxy="$PROXY"
    --build-arg NO_PROXY="localhost,127.0.0.1"
  )
fi

docker build -t "$TAG" \
  "${PXY_ARGS[@]}" \
  --build-arg QWEN_MODEL="$QWEN_MODEL" \
  -f "$CTX/Dockerfile" "$CTX"
rc=$?

echo
if [ $rc -eq 0 ]; then
  echo "✓ Build OK: $TAG"
  echo
  echo "Çalıştır:"
  echo "  cd $CTX"
  echo "  GPU_DEVICE_ID=0 API_TOKEN=<bir-token> docker compose up -d"
  echo "  docker logs -f qwen-asr      # 'Startup complete.' bekle"
  echo
  echo "Test:"
  echo "  curl -s http://localhost:8084/health"
else
  echo "✗ Build başarısız (exit $rc)."
  echo "  SSL/sertifika hatası varsa söyle — CA çözümünü Dockerfile'a ekleyeyim."
fi
exit $rc

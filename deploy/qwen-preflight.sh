#!/usr/bin/env bash
# Pre-flight before sending a bot with the Qwen model. Run on the COMPOSE server.
# Verifies the Qwen adapter is reachable, VAD+aligner are up, and the token matches
# (the classic 401 trap). Uses a curl sidecar container with the proxy neutralised
# (NO_PROXY=*) — the same way the Vexa services reach it — so we don't depend on
# curl/python being present inside any app container.
#   bash deploy/qwen-preflight.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; ENV="$ROOT/.env"
QURL="$(grep -E '^QWEN_TRANSCRIPTION_SERVICE_URL=' "$ENV" | head -1 | cut -d= -f2-)"
QTOK="$(grep -E '^QWEN_TRANSCRIPTION_SERVICE_TOKEN=' "$ENV" | head -1 | cut -d= -f2-)"
[ -z "$QURL" ] && { echo "✗ .env'de QWEN_TRANSCRIPTION_SERVICE_URL yok"; exit 1; }
BASE="${QURL%/v1/audio/transcriptions}"
WAV="$ROOT/services/transcription-service/tests/tr_test.wav"
echo "Qwen URL   : $QURL"
echo "Token      : ${QTOK:0:6}…(${#QTOK} karakter)"
echo

echo "== [1/2] health ($BASE/health) =="
H="$(docker run --rm -e HTTP_PROXY= -e HTTPS_PROXY= -e NO_PROXY='*' -e no_proxy='*' \
       curlimages/curl:latest -s --max-time 8 "$BASE/health" 2>/dev/null || true)"
echo "  ${H:-<yanıt yok>}"
echo "$H" | grep -q '"vllm":[[:space:]]*true'    && echo "  ✓ vLLM bağlı"    || echo "  ✗ vLLM bağlı DEĞİL (qwen-vllm çalışıyor mu?)"
echo "$H" | grep -q '"vad":[[:space:]]*true'     && echo "  ✓ VAD aktif"     || echo "  ⚠ VAD görünmüyor"
echo "$H" | grep -q '"aligner":[[:space:]]*true' && echo "  ✓ aligner aktif" || echo "  ⚠ aligner yok → kelime zaman damgası boş (metni etkilemez)"

echo "== [2/2] token kontrolü (gerçek POST) =="
if [ -f "$WAV" ]; then
  CODE="$(docker run --rm -e HTTP_PROXY= -e HTTPS_PROXY= -e NO_PROXY='*' -e no_proxy='*' \
        -v "$WAV:/t.wav:ro" curlimages/curl:latest \
        -s -o /tmp/_pf.out -w '%{http_code}' --max-time 60 \
        -X POST "$QURL" -H "X-API-Key: $QTOK" \
        -F file=@/t.wav -F model=whisper-1 -F language=tr -F response_format=verbose_json 2>/dev/null || echo "000")"
  echo "  HTTP $CODE"
  case "$CODE" in
    200) echo "  ✓ token kabul edildi, transkripsiyon döndü";;
    401) echo "  ✗ 401 — .env QWEN_TRANSCRIPTION_SERVICE_TOKEN ile adapter API_TOKEN AYNI DEĞİL. Eşitle + qwen-asr'ı restart et.";;
    000) echo "  ✗ adapter'a ulaşılamadı (ağ/proxy/port). qwen-asr ayakta mı, 8084 açık mı?";;
    *)   echo "  ⚠ beklenmedik kod $CODE";;
  esac
else
  echo "  (test wav yok: $WAV — health yeterli)"
fi
echo
echo "Sonuç: yukarıda vLLM ✓ ve token 200 ise — UI'den model QWEN, dil Türkçe seçip botu gönderebilirsin."
echo "Canlı izleme (GPU kutusu): bash deploy/qwen-watch.sh   |   sonra ölçüm: bash deploy/qwen-stats.sh"

#!/usr/bin/env bash
# Pre-flight before sending a bot with the Qwen model. Run on the COMPOSE server.
# Verifies, from where meeting-api/the bot actually live:
#   1) the Qwen adapter URL is reachable (not blocked by the corp proxy)
#   2) VAD + aligner are up
#   3) the token in .env matches what the adapter accepts (the classic 401 trap)
#   bash deploy/qwen-preflight.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; ENV="$ROOT/.env"
QURL="$(grep -E '^QWEN_TRANSCRIPTION_SERVICE_URL=' "$ENV" | head -1 | cut -d= -f2-)"
QTOK="$(grep -E '^QWEN_TRANSCRIPTION_SERVICE_TOKEN=' "$ENV" | head -1 | cut -d= -f2-)"
[ -z "$QURL" ] && { echo "✗ .env'de QWEN_TRANSCRIPTION_SERVICE_URL yok"; exit 1; }
BASE="${QURL%/v1/audio/transcriptions}"
echo "Qwen URL   : $QURL"
echo "Token      : ${QTOK:0:6}…(${#QTOK} char)"
echo

# 1+2) health — run the curl from INSIDE the meeting-api container so we test the
# exact network path the bot config will use (not the host's).
MC="$(docker ps --format '{{.Names}}' | grep -iE 'meeting-api|meeting_api' | head -1)"
RUNNER=(docker run --rm --network "${COMPOSE_NET:-vexa_vexa}" curlimages/curl:latest)
[ -n "$MC" ] && RUNNER=(docker exec "$MC")
echo "== [1/3] health ($BASE/health) =="
H="$("${RUNNER[@]}" curl -s --max-time 8 -H 'NO_PROXY=*' "$BASE/health" 2>/dev/null)"
echo "  $H"
echo "$H" | grep -q '"vad":[[:space:]]*true'      && echo "  ✓ VAD aktif"       || echo "  ⚠ VAD görünmüyor (VAD_ENABLED=0 olabilir)"
echo "$H" | grep -q '"aligner":[[:space:]]*true'  && echo "  ✓ aligner aktif"   || echo "  ⚠ aligner yok → word timestamp boş gelir"
echo "$H" | grep -q '"vllm":[[:space:]]*true'      && echo "  ✓ vLLM bağlı"      || echo "  ✗ vLLM bağlı değil!"

# 3) token check — real transcription POST, expect 200 (401 = token mismatch)
echo "== [2/3] token kontrolü (gerçek POST) =="
WAV="$ROOT/services/transcription-service/tests/tr_test.wav"
if [ -f "$WAV" ] && [ -n "$MC" ]; then
  docker cp "$WAV" "$MC:/tmp/pf.wav" >/dev/null 2>&1
  CODE="$(docker exec "$MC" curl -s -o /tmp/pf.out -w '%{http_code}' --max-time 60 -H 'NO_PROXY=*' \
      -X POST "$QURL" -H "X-API-Key: $QTOK" \
      -F file=@/tmp/pf.wav -F model=whisper-1 -F language=tr -F response_format=verbose_json 2>/dev/null)"
  echo "  HTTP $CODE"
  case "$CODE" in
    200) echo "  ✓ token kabul edildi"; docker exec "$MC" sh -c 'python3 -c "import json;d=json.load(open(\"/tmp/pf.out\"));print(\"  text:\",(d.get(\"text\") or \"\").strip()[:100])" 2>/dev/null || head -c 200 /tmp/pf.out';;
    401) echo "  ✗ 401 — .env QWEN_TRANSCRIPTION_SERVICE_TOKEN ile adapter API_TOKEN AYNI DEĞİL. Eşitle, restart et.";;
    *)   echo "  ⚠ beklenmedik kod. Çıktı:"; docker exec "$MC" head -c 200 /tmp/pf.out;;
  esac
  docker exec "$MC" rm -f /tmp/pf.wav /tmp/pf.out 2>/dev/null
else
  echo "  (meeting-api container ya da test wav bulunamadı — health yeterli)"
fi

echo "== [3/3] sonuç =="
echo "Yukarıda 3 ✓ varsa (vLLM + VAD + token 200): UI'den modeli QWEN, dili Türkçe seçip botu gönderebilirsin."
echo "Canlıyı izlemek için GPU kutusunda:  bash deploy/qwen-watch.sh   (ya da: docker logs -f qwen-asr)"

#!/usr/bin/env bash
# Offline transcription smoke test — run ON the GPU server after `docker compose up -d`.
#
# Usage:
#   API_TOKEN=<token> ./tests/smoke-offline.sh
#   API_TOKEN=<token> BASE_URL=http://localhost:8083 WAV=tests/tr_test.wav ./tests/smoke-offline.sh
#
# It waits for the model to load (first GPU load of large-v3 can take ~1 min),
# prints the HTTP status (so an empty/failed response is never a mystery), runs
# the Turkish transcription, and checks: language=tr + word-level timestamps.

set -uo pipefail

BASE_URL="${BASE_URL:-http://localhost:8083}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WAV="${WAV:-$SCRIPT_DIR/tr_test.wav}"
API_TOKEN="${API_TOKEN:-${1:-}}"
WORKER="${WORKER:-transcription-worker-1}"

red(){ printf '\033[31m%s\033[0m\n' "$*"; }
grn(){ printf '\033[32m%s\033[0m\n' "$*"; }
ylw(){ printf '\033[33m%s\033[0m\n' "$*"; }

echo "== Transcription offline smoke test =="
echo "  BASE_URL = $BASE_URL"
echo "  WAV      = $WAV"
if [ -n "$API_TOKEN" ]; then echo "  API_TOKEN= set (${#API_TOKEN} chars)"; else ylw "  API_TOKEN= EMPTY (only works if service was started without a token)"; fi
echo

# 0) WAV present?
if [ ! -f "$WAV" ]; then
  red "WAV bulunamadı: $WAV"
  echo "  Repodan gelmeli: services/transcription-service/tests/tr_test.wav"
  exit 1
fi

# 1) Container running? (best-effort)
if command -v docker >/dev/null 2>&1; then
  if ! docker ps --format '{{.Names}}' | grep -qx "$WORKER"; then
    ylw "Uyarı: '$WORKER' 'docker ps'te yok. Servis ayakta mı?"
    echo "  Kontrol: docker compose -f docker-compose.offline.yml ps"
  fi
fi

# 2) Health — wait for the model to finish loading (max ~120s)
echo "== 1) Health (model yüklenmesini bekliyorum, ~1 dk sürebilir) =="
H=""; healthy=false
for _ in $(seq 1 60); do
  H="$(curl -s --max-time 5 "$BASE_URL/health" 2>/dev/null || true)"
  if printf '%s' "$H" | grep -q '"healthy"'; then healthy=true; break; fi
  printf '.'; sleep 2
done
echo
if [ "$healthy" != true ]; then
  red "Health 'healthy' olmadı. Son cevap: ${H:-<boş>}"
  echo "  Olası sebep: model hâlâ yükleniyor ya da GPU hatası."
  echo "  Loglara bak:  docker logs --tail 80 $WORKER"
  exit 1
fi
printf '%s\n' "$H"
grn "Health OK"
echo

# 3) Transcribe — capture HTTP status AND body separately so nothing is silent
echo "== 2) Türkçe transkripsiyon =="
AUTH=(); [ -n "$API_TOKEN" ] && AUTH=(-H "X-API-Key: $API_TOKEN")
BODY="$(mktemp)"; ERR="$(mktemp)"
CODE="$(curl -sS -o "$BODY" -w '%{http_code}' --max-time 120 \
  -X POST "$BASE_URL/v1/audio/transcriptions" \
  "${AUTH[@]}" \
  -F "file=@$WAV" -F model=whisper-1 \
  -F response_format=verbose_json -F timestamp_granularities=word 2>"$ERR" || true)"

echo "HTTP status: ${CODE:-<bağlantı yok>}"
if [ "${CODE:-000}" != 200 ]; then
  red "200 değil — sorun burada."
  echo "--- cevap gövdesi ---"; cat "$BODY"; echo
  echo "--- curl hatası ---"; cat "$ERR"
  case "${CODE:-000}" in
    401|403) ylw "Token uyuşmuyor: container'ı başlatırken verdiğin API_TOKEN ile buradaki AYNI olmalı." ;;
    000)     ylw "Bağlantı kurulamadı: servis ayakta mı, port 8083 doğru mu, firewall?" ;;
    5*)      ylw "Sunucu hatası: model yüklenememiş olabilir → docker logs $WORKER" ;;
  esac
  rm -f "$BODY" "$ERR"; exit 1
fi

# Pretty print
if command -v python3 >/dev/null 2>&1; then python3 -m json.tool < "$BODY" || cat "$BODY"; else cat "$BODY"; fi
echo

# 4) Validate
read -r LANG NWORDS TEXT < <(python3 - "$BODY" <<'PY' 2>/dev/null
import json,sys
d=json.load(open(sys.argv[1]))
n=sum(len(s.get("words",[])) for s in d.get("segments",[]))
print(d.get("language",""), n, d.get("text","").strip())
PY
)
echo "== 3) Sonuç =="
echo "  language   : ${LANG:-?}"
echo "  word count : ${NWORDS:-0}"
echo "  text       : ${TEXT:-<boş>}"
ok=true
[ "${LANG:-}" = tr ]        || { red "  ✗ dil 'tr' değil"; ok=false; }
[ "${NWORDS:-0}" -gt 0 ] 2>/dev/null || { red "  ✗ kelime zaman damgası yok"; ok=false; }
[ -n "${TEXT:-}" ]          || { red "  ✗ metin boş"; ok=false; }
rm -f "$BODY" "$ERR"
echo
if [ "$ok" = true ]; then grn "✓ TÜM KONTROLLER GEÇTİ — transcription çalışıyor."; else red "✗ Bazı kontroller başarısız (yukarıya bak)."; exit 1; fi

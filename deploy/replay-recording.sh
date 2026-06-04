#!/usr/bin/env bash
# Pull a REAL recorded meeting audio from MinIO and replay it DIRECTLY through
# the Whisper service — bypassing the bot, meeting-api, captions and proxy.
# This isolates pure Whisper quality on real audio.
# Run on the COMPOSE server:  bash deploy/replay-recording.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
ENV="$ROOT/.env"
AK="$(grep -E '^MINIO_ACCESS_KEY=' "$ENV" | cut -d= -f2-)"; AK="${AK:-vexa-access-key}"
SK="$(grep -E '^MINIO_SECRET_KEY=' "$ENV" | cut -d= -f2-)"; SK="${SK:-vexa-secret-key}"
BUCKET="$(grep -E '^MINIO_BUCKET=' "$ENV" | cut -d= -f2-)"; BUCKET="${BUCKET:-vexa}"
WURL="$(grep -E '^TRANSCRIPTION_SERVICE_URL=' "$ENV" | cut -d= -f2-)"
WTOK="$(grep -E '^TRANSCRIPTION_SERVICE_TOKEN=' "$ENV" | cut -d= -f2-)"
QURL="$(grep -E '^QWEN_TRANSCRIPTION_SERVICE_URL=' "$ENV" | cut -d= -f2-)"
QTOK="$(grep -E '^QWEN_TRANSCRIPTION_SERVICE_TOKEN=' "$ENV" | cut -d= -f2-)"
LANG="${LANG_CODE:-tr}"

MINIO_C="$(docker ps --filter ancestor=minio/minio:latest --format '{{.Names}}' | head -1)"
[ -z "$MINIO_C" ] && { echo "minio container yok"; exit 1; }
NET="$(docker inspect "$MINIO_C" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' | head -1)"
echo "minio=$MINIO_C net=$NET"

mcrun(){ docker run --rm --network "$NET" -v "$PWD:/out" \
  -e HTTP_PROXY= -e HTTPS_PROXY= -e http_proxy= -e https_proxy= -e NO_PROXY='*' -e no_proxy='*' \
  --entrypoint sh minio/mc:latest -c \
  "mc alias set v http://minio:9000 '$AK' '$SK' >/dev/null 2>&1; $1"; }

echo
echo "== Kayıtlı ses dosyaları (son 15) =="
LIST="$(mcrun "mc ls --recursive v/$BUCKET/ 2>/dev/null | grep -iE 'audio/.*\.webm'")"
echo "$LIST" | tail -15
KEY="$(echo "$LIST" | grep -i 'master.webm' | tail -1 | awk '{print $NF}')"
[ -z "$KEY" ] && KEY="$(echo "$LIST" | tail -1 | awk '{print $NF}')"
[ -z "$KEY" ] && { echo "Kayıt bulunamadı (recording açık bir toplantı yaptın mı?)"; exit 1; }

echo
echo "== İndiriliyor: $KEY =="
mcrun "mc cp 'v/$BUCKET/$KEY' /out/real-meeting.webm >/dev/null 2>&1 && echo indi" || { echo "indirme başarısız"; exit 1; }
ls -la real-meeting.webm

hit(){  # name url token
  [ -z "$2" ] && { echo "  ($1 URL yok, atlandı)"; return; }
  echo; echo "===== $1 ====="
  local body; body="$(mktemp)"
  local code; code="$(curl -s -o "$body" -w '%{http_code}' --max-time 300 -X POST "$2" \
    -H "X-API-Key: $3" -F file=@real-meeting.webm -F model=whisper-1 -F "language=$LANG" \
    -F response_format=verbose_json)"
  echo "HTTP $code"
  python3 -c "import json;d=json.load(open('$body'));print('lang:',d.get('language'));print('text:',(d.get('text') or '').strip())" 2>/dev/null || cat "$body"
  rm -f "$body"
}

echo
echo "######## SAF STT — gerçek toplantı sesi, doğrudan (bot/proxy/altyazı YOK) ########"
hit "WHISPER (mevcut)" "$WURL" "$WTOK"
hit "QWEN"             "$QURL" "$QTOK"
echo
echo "→ Bu metin = STT'nin gerçek toplantı sesindeki HAM kalitesi. Botla/altyazıyla alakası yok."

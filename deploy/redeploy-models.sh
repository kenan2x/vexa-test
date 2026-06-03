#!/usr/bin/env bash
# Force-deploy the per-bot-model images (dashboard + meeting-api) and verify.
# Fixes "make all didn't recreate the dashboard / no Model dropdown".
# Run from repo root:  bash deploy/redeploy-models.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
ENV_FILE="$ROOT/.env"
COMPOSE="docker compose --env-file $ENV_FILE -f $ROOT/deploy/compose/docker-compose.yml"
DASH_IMG="ghcr.io/kenan2x/vexa-dashboard:per-bot-model"
MEET_IMG="ghcr.io/kenan2x/vexa-meeting-api:per-bot-model"

red(){ printf '\033[31m%s\033[0m\n' "$*"; }; grn(){ printf '\033[32m%s\033[0m\n' "$*"; }; ylw(){ printf '\033[33m%s\033[0m\n' "$*"; }

[ -f "$ENV_FILE" ] || { red ".env yok: $ENV_FILE"; exit 1; }

# clean paste artifacts that silently break things
sed -i -e 's/\r$//' -e 's/[[:space:]]*$//' "$ENV_FILE"

ensure() {  # key value  → set or append in .env
  local k="$1" v="$2"
  if grep -qE "^$k=" "$ENV_FILE"; then
    sed -i "s|^$k=.*|$k=$v|" "$ENV_FILE"
  else
    echo "$k=$v" >> "$ENV_FILE"
  fi
}

echo "== [1/4] .env image override'ları ayarlanıyor =="
ensure DASHBOARD_IMAGE "$DASH_IMG"
ensure MEETING_IMAGE   "$MEET_IMG"
grep -E '^(DASHBOARD_IMAGE|MEETING_IMAGE)=' "$ENV_FILE" | sed 's/^/    /'
if ! grep -qE '^QWEN_TRANSCRIPTION_SERVICE_URL=.*://' "$ENV_FILE"; then
  ylw "    UYARI: QWEN_TRANSCRIPTION_SERVICE_URL .env'de dolu değil → qwen seçince whisper'a düşer."
fi

echo
echo "== [2/4] image'lar çekiliyor (ghcr) =="
if docker pull "$DASH_IMG" >/dev/null 2>&1; then grn "    dashboard  ✓"; else red "    dashboard pull FAIL — 'echo <TOKEN> | docker login ghcr.io -u kenan2x --password-stdin' yaptın mı?"; fi
if docker pull "$MEET_IMG" >/dev/null 2>&1; then grn "    meeting-api ✓"; else red "    meeting-api pull FAIL"; fi

echo
echo "== [3/4] dashboard + meeting-api ZORLA yeniden oluşturuluyor =="
$COMPOSE up -d --force-recreate dashboard meeting-api 2>&1 | tail -6

echo
echo "== [4/4] doğrulama =="
$COMPOSE ps dashboard meeting-api 2>/dev/null
echo
RUN_IMG="$(docker ps --filter 'name=dashboard' --format '{{.Image}}' | head -1)"
echo "çalışan dashboard image: ${RUN_IMG:-<bulunamadı>}"
if printf '%s' "$RUN_IMG" | grep -q "per-bot-model"; then
  grn "✓ YENİ image çalışıyor. Tarayıcıda Ctrl+Shift+R (sert yenile) → 'Join Meeting' modalında 'Transcription Model' menüsü gelecek."
else
  red "✗ Hâlâ eski image. .env'deki DASHBOARD_IMAGE satırı:"
  grep -nE 'DASHBOARD_IMAGE' "$ENV_FILE" || echo "  (DASHBOARD_IMAGE satırı YOK)"
  echo "  Bu çıktıyı bana gönder."
fi

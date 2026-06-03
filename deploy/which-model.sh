#!/usr/bin/env bash
# Why isn't the bot using Qwen? Run on the COMPOSE server (best) or the Qwen GPU
# server — it auto-detects and runs the relevant checks.
#   bash deploy/which-model.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
ENV_FILE="$ROOT/.env"
red(){ printf '\033[31m%s\033[0m\n' "$*"; }; grn(){ printf '\033[32m%s\033[0m\n' "$*"; }; ylw(){ printf '\033[33m%s\033[0m\n' "$*"; }

NAMES="$(docker ps --format '{{.Names}}' 2>/dev/null)"

# ───────────────────────── QWEN GPU server checks ─────────────────────────
if printf '%s' "$NAMES" | grep -q '^qwen-asr$'; then
  echo "######## [QWEN GPU sunucusu] ########"
  TX="$(docker logs --since 5m qwen-asr 2>&1 | grep -c 'audio/transcriptions' || true)"
  HZ="$(docker logs --since 5m qwen-asr 2>&1 | grep -c '/health' || true)"
  echo "  son 5 dk: transkripsiyon isteği=$TX   health=$HZ"
  if [ "${TX:-0}" -gt 0 ]; then
    grn "  ✓ Qwen transkripsiyon isteği ALIYOR → bot Qwen'i kullanıyor."
  else
    red "  ✗ Qwen'e SADECE health geliyor, transkripsiyon YOK → bot Qwen'e gitmiyor."
    echo "    Sebebi COMPOSE sunucusunda → bu script'i orada da çalıştır."
  fi
  echo
fi

# ───────────────────────── COMPOSE server checks ─────────────────────────
if printf '%s' "$NAMES" | grep -qE 'meeting-api'; then
  echo "######## [COMPOSE sunucusu] ########"
  COMPOSE="docker compose --env-file $ENV_FILE -f $ROOT/deploy/compose/docker-compose.yml"

  echo "== 1) Servis image'ları (per-bot-model olmalı) =="
  MI="$(docker ps --filter name=meeting-api --format '{{.Image}}' | head -1)"
  DI="$(docker ps --filter name=dashboard   --format '{{.Image}}' | head -1)"
  echo "   meeting-api: $MI";  printf '%s' "$MI" | grep -q per-bot-model && grn "     ✓ yeni" || red "     ✗ ESKİ image → transcription_model'i YOK SAYAR (hep whisper)!"
  echo "   dashboard  : $DI";  printf '%s' "$DI" | grep -q per-bot-model && grn "     ✓ yeni" || red "     ✗ ESKİ image → formda model menüsü yok (qwen gönderilmez)!"

  echo
  echo "== 2) .env Qwen URL =="
  QURL="$(grep -E '^QWEN_TRANSCRIPTION_SERVICE_URL=' "$ENV_FILE" | cut -d= -f2-)"
  if [ -n "$QURL" ]; then grn "   QWEN_TRANSCRIPTION_SERVICE_URL=$QURL"; else red "   ✗ QWEN_TRANSCRIPTION_SERVICE_URL YOK → qwen seçince whisper'a düşer!"; fi

  echo
  echo "== 3) Compose sunucusundan Qwen'e erişim =="
  if [ -n "$QURL" ]; then
    HQ="$(printf '%s' "$QURL" | sed 's#/v1/.*#/health#')"
    if curl -s --max-time 6 "$HQ" | grep -q healthy; then grn "   ✓ $HQ → healthy (erişim var)"; else red "   ✗ $HQ erişilemiyor (firewall/IP/port?) → bot da ulaşamaz"; fi
  else
    ylw "   (QWEN URL yok, atlanıyor)"
  fi

  echo
  echo "== 4) meeting-api: fallback uyarısı (qwen→whisper) =="
  $COMPOSE logs --tail 300 meeting-api 2>&1 | grep -iE 'falling back' | tail -5 || true
  $COMPOSE logs --tail 300 meeting-api 2>&1 | grep -qiE 'falling back' && red "   ↑ qwen istendi ama whisper'a düşülmüş (URL boş)" || grn "   (fallback uyarısı yok)"

  echo
  echo "== 5) Son meeting'lerin seçilen modeli =="
  KEY="$(grep -E '^VEXA_API_KEY=' "$ENV_FILE" | cut -d= -f2-)"
  APIP="$(grep -E '^API_GATEWAY_HOST_PORT=' "$ENV_FILE" | cut -d= -f2-)"; APIP="${APIP:-8056}"
  if [ -n "$KEY" ]; then
    curl -s -H "X-API-Key: $KEY" "http://localhost:$APIP/bots?limit=5" 2>/dev/null | python3 - <<'PY' 2>/dev/null || echo "   (okunamadı)"
import sys,json
d=json.load(sys.stdin)
items=d if isinstance(d,list) else d.get("bots") or d.get("items") or d.get("meetings") or []
if not items: print("   (meeting bulunamadı)")
for m in items[:5]:
    mid=m.get("id"); data=m.get("data") or {}
    print(f"   meeting {mid}: transcription_model = {data.get('transcription_model','?')}")
PY
  else
    ylw "   (.env'de VEXA_API_KEY yok, atlanıyor)"
  fi
  echo
  echo "→ 5'te 'qwen' görüyorsan ama Qwen logunda istek yoksa: erişim sorunu (3'e bak)."
  echo "  '?' veya 'whisper' görüyorsan: ya eski image (1) ya boş URL (2) ya formda whisper seçili."
fi

printf '%s' "$NAMES" | grep -qE 'qwen-asr|meeting-api' || red "Bu sunucuda ne qwen-asr ne meeting-api var — yanlış sunucu olabilir."

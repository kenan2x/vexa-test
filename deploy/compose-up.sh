#!/usr/bin/env bash
# =============================================================================
# Vexa COMPOSE server one-shot bootstrap.
# Run from the repo root:   bash deploy/compose-up.sh
#
# What it does (idempotent — safe to re-run):
#   1. Sanitizes .env (strips stray trailing '$', CRLF, trailing spaces that
#      sneak in via copy-paste and break YAML parsing)
#   2. Checks the must-fill values are actually filled
#   3. Validates the compose file parses
#   4. Brings the stack up (make all)
#   5. Ensures VEXA_API_KEY exists (re-runs setup-api-key if the first pass
#      raced admin-api startup)
#   6. Prints dashboard/API URLs + service status
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
ENV_FILE="$ROOT/.env"
COMPOSE="docker compose --env-file $ENV_FILE -f $ROOT/deploy/compose/docker-compose.yml"

red(){ printf '\033[31m%s\033[0m\n' "$*"; }
grn(){ printf '\033[32m%s\033[0m\n' "$*"; }
ylw(){ printf '\033[33m%s\033[0m\n' "$*"; }

echo "== Vexa compose bootstrap =="

# 0) .env present?
if [ ! -f "$ENV_FILE" ]; then
  red ".env yok. Önce:  cp deploy/env-offline-compose.example .env  &&  nano .env"
  exit 1
fi

# 1) Sanitize .env — the copy-paste killers
cp "$ENV_FILE" "$ENV_FILE.bak"
sed -i -e 's/\r$//' -e 's/\$$//' -e 's/[[:space:]]*$//' "$ENV_FILE"
grn "[1/6] .env temizlendi (satır sonu \$, CR, boşluk).  Yedek: .env.bak"

# 2) Required values filled? (not blank, no leftover <...> placeholder)
miss=0
for k in TRANSCRIPTION_SERVICE_URL TRANSCRIPTION_SERVICE_TOKEN BOT_PROXY_SERVER; do
  v="$(grep -E "^$k=" "$ENV_FILE" | head -1 | cut -d= -f2-)"
  if [ -z "$v" ] || printf '%s' "$v" | grep -q '[<> ]'; then
    red "  ✗ $k doldurulmamış / boşluk içeriyor:  '$v'"
    miss=1
  fi
done
if [ "$miss" = 1 ]; then
  red "[2/6] .env'deki <...> değerlerini doldur (boşluksuz), sonra tekrar çalıştır."
  exit 1
fi
grn "[2/6] .env zorunlu alanlar dolu"

# 3) Validate compose
if ! $COMPOSE config >/dev/null 2>/tmp/vexa_cfg_err; then
  red "[3/6] Compose parse HATASI:"; head -15 /tmp/vexa_cfg_err; exit 1
fi
grn "[3/6] compose config OK"

# 4) Bring up
echo "[4/6] make all (servisleri kaldırıyor, ilk seferde uzun sürebilir)..."
if ! make all; then
  ylw "[4/6] 'make all' uyarı/hata verdi — yine de durumu kontrol ediyorum."
fi

# 5) Ensure VEXA_API_KEY (re-run if it raced admin-api on first boot)
if ! grep -qE '^VEXA_API_KEY=.+' "$ENV_FILE"; then
  ylw "[5/6] VEXA_API_KEY yok — setup-api-key tekrar deneniyor..."
  make -C deploy/compose setup-api-key || true
fi
if grep -qE '^VEXA_API_KEY=.+' "$ENV_FILE"; then
  grn "[5/6] VEXA_API_KEY hazır (dashboard girişi tutar)"
else
  ylw "[5/6] VEXA_API_KEY hâlâ üretilemedi. admin-api loglarına bak:"
  echo "       $COMPOSE logs --tail=40 admin-api"
fi

# 6) Summary
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
DASH="$(grep -E '^DASHBOARD_HOST_PORT=' "$ENV_FILE" | cut -d= -f2)"; DASH="${DASH:-3021}"
APIP="$(grep -E '^API_GATEWAY_HOST_PORT=' "$ENV_FILE" | cut -d= -f2)"; APIP="${APIP:-8056}"
echo
grn "[6/6] HAZIR"
echo "  Dashboard : http://${IP:-<sunucu-ip>}:$DASH"
echo "  API docs  : http://${IP:-<sunucu-ip>}:$APIP/docs"
echo
echo "Servis durumu:"
$COMPOSE ps
echo
echo "İpucu: GPU transcription erişimini de doğrula:"
echo "  curl -s \$(grep ^TRANSCRIPTION_SERVICE_URL= .env | cut -d= -f2 | sed 's#/v1/.*#/health#')"

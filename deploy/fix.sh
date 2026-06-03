#!/usr/bin/env bash
# Post-bringup fixes:
#   1. Recreate tts-service with the corrected compose (Turkish-only, no shadow volume)
#   2. Create VEXA_API_KEY via admin-api DIRECTLY (the gateway /admin path is
#      blocked by the outbound proxy), write it to .env, restart dashboard
#   3. Diagnose whether the gateway container has a proxy env that would also
#      break /bots forwarding
# Run from repo root:  bash deploy/fix.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
ENV_FILE="$ROOT/.env"
COMPOSE="docker compose --env-file $ENV_FILE -f $ROOT/deploy/compose/docker-compose.yml"
ADMIN="$(grep -E '^ADMIN_TOKEN=' "$ENV_FILE" | cut -d= -f2-)"
ADMP="$(grep -E '^ADMIN_API_PORT=' "$ENV_FILE" | cut -d= -f2-)"; ADMP="${ADMP:-8057}"
A="http://localhost:$ADMP"

red(){ printf '\033[31m%s\033[0m\n' "$*"; }; grn(){ printf '\033[32m%s\033[0m\n' "$*"; }; ylw(){ printf '\033[33m%s\033[0m\n' "$*"; }

echo "== Vexa fix =="

# 1) Recreate tts-service with the fixed compose
echo "[1/4] tts-service yeniden oluşturuluyor (Türkçe-only)..."
$COMPOSE up -d --force-recreate tts-service >/dev/null 2>&1
sleep 6
ST="$($COMPOSE ps tts-service --format '{{.Status}}' 2>/dev/null | head -1)"
echo "    durum: $ST"
case "$ST" in
  *Restarting*|*Exited*) ylw "    tts hâlâ sorunlu. Log:  $COMPOSE logs --tail=25 tts-service" ;;
  *Up*|*running*)        grn "    tts ayakta ✓" ;;
  *)                     ylw "    durum belirsiz: $ST" ;;
esac

# 2) Find-or-create user via admin-api DIRECT (gateway /admin is proxy-blocked)
echo "[2/4] kullanıcı (admin-api direct, port $ADMP)..."
USERID="$(curl -s "$A/admin/users?limit=1" -H "X-Admin-API-Key: $ADMIN" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['id'] if d else '')" 2>/dev/null)"
if [ -z "$USERID" ]; then
  USERID="$(curl -s -X POST "$A/admin/users" -H "X-Admin-API-Key: $ADMIN" -H "Content-Type: application/json" \
    -d '{"email":"admin@vexa.ai","name":"Admin","max_concurrent_bots":10}' \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)"
fi
if [ -z "$USERID" ]; then red "    kullanıcı alınamadı (admin token? ADMIN_TOKEN=$ADMIN)"; exit 1; fi
grn "    user id = $USERID"

# 3) Create token, write VEXA_API_KEY to .env
echo "[3/4] token üret + .env'e yaz..."
TOK="$(curl -s -X POST "$A/admin/users/$USERID/tokens?scopes=bot,browser,tx&name=dashboard-ws" \
  -H "X-Admin-API-Key: $ADMIN" | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null)"
if [ -z "$TOK" ]; then red "    token üretilemedi"; exit 1; fi
sed -i '/^VEXA_API_KEY=/d' "$ENV_FILE"
echo "VEXA_API_KEY=$TOK" >> "$ENV_FILE"
grn "    VEXA_API_KEY yazıldı (${#TOK} karakter)"

# 4) Restart dashboard so it picks up VEXA_API_KEY
echo "[4/4] dashboard yeniden başlatılıyor..."
$COMPOSE up -d --force-recreate dashboard >/dev/null 2>&1 && grn "    dashboard yenilendi ✓"

# Diagnostic — the gateway's proxy env decides whether /bots forwarding works
echo
echo "== TEŞHİS: gateway container proxy env =="
echo "(BOŞ olmalı. Doluysa gateway iç çağrıları proxy'e gidiyor → /admin 403 + /bots da kırılır)"
$COMPOSE exec -T api-gateway sh -c 'env | grep -iE "http_proxy|https_proxy|no_proxy|HTTP_PROXY|HTTPS_PROXY|NO_PROXY"' 2>/dev/null || echo "  (proxy env YOK — iyi haber)"

echo
grn "Bitti."
echo "Şimdi panele EMAIL ile tekrar gir — token + dashboard yenilendi, bounce olmamalı."
echo "Yukarıdaki TEŞHİS'te proxy env GÖRÜNÜYORSA bana söyle — /bots göndermeden onu da çözeriz."

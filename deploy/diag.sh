#!/usr/bin/env bash
# Diagnostics for the two open issues: API-key/user creation + tts crash.
# Run from repo root:  bash deploy/diag.sh > test 2>&1   (then git add/commit/push test)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
ENV_FILE="$ROOT/.env"
COMPOSE="docker compose --env-file $ENV_FILE -f $ROOT/deploy/compose/docker-compose.yml"
ADMIN="$(grep -E '^ADMIN_TOKEN=' "$ENV_FILE" | cut -d= -f2-)"
APIP="$(grep -E '^API_GATEWAY_HOST_PORT=' "$ENV_FILE" | cut -d= -f2-)"; APIP="${APIP:-8056}"
ADMP="$(grep -E '^ADMIN_API_PORT=' "$ENV_FILE" | cut -d= -f2-)"; ADMP="${ADMP:-8057}"

echo "############ 1) Admin user-create via GATEWAY (full status+body) ############"
curl -i -s -X POST "http://localhost:$APIP/admin/users" \
  -H "X-Admin-API-Key: $ADMIN" -H "Content-Type: application/json" \
  -d '{"email":"admin@vexa.ai","name":"Admin","max_concurrent_bots":10}' 2>&1 | head -25

echo; echo "############ 2) Admin user-create DIRECT to admin-api (bypass gateway) ############"
curl -i -s -X POST "http://localhost:$ADMP/admin/users" \
  -H "X-Admin-API-Key: $ADMIN" -H "Content-Type: application/json" \
  -d '{"email":"admin@vexa.ai","name":"Admin","max_concurrent_bots":10}' 2>&1 | head -25

echo; echo "############ 3) admin-api ENV (token karsilastir) ############"
$COMPOSE exec -T admin-api sh -c 'env | grep -iE "ADMIN|TOKEN|INTERNAL|DB_" | sort' 2>&1 | head -20
echo "   .env ADMIN_TOKEN=[$ADMIN]"

echo; echo "############ 4) admin-api LOGS (tail) ############"
$COMPOSE logs --tail=40 admin-api 2>&1 | tail -40

echo; echo "############ 5) tts-service LOGS (neden crash) ############"
$COMPOSE logs --tail=50 tts-service 2>&1 | tail -50

echo; echo "############ 6) tts-service durum ############"
$COMPOSE ps tts-service 2>&1 | tail -3

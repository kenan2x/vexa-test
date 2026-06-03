#!/usr/bin/env bash
# Diagnose "no transcript": gathers the bot container + meeting-api + runtime-api
# logs and highlights the transcription path. Run from repo root:
#   bash deploy/logs.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
COMPOSE="docker compose --env-file $ROOT/.env -f $ROOT/deploy/compose/docker-compose.yml"
BOT_IMG="${BROWSER_IMAGE:-ghcr.io/kenan2x/vexa-bot:offline}"

echo "######## 1) Çalışan BOT container'ları ########"
docker ps --filter "ancestor=$BOT_IMG" --format '  {{.Names}}   {{.Status}}' 2>/dev/null
docker ps --format '{{.Names}}' | grep -iE 'vexa-bot|bot-' | grep -viE 'telegram-bot' | sed 's/^/  (isimle) /'
BOT="$(docker ps --filter "ancestor=$BOT_IMG" --format '{{.Names}}' | head -1)"
[ -z "$BOT" ] && BOT="$(docker ps --format '{{.Names}}' | grep -iE 'vexa-bot|bot-' | grep -viE 'telegram-bot' | head -1)"

echo
echo "######## 2) BOT logu — toplantıya girdi mi, ses + STT çağrısı ########"
if [ -n "$BOT" ]; then
  echo "bot: $BOT"
  echo "--- ilgili satırlar (join/audio/transcription/error) ---"
  docker logs --tail 200 "$BOT" 2>&1 | grep -iE 'transcri|whisper|qwen|audio|segment|caption|admit|join|error|fail|refused|timeout|proxy|:808[34]|ECONN|ENOTFOUND' | tail -45
  echo "--- bot logunun son 15 satırı (genel) ---"
  docker logs --tail 15 "$BOT" 2>&1
else
  echo "  ⚠ Çalışan bot container'ı YOK → bot toplantıya hiç girememiş olabilir (proxy/Teams erişimi?)."
  echo "    runtime-api logu (aşağıda 4) spawn hatası gösterir."
fi

echo
echo "######## 3) meeting-api — hangi STT'ye yönlendirdi + collector ########"
$COMPOSE logs --tail 80 meeting-api 2>&1 | grep -iE 'transcri|qwen|whisper|segment|collector|error|exception|503|404|callback|bot' | tail -30

echo
echo "######## 4) runtime-api — bot spawn ########"
$COMPOSE logs --tail 40 runtime-api 2>&1 | grep -iE 'spawn|create|bot|error|fail|exit|oom|container|proxy' | tail -25

echo
echo "######## 5) Hızlı kontrol — bot'a verilen transcription URL'i nereye gidiyor? ########"
if [ -n "$BOT" ]; then
  docker exec "$BOT" sh -c 'echo "$BOT_CONFIG" 2>/dev/null | head -c 400' 2>/dev/null | grep -oE '"transcriptionServiceUrl":"[^"]*"' || echo "  (BOT_CONFIG'ten URL okunamadı)"
fi
echo
echo "→ İpuçları: 'ECONNREFUSED/timeout/:8084' görürsen bot Qwen sunucusuna ulaşamıyor (firewall/IP)."
echo "  'transcriptionServiceUrl' qwen IP'sini gösteriyorsa ama transkript yoksa → o sunucuya erişim/sertifika/sorunu."

#!/usr/bin/env bash
# Run on the COMPOSE server WHILE a bot is in a meeting. Pinpoints why the
# transcript isn't using your STT: which URL the bot got, whether it connected,
# and whether audio segments were confirmed (vs discarded → caption fallback).
#   bash deploy/bot-stt-check.sh
set -uo pipefail
red(){ printf '\033[31m%s\033[0m\n' "$*"; }; grn(){ printf '\033[32m%s\033[0m\n' "$*"; }; ylw(){ printf '\033[33m%s\033[0m\n' "$*"; }

BOT="$(docker ps --filter "ancestor=${BROWSER_IMAGE:-ghcr.io/kenan2x/vexa-bot:offline}" --format '{{.Names}}' | head -1)"
[ -z "$BOT" ] && BOT="$(docker ps --format '{{.Names}}' | grep -iE 'meeting-[0-9]|vexa-bot' | grep -viE 'telegram' | head -1)"
[ -z "$BOT" ] && { red "Çalışan bot container'ı yok — önce toplantıya bot gönder, sonra (bot toplantıdayken) bu script'i çalıştır."; exit 1; }
echo "bot container: $BOT"
echo

echo "== 1) Bota VERİLEN transcription URL'i (8083=Whisper / 8084=Qwen) =="
ENVD="$(docker inspect "$BOT" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null)"
URL="$(printf '%s' "$ENVD" | grep -oE '"transcriptionServiceUrl": *"[^"]*"' | head -1)"
if [ -n "$URL" ]; then
  echo "   $URL"
  printf '%s' "$URL" | grep -q ':8084' && grn "   → QWEN'e yönlendirilmiş ✓" || { printf '%s' "$URL" | grep -q ':8083' && ylw "   → WHISPER'a yönlendirilmiş (Qwen değil!)" || ylw "   → başka bir URL"; }
else
  red "   transcriptionServiceUrl okunamadı. Ham BOT_CONFIG:"
  printf '%s' "$ENVD" | grep -i BOT_CONFIG | head -c 600; echo
fi
echo

echo "== 2) STT'ye bağlanma — hata var mı? =="
ERR="$(docker logs --tail 300 "$BOT" 2>&1 | grep -iE ':808[34]|ECONNREFUSED|ETIMEDOUT|ENOTFOUND|EHOSTUNREACH|getaddrinfo|transcri.*(error|fail|refus)|whisper.*error|fetch.*fail|timeout' | tail -15)"
if [ -n "$ERR" ]; then red "   ⚠ Bağlantı/STT hataları:"; printf '%s\n' "$ERR" | sed 's/^/     /'; else grn "   (açık bağlantı hatası görünmüyor)"; fi
echo

echo "== 3) Telemetri — audio STT segmentleri ONAYLANDI mı? =="
docker logs --tail 400 "$BOT" 2>&1 | grep -oE 'whisper=[0-9]+ \([0-9]+ms[^|]*\|[^|]*confirmed=[0-9]+ discarded=[0-9]+' | tail -6 | sed 's/^/   /'
echo
echo "   → confirmed>0  : STT metni kullanılıyor (Whisper/Qwen) — iyi"
echo "   → confirmed=0  : STT atılıyor → metin Teams ALTYAZISINDAN geliyor (kalite düşük, Qwen etkisiz)"
echo
echo "== 4) Son birkaç gerçek transkripsiyon satırı (dil/discard) =="
docker logs --tail 400 "$BOT" 2>&1 | grep -iE 'LANGUAGE|LOW CONFIDENCE|discarded|confirmed|emitSegment|onSegmentConfirmed' | tail -12 | sed 's/^/   /'

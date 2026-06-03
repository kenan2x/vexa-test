#!/usr/bin/env bash
# Run on the GPU server (172.30.146.11) — shows which STT actually received the
# bot's audio in the last window. Qwen and Whisper both live here.
#   bash deploy/stt-traffic.sh           # last 10 min
#   bash deploy/stt-traffic.sh 30m       # custom window
set -uo pipefail
WIN="${1:-10m}"
red(){ printf '\033[31m%s\033[0m\n' "$*"; }; grn(){ printf '\033[32m%s\033[0m\n' "$*"; }; ylw(){ printf '\033[33m%s\033[0m\n' "$*"; }

echo "== STT trafiği (son $WIN) — hangi servis transkripsiyon isteği aldı? =="
echo

NAMES="$(docker ps --format '{{.Names}}' 2>/dev/null)"
total=0

check(){ # container label
  local name="$1" label="$2"
  if printf '%s' "$NAMES" | grep -q "^$name$"; then
    local n h
    n=$(docker logs --since "$WIN" "$name" 2>&1 | grep -c 'audio/transcriptions' || true)
    h=$(docker logs --since "$WIN" "$name" 2>&1 | grep -c '/health' || true)
    if [ "${n:-0}" -gt 0 ]; then
      grn "  ✓ [$label]  $name → $n transkripsiyon isteği  (health=$h)"
      docker logs --since "$WIN" "$name" 2>&1 | grep 'audio/transcriptions' | tail -2 | sed 's/^/        /'
      total=$((total+n))
    else
      ylw "  ·  [$label]  $name → 0 transkripsiyon (sadece health=$h)"
    fi
  else
    echo "  -  [$label]  '$name' bu sunucuda yok"
  fi
}

check qwen-asr                "QWEN  :8084"
check transcription-worker-1  "WHISPER worker :8083"
check transcription-lb        "WHISPER nginx  :8083"

echo
if [ "$total" -gt 0 ]; then
  grn "→ İstek alan servis = botun kullandığı model. Yukarıda ✓ olan hangisiyse o."
else
  red "→ HİÇBİRİ transkripsiyon almadı!"
  echo "  O zaman bot başka bir URL'e gidiyor. Compose sunucusunda şunu kontrol et:"
  echo "    grep -E 'TRANSCRIPTION_SERVICE_URL|QWEN_TRANSCRIPTION' .env"
  echo "  (Whisper URL'i 172.30.146.11:8083 mü, yoksa eski vexa.ai/başka IP mi?)"
fi

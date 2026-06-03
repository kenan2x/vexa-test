#!/usr/bin/env bash
# Compare Whisper vs Qwen on the SAME audio (offline replay = fair test).
# Run from anywhere that can reach BOTH services (e.g. the compose box).
#
# Usage:
#   WHISPER_URL=http://<whisper-gpu-ip>:8083/v1/audio/transcriptions WHISPER_TOKEN=<tok> \
#   QWEN_URL=http://<qwen-gpu-ip>:8084/v1/audio/transcriptions       QWEN_TOKEN=<tok> \
#   bash services/qwen-transcription/compare.sh <audio.wav> [lang]
set -uo pipefail

AUDIO="${1:?kullanım: compare.sh <audio.wav> [lang]}"
LANG="${2:-tr}"
WURL="${WHISPER_URL:?WHISPER_URL gerekli (…/v1/audio/transcriptions)}"
WTOK="${WHISPER_TOKEN:-}"
QURL="${QWEN_URL:?QWEN_URL gerekli (…/v1/audio/transcriptions)}"
QTOK="${QWEN_TOKEN:-}"

[ -f "$AUDIO" ] || { echo "ses dosyası yok: $AUDIO"; exit 1; }

hit() {  # name url token
  local name="$1" url="$2" tok="$3" body meta code secs
  body="$(mktemp)"
  meta="$(curl -s -o "$body" -w '%{http_code} %{time_total}' --max-time 180 \
    -X POST "$url" -H "X-API-Key: $tok" \
    -F "file=@$AUDIO" -F model=whisper-1 -F "language=$LANG" \
    -F response_format=verbose_json -F timestamp_granularities=word)"
  code="$(echo "$meta" | awk '{print $1}')"
  secs="$(echo "$meta" | awk '{print $2}')"
  echo "===== $name  [HTTP $code · ${secs}s] ====="
  python3 - "$body" <<'PY'
import sys, json
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print("(cevap okunamadı:", e, ")"); sys.exit()
segs = d.get("segments") or []
nw = sum(len(s.get("words") or []) for s in segs)
print(f"kelime-zamanı: {nw}")
print(f"metin: {(d.get('text') or '').strip()}")
PY
  rm -f "$body"
}

echo "######## SES: $AUDIO   (dil=$LANG) ########"
echo
hit "WHISPER (large-v3)" "$WURL" "$WTOK"
echo
hit "QWEN (3-ASR-1.7B)"  "$QURL" "$QTOK"
echo
echo "→ İki metni yan yana oku: özel isimler, teknik terimler, Türkçe ekler,"
echo "  noktalama ve kelime sayısı hangisinde daha doğru? Süre farkına da bak."

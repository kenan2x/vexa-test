#!/usr/bin/env bash
# Qwen STT smoke + timing test. Run ON the GPU box (where qwen-asr runs).
# Checks: health, response time, and that the response has the Vexa format
# (text, language, segments[].words[] with start/end).
#
# Usage:
#   API_TOKEN=<token> bash services/qwen-transcription/smoke.sh
#   API_TOKEN=<token> BASE_URL=http://localhost:8084 bash services/qwen-transcription/smoke.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BASE="${BASE_URL:-http://localhost:8084}"
TOKEN="${API_TOKEN:-${1:-}}"
WAV="${WAV:-$ROOT/services/transcription-service/tests/tr_test.wav}"

echo "== Qwen STT smoke + süre testi =="
echo "  url = $BASE"
echo "  wav = $WAV"
echo

[ -f "$WAV" ] || { echo "WAV yok: $WAV"; exit 1; }

echo "== 1) /health =="
curl -s --max-time 10 "$BASE/health"; echo; echo

echo "== 2) transkripsiyon (zamanlı) =="
BODY="$(mktemp)"
META="$(curl -s -o "$BODY" -w '%{http_code} %{time_total}' --max-time 120 \
  -X POST "$BASE/v1/audio/transcriptions" \
  -H "X-API-Key: $TOKEN" \
  -F "file=@$WAV" -F model=whisper-1 -F language=tr \
  -F response_format=verbose_json -F timestamp_granularities=word)"
CODE="$(echo "$META" | awk '{print $1}')"
SECS="$(echo "$META" | awk '{print $2}')"
echo "HTTP=$CODE   süre=${SECS}s"
echo
echo "--- ham cevap ---"
python3 -m json.tool < "$BODY" 2>/dev/null || cat "$BODY"
echo

echo "== 3) FORMAT kontrolü =="
python3 - "$BODY" <<'PY'
import sys, json
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print("JSON parse FAIL:", e); sys.exit(1)
text = (d.get("text") or "")
lang = d.get("language")
segs = d.get("segments") or []
words = (segs[0].get("words") or []) if segs else []
print(f"  text      : {text[:140]}")
print(f"  language  : {lang}")
print(f"  segments  : {len(segs)}")
print(f"  words     : {len(words)}")
ok = True
if not text: print("  ✗ metin BOŞ"); ok = False
if lang != "tr": print(f"  ✗ dil 'tr' değil ({lang})"); ok = False
if not words:
    print("  ✗ words[] BOŞ → aligner çalışmadı (Teams konuşmacı atfı bunsuz olmaz)"); ok = False
else:
    w = words[0]
    print(f"  ilk kelime: {w}")
    if "start" in w and "end" in w and "word" in w:
        print("  ✓ kelime zaman damgası DOĞRU formatta (word/start/end)")
    else:
        print(f"  ✗ kelime alanları eksik: {list(w.keys())}"); ok = False
print()
print("  ✓ FORMAT TAMAM — Vexa bunu olduğu gibi kullanır." if ok else "  ✗ Format eksik (yukarı bak).")
PY
rm -f "$BODY"

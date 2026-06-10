#!/usr/bin/env bash
#
# capture-bot-audio.sh — "Bot temiz ses alıyor mu?" denetimi.
#
# A vexa-bot container, RAW_CAPTURE=true ile çalıştığında her konuşmacının sesini
# /tmp/raw-capture-{meetingId}/ altına ayrı WAV olarak döker. Spawn edilen bot
# container'ları geçici olduğundan, bu script onları canlıyken yakalayıp kaydı
# dışarı kopyalar ve container kapanınca zip'ler. Sonra WAV'ları kulağınla dinle:
# tek kişi / temiz / kesintisiz ses = temiz yakalama.
#
# ── Ön koşullar (bir kez) ─────────────────────────────────────────────────────
#   1) profiles.yaml'da RAW_CAPTURE passthrough olmalı (bu repoda eklendi).
#   2) runtime-api ortamında RAW_CAPTURE=true olmalı, ör. docker compose için:
#        RAW_CAPTURE=true docker compose up -d runtime-api
#      (veya .env'e RAW_CAPTURE=true ekleyip `docker compose up -d runtime-api`)
#   3) Bu script çalışırken bir Teams/Meet toplantısına bot gönder (dashboard/API).
#
# ── Kullanım ──────────────────────────────────────────────────────────────────
#   ./scripts/capture-bot-audio.sh                 # bot'u bekle, kaydı topla, zip'le
#   OUT_DIR=/data/caps ./scripts/capture-bot-audio.sh
#
set -euo pipefail

OUT_DIR="${OUT_DIR:-./raw-capture-out}"
POLL_SECS="${POLL_SECS:-5}"
CAPTURE_GLOB="/tmp/raw-capture-*"

command -v docker >/dev/null || { echo "HATA: docker bulunamadı."; exit 1; }
mkdir -p "$OUT_DIR"

echo "[*] Bot container'ı bekleniyor (RAW_CAPTURE kaydı olan)…  Ctrl-C ile çık."
echo "[*] Çıktı klasörü: $OUT_DIR"

# Kayıt dizinine sahip çalışan ilk container'ı bul (isimden bağımsız, sağlam).
find_bot() {
  for cid in $(docker ps -q); do
    if docker exec "$cid" sh -c "ls -d $CAPTURE_GLOB" >/dev/null 2>&1; then
      echo "$cid"; return 0
    fi
  done
  return 1
}

BOT_CID=""
while [ -z "$BOT_CID" ]; do
  if BOT_CID="$(find_bot)"; then :; else BOT_CID=""; sleep "$POLL_SECS"; fi
done

NAME="$(docker inspect -f '{{.Name}}' "$BOT_CID" | sed 's#^/##')"
echo "[+] Bot bulundu: $NAME ($BOT_CID)"
echo "[*] Kayıt canlı kopyalanıyor (container kapanana kadar)…"

# Container ölmeden önce veriyi kaybetmemek için sürekli dışarı kopyala.
while docker ps -q --no-trunc | grep -q "$BOT_CID"; do
  for d in $(docker exec "$BOT_CID" sh -c "ls -d $CAPTURE_GLOB" 2>/dev/null); do
    docker cp "$BOT_CID:$d" "$OUT_DIR/" 2>/dev/null || true
  done
  sleep "$POLL_SECS"
done

echo "[+] Bot kapandı. Son kopya alınıyor…"
STAMP="$(date +%Y%m%d-%H%M%S)"
ZIP="$OUT_DIR/raw-capture-$STAMP.zip"
( cd "$OUT_DIR" && zip -rq "raw-capture-$STAMP.zip" raw-capture-* 2>/dev/null ) || {
  echo "[!] zip yok; klasör olarak bırakıldı: $OUT_DIR"; exit 0; }

echo ""
echo "[✓] Hazır: $ZIP"
echo "    İçindeki audio/*.wav dosyalarını dinle:"
echo "      - tek kişi / net / kesintisiz  → temiz yakalama, sorun transkripsiyonda"
echo "      - karışık / cızırtılı / eksik   → Teams ses yakalamada sorun, önce o"

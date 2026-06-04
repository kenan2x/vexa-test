#!/usr/bin/env bash
# Measure the Qwen adapter's drop behaviour from its logs. Run on the GPU box.
# Answers: how many requests came in, how many were transcribed vs SKIPPED, WHY
# they were skipped, and how much silence VAD is cutting (speech vs dur).
#   bash deploy/qwen-stats.sh           # last 2000 log lines
#   N=8000 bash deploy/qwen-stats.sh    # look further back
set -uo pipefail
N="${N:-2000}"
LOG="$(docker logs --tail "$N" qwen-asr 2>&1)"

req=$(printf '%s\n' "$LOG" | grep -c "REQ ")
ok=$(printf  '%s\n' "$LOG" | grep -E "REQ .*words=" | grep -cv "SKIPPED")
sk_short=$(printf '%s\n' "$LOG" | grep -c "SKIPPED (< ")
sk_nospeech=$(printf '%s\n' "$LOG" | grep -c "VAD: no speech")
sk_tiny=$(printf '%s\n' "$LOG" | grep -c "VAD: only ")
errs=$(printf '%s\n' "$LOG" | grep -ciE "vLLM [45][0-9][0-9]|forward failed|alignment failed")

echo "================ Qwen adapter drop özeti (son $N log satırı) ================"
echo "Toplam istek (REQ)        : $req"
echo "  ✓ yazıya çevrildi       : $ok"
echo "  ✗ atıldı — çok kısa(<min): $sk_short    (MIN_AUDIO_SEC altı)"
echo "  ✗ atıldı — VAD sessizlik : $sk_nospeech    (hiç konuşma yok)"
echo "  ✗ atıldı — VAD çok az    : $sk_tiny    (konuşma < eşik süre)"
echo "  ⚠ vLLM/align hatası      : $errs"
echo
echo "-- VAD ne kadar sessizlik kesiyor (son 10 başarılı istek: dur → speech) --"
printf '%s\n' "$LOG" | grep -E "REQ .*words=" | grep -v SKIPPED | tail -10 \
  | sed -E 's/.*dur=([0-9.]+)s speech=([0-9.]+)s.*words=([0-9]+).*/  ham \1s → konuşma \2s   (words=\3)/'
echo
echo "-- Son birkaç gerçek metin (kalite gözüyle bak) --"
printf '%s\n' "$LOG" | grep -E "REQ .*text=" | grep -v SKIPPED | tail -5 \
  | sed -E "s/.*text=('?)(.*)\1$/  • \2/" | cut -c1-160
echo
echo "Yorum: 'VAD sessizlik/çok az' atışları YÜKSEK ve metin az geliyorsa VAD fazla"
echo "agresif → VAD_THRESHOLD'u düşür (0.4→0.3). Halüsinasyon (uydurma metin) varsa →"
echo "tersine VAD_THRESHOLD'u yükselt. İkisi de yoksa ayar iyi demektir."

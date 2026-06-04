#!/usr/bin/env bash
# Watch the Qwen adapter live while a bot is in a meeting. Run on the GPU box.
# Shows one line per request: duration, speech-after-VAD, words, and the text —
# so you can see VAD cutting silence (speech < dur) and whether text is Turkish.
#   bash deploy/qwen-watch.sh
set -uo pipefail
echo "qwen-asr (adapter) canlı log — Ctrl+C ile çık"
echo "Okuma: dur=ham süre  speech=VAD sonrası konuşma  words=timestamp sayısı  SKIPPED=sessiz/kısa atıldı"
echo "------------------------------------------------------------------------------"
# REQ satırları + SKIPPED + hatalar; gürültüyü ele.
docker logs -f --tail 30 qwen-asr 2>&1 | grep --line-buffered -iE "REQ |SKIPPED|vLLM [0-9]|forward failed|alignment failed|VAD"

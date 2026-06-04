#!/usr/bin/env bash
# What's actually in MinIO? Lists the whole bucket + counts recordings, with
# auth/network errors shown (not hidden). Run on the COMPOSE server.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV="$ROOT/.env"
AK="$(grep -E '^MINIO_ACCESS_KEY=' "$ENV" | cut -d= -f2-)"; AK="${AK:-vexa-access-key}"
SK="$(grep -E '^MINIO_SECRET_KEY=' "$ENV" | cut -d= -f2-)"; SK="${SK:-vexa-secret-key}"
BUCKET="$(grep -E '^MINIO_BUCKET=' "$ENV" | cut -d= -f2-)"; BUCKET="${BUCKET:-vexa}"

MC="$(docker ps --filter ancestor=minio/minio:latest --format '{{.Names}}' | head -1)"
[ -z "$MC" ] && { echo "minio container çalışmıyor!"; exit 1; }
NET="$(docker inspect "$MC" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' | head -1)"
echo "minio=$MC  net=$NET  bucket=$BUCKET  ak=$AK"
echo

docker run --rm --network "$NET" --entrypoint sh minio/mc:latest -c "
  mc alias set v http://minio:9000 '$AK' '$SK' || { echo '✗ ALIAS/AUTH FAIL — ag ya da anahtar yanlis'; exit 1; }
  echo '=== bucket listesi ==='
  mc ls v/ || echo '(bucket listelenemedi)'
  echo
  echo '=== $BUCKET içeriği (ilk 50) ==='
  mc ls --recursive v/$BUCKET/ 2>&1 | head -50
  echo
  echo -n '=== recordings altında webm sayısı: '
  mc ls --recursive v/$BUCKET/recordings/ 2>/dev/null | grep -c '\.webm' || echo 0
"

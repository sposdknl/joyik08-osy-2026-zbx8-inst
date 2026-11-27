#!/usr/bin/env bash
set -euo pipefail

HOST="${1:-sposdk.cz}"
PORT="${2:-443}"

END_DATE=$(echo | openssl s_client -servername "$HOST" -connect "${HOST}:${PORT}" 2>/dev/null \
  | openssl x509 -noout -enddate 2>/dev/null \
  | cut -d= -f2)

if [ -z "$END_DATE" ]; then
  echo "0"
  exit 1
fi

END_EPOCH=$(date -d "$END_DATE" +%s)
NOW_EPOCH=$(date +%s)
DIFF_DAYS=$(( (END_EPOCH - NOW_EPOCH) / 86400 ))

echo "$DIFF_DAYS"

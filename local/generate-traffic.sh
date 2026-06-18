#!/usr/bin/env bash
# generate-traffic.sh — Send continuous traffic to the app so Prometheus has data
# Usage: bash local/generate-traffic.sh [requests_per_second]
set -euo pipefail

APP_URL="${APP_URL:-http://localhost:8080}"
RPS="${1:-2}"
INTERVAL=$(echo "scale=3; 1/$RPS" | bc)

echo "Sending ~${RPS} req/s to ${APP_URL}  (Ctrl-C to stop)"
echo ""

i=0
while true; do
  i=$((i + 1))

  # Rotate through different endpoints
  case $((i % 5)) in
    0) curl -sf "${APP_URL}/"         -o /dev/null ;;
    1) curl -sf "${APP_URL}/api/data" -o /dev/null ;;
    2) curl -sf "${APP_URL}/healthz"  -o /dev/null ;;
    3) curl -sf "${APP_URL}/readyz"   -o /dev/null ;;
    4) curl -sf "${APP_URL}/metrics"  -o /dev/null ;;
  esac

  # Every 50 requests print a status line
  if (( i % 50 == 0 )); then
    echo "[$(date +%H:%M:%S)] ${i} requests sent"
  fi

  sleep "${INTERVAL}"
done

#!/usr/bin/env bash
# generate-traffic.sh — Continuous traffic generator for the Self-Healing Deployment Engine
#
# Sends requests to all app endpoints so Prometheus has real data and the
# anomaly detector can train its model.  Prints a live dashboard status
# line every 10 seconds so you can watch metrics change without opening a browser.
#
# Usage:
#   bash compose/generate-traffic.sh [requests_per_second] [app_url]
#
# Examples:
#   bash compose/generate-traffic.sh          # 5 req/s, http://localhost:8080
#   bash compose/generate-traffic.sh 10       # 10 req/s
#   bash compose/generate-traffic.sh 5 http://1.2.3.4:8080   # remote server

set -euo pipefail

APP_URL="${2:-${APP_URL:-http://localhost:8080}}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://localhost:9090}"
DETECTOR_URL="${DETECTOR_URL:-http://localhost:8090}"
RPS="${1:-5}"
INTERVAL=$(echo "scale=4; 1/$RPS" | bc)
STATUS_EVERY=10   # print dashboard status every N seconds

# ── colours ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ── helpers ─────────────────────────────────────────────────────────────────
prom_query() {
  # $1 = PromQL expression; returns scalar value or "n/a"
  local val
  val=$(curl -sf --max-time 3 \
    "${PROMETHEUS_URL}/api/v1/query" \
    --data-urlencode "query=$1" \
    2>/dev/null \
    | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    r = d['data']['result']
    print(r[0]['value'][1] if r else 'n/a')
except:
    print('n/a')
" 2>/dev/null) || val="n/a"
  echo "$val"
}

detector_field() {
  # $1 = JSON key from /status
  curl -sf --max-time 3 "${DETECTOR_URL}/status" 2>/dev/null \
    | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('$1', 'n/a'))
except:
    print('n/a')
" 2>/dev/null || echo "n/a"
}

print_status() {
  local error_rate deployment_score anomaly_score anomaly_detected model_trained total_samples

  # Pull from Prometheus
  error_rate=$(prom_query \
    'round(sum(rate(http_requests_total{status_code=~"5.."}[2m])) / sum(rate(http_requests_total[2m])) * 100, 0.1)')
  anomaly_score=$(prom_query 'anomaly_detector_score')
  anomaly_detected=$(prom_query 'anomaly_detected')

  # Pull from detector API
  deployment_score=$(detector_field "deployment_score")
  model_trained=$(detector_field "model_trained")
  total_samples=$(detector_field "total_samples")

  # Format error rate colour
  local err_colour="$GREEN"
  if [[ "$error_rate" != "n/a" ]]; then
    local err_int
    err_int=$(echo "$error_rate" | cut -d. -f1)
    (( err_int >= 20 )) && err_colour="$RED" || { (( err_int >= 5 )) && err_colour="$YELLOW"; }
  fi

  # Format anomaly colour
  local anm_colour="$GREEN"
  [[ "$anomaly_detected" == "1" ]] && anm_colour="$RED"

  echo ""
  echo -e "${BOLD}${CYAN}──── Dashboard Status [$(date +%H:%M:%S)] ──────────────────────────────${RESET}"
  printf "  %-22s %s\n" "Requests sent:"      "${BOLD}${i}${RESET}"
  printf "  %-22s " "Error Rate:"
  echo -e "${err_colour}${BOLD}${error_rate}%${RESET}"
  printf "  %-22s %s\n" "Deployment Score:"   "${BOLD}${deployment_score}${RESET}"
  printf "  %-22s " "Anomaly Score:"
  echo -e "${anm_colour}${BOLD}${anomaly_score}${RESET}"
  printf "  %-22s " "Anomaly Detected:"
  [[ "$anomaly_detected" == "1" ]] \
    && echo -e "${RED}${BOLD}YES${RESET}" \
    || echo -e "${GREEN}${BOLD}no${RESET}"
  printf "  %-22s %s\n" "Samples collected:"  "${total_samples}"
  printf "  %-22s " "Model trained:"
  [[ "$model_trained" == "True" ]] \
    && echo -e "${GREEN}${BOLD}yes${RESET}" \
    || echo -e "${YELLOW}waiting (need 10+ samples)${RESET}"
  echo -e "${CYAN}────────────────────────────────────────────────────────────────────${RESET}"
}

# ── main ────────────────────────────────────────────────────────────────────
echo -e "${BOLD}Self-Healing Deployment Engine — Traffic Generator${RESET}"
echo -e "App:        ${APP_URL}"
echo -e "Prometheus: ${PROMETHEUS_URL}"
echo -e "Detector:   ${DETECTOR_URL}"
echo -e "Rate:       ${RPS} req/s  (Ctrl-C to stop)"
echo ""

i=0
last_status=$SECONDS

while true; do
  i=$((i + 1))

  # Rotate through endpoints — / and /api/data are subject to failure injection
  case $((i % 6)) in
    0) curl -sf "${APP_URL}/"         -o /dev/null -w "" || true ;;
    1) curl -sf "${APP_URL}/api/data" -o /dev/null -w "" || true ;;
    2) curl -sf "${APP_URL}/"         -o /dev/null -w "" || true ;;
    3) curl -sf "${APP_URL}/api/data" -o /dev/null -w "" || true ;;
    4) curl -sf "${APP_URL}/healthz"  -o /dev/null -w "" || true ;;
    5) curl -sf "${APP_URL}/readyz"   -o /dev/null -w "" || true ;;
  esac

  # Print status every STATUS_EVERY seconds
  if (( SECONDS - last_status >= STATUS_EVERY )); then
    print_status
    last_status=$SECONDS
  fi

  sleep "${INTERVAL}"
done

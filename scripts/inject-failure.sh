#!/usr/bin/env bash
# inject-failure.sh — Inject controlled failures to test self-healing
set -euo pipefail

NAMESPACE="self-healing"
APP_NAME="healing-app"
MODE="${1:-enable}"    # enable | disable
ERROR_RATE="${2:-0.5}" # 0.0 – 1.0

log() { echo "[$(date +%H:%M:%S)] INFO  $*"; }

PORT_FORWARD_PID=""
cleanup() { [[ -n "$PORT_FORWARD_PID" ]] && kill "$PORT_FORWARD_PID" 2>/dev/null; }
trap cleanup EXIT

log "Starting port-forward to ${APP_NAME}..."
kubectl port-forward -n "${NAMESPACE}" "svc/${APP_NAME}" 8080:80 &>/dev/null &
PORT_FORWARD_PID=$!
sleep 2

if [[ "$MODE" == "enable" ]]; then
  log "Injecting ${ERROR_RATE} error rate into ${APP_NAME}..."
  curl -sf -X POST http://localhost:8080/admin/inject-failure \
    -H "Content-Type: application/json" \
    -d "{\"enabled\": true, \"error_rate\": ${ERROR_RATE}}"
  echo ""
  log "Failure injected. Watch self-healing kick in:"
  log "  kubectl argo rollouts get rollout ${APP_NAME} -n ${NAMESPACE} --watch"
  log "  kubectl get pods -n ${NAMESPACE} -w"
else
  log "Disabling failure injection..."
  curl -sf -X POST http://localhost:8080/admin/inject-failure \
    -H "Content-Type: application/json" \
    -d '{"enabled": false}'
  echo ""
  log "Failure mode disabled"
fi

#!/usr/bin/env bash
# rollback.sh — Manually roll back the deployment to a specific or previous revision
set -euo pipefail

NAMESPACE="self-healing"
APP_NAME="healing-app"
REVISION="${1:-0}"   # 0 = previous stable revision

log()  { echo "[$(date +%H:%M:%S)] INFO  $*"; }
warn() { echo "[$(date +%H:%M:%S)] WARN  $*" >&2; }
die()  { echo "[$(date +%H:%M:%S)] ERROR $*" >&2; exit 1; }

log "Initiating manual rollback for ${APP_NAME} (revision=${REVISION})..."

# Show current state before rolling back
CURRENT=$(kubectl argo rollouts get rollout "${APP_NAME}" -n "${NAMESPACE}" 2>/dev/null)
echo "$CURRENT"

echo ""
read -r -p "Confirm rollback? (y/N) " CONFIRM
[[ "${CONFIRM,,}" == "y" ]] || { warn "Rollback cancelled"; exit 0; }

log "Rolling back..."
if [[ "$REVISION" == "0" ]]; then
  kubectl argo rollouts undo "${APP_NAME}" -n "${NAMESPACE}"
else
  kubectl argo rollouts undo "${APP_NAME}" -n "${NAMESPACE}" --to-revision="${REVISION}"
fi

log "Watching rollback status..."
kubectl argo rollouts status "${APP_NAME}" -n "${NAMESPACE}" --timeout 5m --watch

FINAL=$(kubectl argo rollouts get rollout "${APP_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}')
if [[ "$FINAL" == "Healthy" ]]; then
  log "Rollback SUCCESSFUL — service is healthy"
else
  die "Rollback ended in state: ${FINAL}"
fi

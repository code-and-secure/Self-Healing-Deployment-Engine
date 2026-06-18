#!/usr/bin/env bash
# deploy.sh — Build, push, and deploy a new version of the app
set -euo pipefail

NAMESPACE="self-healing"
APP_NAME="healing-app"
REGISTRY="${REGISTRY:-localhost:5000}"
IMAGE_TAG="${1:-$(git rev-parse --short HEAD 2>/dev/null || echo "latest")}"
IMAGE="${REGISTRY}/${APP_NAME}:${IMAGE_TAG}"

log()  { echo "[$(date +%H:%M:%S)] INFO  $*"; }
die()  { echo "[$(date +%H:%M:%S)] ERROR $*" >&2; exit 1; }

log "Deploying ${APP_NAME}:${IMAGE_TAG}..."

# ── Build and push ────────────────────────────────────────────────────────
log "Building Docker image: ${IMAGE}..."
docker build -t "${IMAGE}" app/

log "Pushing image..."
docker push "${IMAGE}"

# ── Deploy via Argo Rollouts ──────────────────────────────────────────────
log "Updating rollout image to ${IMAGE}..."
kubectl argo rollouts set image "${APP_NAME}" \
  "${APP_NAME}=${IMAGE}" \
  -n "${NAMESPACE}"

log "Watching rollout status (Ctrl-C to stop watching; rollout continues)..."
kubectl argo rollouts status "${APP_NAME}" \
  -n "${NAMESPACE}" \
  --timeout 10m \
  --watch || {
    STATUS=$(kubectl argo rollouts get rollout "${APP_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}')
    if [[ "$STATUS" == "Degraded" || "$STATUS" == "Error" ]]; then
      die "Rollout entered ${STATUS} state — auto-rollback should have fired. Check: kubectl argo rollouts get rollout ${APP_NAME} -n ${NAMESPACE}"
    fi
  }

FINAL_STATUS=$(kubectl argo rollouts get rollout "${APP_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}')
log "Rollout finished with status: ${FINAL_STATUS}"

if [[ "$FINAL_STATUS" == "Healthy" ]]; then
  log "Deployment SUCCESSFUL — ${IMAGE} is now stable"
else
  die "Deployment ended in unexpected state: ${FINAL_STATUS}"
fi

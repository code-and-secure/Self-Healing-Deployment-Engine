#!/usr/bin/env bash
# setup-kind.sh — Full local Kubernetes deployment using kind
set -euo pipefail

log()  { echo -e "\n\033[1;32m[$(date +%H:%M:%S)]\033[0m $*"; }
die()  { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

# ── 1. Check prerequisites ────────────────────────────────────────────────
log "Checking prerequisites..."
for tool in docker kind kubectl helm; do
  command -v "$tool" &>/dev/null || die "$tool is not installed. See LOCAL-DEPLOY.md for install instructions."
done
docker info &>/dev/null || die "Docker is not running. Start Docker Desktop."

# ── 2. Create kind cluster ────────────────────────────────────────────────
log "Creating kind cluster 'self-healing'..."
if kind get clusters | grep -q "^self-healing$"; then
  echo "  Cluster already exists — skipping creation"
else
  kind create cluster --config compose/kind-cluster.yaml --wait 2m
fi
kubectl cluster-info --context kind-self-healing

# ── 3. Build Docker images ────────────────────────────────────────────────
log "Building app image..."
docker build -t healing-app:1.0.0 app/

log "Building anomaly-detector image..."
docker build -t anomaly-detector:1.0.0 ml/

# ── 4. Load images into kind (no registry needed) ─────────────────────────
log "Loading images into kind cluster..."
kind load docker-image healing-app:1.0.0 --name self-healing
kind load docker-image anomaly-detector:1.0.0 --name self-healing

# ── 5. Install Prometheus + Grafana via Helm ──────────────────────────────
log "Adding Helm repos..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

log "Installing kube-prometheus-stack..."
kubectl create namespace self-healing --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace self-healing \
  --set grafana.adminPassword=admin \
  --set grafana.service.type=NodePort \
  --set grafana.service.nodePort=30000 \
  --set prometheus.service.type=NodePort \
  --set prometheus.service.nodePort=30091 \
  --set prometheus.prometheusSpec.retention=2d \
  --set alertmanager.alertmanagerSpec.retention=24h \
  --wait --timeout 5m

# ── 6. Install Argo Rollouts ──────────────────────────────────────────────
log "Installing Argo Rollouts..."
kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argo-rollouts \
  -f https://github.com/argoproj/argo-rollouts/releases/download/v1.7.2/install.yaml
kubectl -n argo-rollouts rollout status deployment/argo-rollouts --timeout=3m

# ── 7. Apply all manifests (swapping in the locally-built images) ────────
log "Applying Prometheus alert rules..."
kubectl apply -f monitoring/prometheus/rules/alerts.yaml

log "Applying Argo Rollouts AnalysisTemplates..."
kubectl apply -f argo-rollouts/analysis-template.yaml

log "Deploying application via Argo Rollout..."
sed "s|image: ghcr.io/.*healing-app.*|image: healing-app:1.0.0|" argo-rollouts/rollout.yaml \
  | kubectl apply -f -

log "Deploying anomaly detector..."
sed "s|image: ghcr.io/.*anomaly-detector.*|image: anomaly-detector:1.0.0|" ml/deployment.yaml \
  | kubectl apply -f -

# ── 8. Wait for pods ──────────────────────────────────────────────────────
log "Waiting for pods to be ready..."
kubectl rollout status deployment/anomaly-detector -n self-healing --timeout=3m || true
kubectl argo rollouts status healing-app -n self-healing --timeout=5m || true

# ── 9. Print access URLs ──────────────────────────────────────────────────
log "Done! Access your services:"
echo ""
echo "  App:          http://localhost:8080"
echo "  Prometheus:   http://localhost:9090"
echo "  Grafana:      http://localhost:3000  (admin / admin)"
echo "  AlertManager: kubectl port-forward -n self-healing svc/alertmanager-operated 9093:9093"
echo ""
echo "Test self-healing:"
echo "  bash scripts/inject-failure.sh enable 0.5"
echo "  kubectl argo rollouts get rollout healing-app -n self-healing --watch"

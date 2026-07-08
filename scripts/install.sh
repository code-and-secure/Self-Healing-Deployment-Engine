#!/usr/bin/env bash
# install.sh — Install all dependencies for the Self-Healing Deployment Engine
set -euo pipefail

NAMESPACE="self-healing"
ARGO_ROLLOUTS_VERSION="v1.7.2"
PROMETHEUS_CHART_VERSION="87.1.0"

log()  { echo "[$(date +%H:%M:%S)] INFO  $*"; }
warn() { echo "[$(date +%H:%M:%S)] WARN  $*" >&2; }
die()  { echo "[$(date +%H:%M:%S)] ERROR $*" >&2; exit 1; }

require() { command -v "$1" &>/dev/null || die "Required tool not found: $1"; }

# ── Pre-flight checks ─────────────────────────────────────────────────────
log "Checking required tools..."
require kubectl
require helm

KUBE_VERSION=$(kubectl version --client -o json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['clientVersion']['minor'])" 2>/dev/null || echo "0")
[[ "$KUBE_VERSION" -ge 24 ]] || warn "kubectl < 1.24 detected — some features may not work"

log "Kubernetes context: $(kubectl config current-context)"
kubectl cluster-info --request-timeout=5s || die "Cannot reach Kubernetes cluster"

# ── Namespace ─────────────────────────────────────────────────────────────
log "Creating namespace $NAMESPACE..."
kubectl apply -f k8s/namespace.yaml

# ── Prometheus + Grafana (kube-prometheus-stack) ──────────────────────────
log "Adding Prometheus Community Helm repo..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

log "Installing kube-prometheus-stack v${PROMETHEUS_CHART_VERSION}..."
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace "$NAMESPACE" \
  --version "$PROMETHEUS_CHART_VERSION" \
  --set grafana.adminPassword=admin \
  --set prometheus.prometheusSpec.retention=15d \
  --set alertmanager.enabled=true \
  --wait --timeout 5m

# ── Custom Prometheus rules ────────────────────────────────────────────────
# Alerting is handled by kube-prometheus-stack's bundled Alertmanager
# (--set alertmanager.enabled=true above) rather than a separate instance.
log "Applying Prometheus alert rules..."
kubectl apply -f monitoring/prometheus/rules/alerts.yaml

# ── Argo Rollouts resources ────────────────────────────────────────────────
log "Applying Argo Rollouts AnalysisTemplates..."
kubectl apply -f argo-rollouts/analysis-template.yaml

log "Installation complete!"
echo ""
echo "Next steps:"
echo "  1. Build and push your app image:  scripts/build.sh"
echo "  2. Deploy the application:         scripts/deploy.sh"
echo "  3. Access Grafana:                 kubectl port-forward -n $NAMESPACE svc/kube-prometheus-stack-grafana 3000:80"
echo "  4. Access Prometheus:              kubectl port-forward -n $NAMESPACE svc/kube-prometheus-stack-prometheus 9090:9090"

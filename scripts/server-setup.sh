#!/usr/bin/env bash
# server-setup.sh — Run this ONCE on 18.143.224.244 to bootstrap everything.
#
# Usage:
#   ssh user@18.143.224.244
#   git clone https://github.com/YOUR_ORG/YOUR_REPO
#   cd YOUR_REPO
#   bash scripts/server-setup.sh https://github.com/YOUR_ORG/YOUR_REPO
#
set -euo pipefail

REPO_URL="${1:?Usage: server-setup.sh <github-repo-url>}"
SERVER_IP="18.143.224.244"
NAMESPACE="self-healing"

log()  { echo "[$(date +%H:%M:%S)] INFO  $*"; }
warn() { echo "[$(date +%H:%M:%S)] WARN  $*" >&2; }
die()  { echo "[$(date +%H:%M:%S)] ERROR $*" >&2; exit 1; }

# ── Step 1: Install k3s (lightweight single-node Kubernetes) ─────────────────
log "==> [1/8] Installing k3s..."
# Disable Traefik — we use Nginx Ingress for canary traffic splitting
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
  --disable traefik \
  --tls-san ${SERVER_IP} \
  --write-kubeconfig-mode 644" sh -

# Make kubeconfig available to current user — keep 127.0.0.1 for local use
# (replacing with external IP causes i/o timeout when port 6443 is firewalled)
mkdir -p "$HOME/.kube"
sudo cp /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
export KUBECONFIG="$HOME/.kube/config"

log "Waiting for k3s node to be Ready..."
# Poll via local socket — avoids needing port 6443 open externally
until kubectl get node &>/dev/null; do sleep 3; done
kubectl wait node --all --for=condition=Ready --timeout=120s
log "k3s ready: $(kubectl get node -o wide)"

# ── Step 2: Install Helm ─────────────────────────────────────────────────────
log "==> [2/8] Installing Helm..."
if ! command -v helm &>/dev/null; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi
log "Helm: $(helm version --short)"

# ── Step 3: Install Nginx Ingress (required for canary traffic splitting) ─────
log "==> [3/8] Installing Nginx Ingress Controller..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.service.externalIPs[0]="${SERVER_IP}" \
  --set controller.metrics.enabled=true \
  --set controller.podAnnotations."prometheus\.io/scrape"=true \
  --set controller.podAnnotations."prometheus\.io/port"=10254 \
  --wait --timeout 3m
log "Nginx Ingress ready"

# ── Step 4: Install ArgoCD ───────────────────────────────────────────────────
log "==> [4/8] Installing ArgoCD..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl rollout status deployment/argocd-server -n argocd --timeout=180s

# Expose ArgoCD via NodePort on port 30080 so GitHub Actions can reach it
kubectl patch svc argocd-server -n argocd \
  -p '{"spec":{"type":"NodePort","ports":[{"port":443,"targetPort":8080,"nodePort":30080}]}}'

ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d)

log "ArgoCD URL:      https://${SERVER_IP}:30080"
log "ArgoCD user:     admin"
log "ArgoCD password: ${ARGOCD_PASSWORD}"
echo ""
warn "SAVE THIS PASSWORD — add it as GitHub secret ARGOCD_PASSWORD"
warn "GitHub secret ARGOCD_SERVER = ${SERVER_IP}:30080"
echo ""

# ── Step 5: Install Argo Rollouts + dashboard ────────────────────────────────
log "==> [5/8] Installing Argo Rollouts..."
kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argo-rollouts \
  -f https://github.com/argoproj/argo-rollouts/releases/download/v1.7.2/install.yaml
kubectl apply -n argo-rollouts \
  -f https://github.com/argoproj/argo-rollouts/releases/download/v1.7.2/dashboard-install.yaml
kubectl rollout status deployment/argo-rollouts -n argo-rollouts --timeout=120s

# kubectl plugin
if ! command -v kubectl-argo-rollouts &>/dev/null; then
  ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
  curl -sLo /usr/local/bin/kubectl-argo-rollouts \
    "https://github.com/argoproj/argo-rollouts/releases/download/v1.7.2/kubectl-argo-rollouts-linux-${ARCH}"
  chmod +x /usr/local/bin/kubectl-argo-rollouts
fi
log "Argo Rollouts ready"

# ── Step 6: Run existing install.sh to set up Prometheus/Grafana/app stack ───
log "==> [6/8] Installing Prometheus, Grafana, Alertmanager, app manifests..."
bash "$(dirname "$0")/install.sh"

# ── Step 7: Create ArgoCD API token for GitHub Actions ──────────────────────
log "==> [7/8] Creating ArgoCD API token..."
# Install argocd CLI
if ! command -v argocd &>/dev/null; then
  curl -sSL -o /usr/local/bin/argocd \
    https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
  chmod +x /usr/local/bin/argocd
fi

# Login and create a token
argocd login "${SERVER_IP}:30080" \
  --username admin \
  --password "${ARGOCD_PASSWORD}" \
  --insecure

ARGOCD_TOKEN=$(argocd account generate-token --account admin --insecure 2>/dev/null || echo "")

if [[ -n "$ARGOCD_TOKEN" ]]; then
  log "ArgoCD token generated"
  echo ""
  warn "Add this as GitHub secret ARGOCD_TOKEN:"
  echo "${ARGOCD_TOKEN}"
  echo ""
else
  warn "Could not auto-generate token — create it manually at https://${SERVER_IP}:30080/settings/accounts/admin"
fi

# ── Step 8: Apply ArgoCD Application manifests ───────────────────────────────
log "==> [8/8] Registering ArgoCD Applications..."
# Substitute the real repo URL into the application manifest
sed "s|https://github.com/YOUR_ORG/YOUR_REPO|${REPO_URL}|g" \
  "$(dirname "$0")/../argocd/application.yaml" | kubectl apply -f -

log "ArgoCD Applications registered — sync will start within 3 minutes"
log ""
log "================================================================"
log "SETUP COMPLETE — Summary"
log "================================================================"
log "App URL:              http://${SERVER_IP}  (via Nginx Ingress)"
log "ArgoCD UI:            https://${SERVER_IP}:30080"
log "Grafana:              kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n ${NAMESPACE}"
log "Prometheus:           kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n ${NAMESPACE}"
log "Argo Rollouts UI:     kubectl argo rollouts dashboard -n ${NAMESPACE}"
log ""
log "GitHub Secrets to set (Settings > Secrets > Actions):"
log "  ARGOCD_SERVER   = ${SERVER_IP}:30080"
log "  ARGOCD_PASSWORD = ${ARGOCD_PASSWORD}"
log "  ARGOCD_TOKEN    = (shown above)"
log ""
log "  KUBECONFIG_B64  = (copy the line below — it is the base64 kubeconfig"
log "                     with external IP so GitHub Actions can reach k3s)"
# Generate a remote kubeconfig pointing to the external IP for GitHub Actions
sed "s|127.0.0.1|${SERVER_IP}|g" "$HOME/.kube/config" | base64 -w0
echo ""
log "================================================================"

#!/usr/bin/env bash
# One-time cluster bootstrap — run this ONCE before ArgoCD takes over.
# After this script, all subsequent deploys happen via GitHub Actions + ArgoCD.
set -euo pipefail

REPO_URL="${1:-https://github.com/YOUR_ORG/YOUR_REPO}"   # Pass your repo URL as first arg

echo "==> [1/5] Installing Argo CD"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl rollout status deployment/argocd-server -n argocd --timeout=120s

echo "==> [2/5] Installing Argo Rollouts + dashboard"
kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/dashboard-install.yaml
kubectl rollout status deployment/argo-rollouts -n argo-rollouts --timeout=120s

echo "==> [3/5] Installing Nginx Ingress (required for canary traffic splitting)"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.metrics.enabled=true \
  --wait

echo "==> [4/5] Registering repo with ArgoCD and applying Application manifests"
# Update the repoURL in application.yaml before applying
sed "s|https://github.com/YOUR_ORG/YOUR_REPO|${REPO_URL}|g" \
  "$(dirname "$0")/../argocd/application.yaml" | kubectl apply -f -

echo "==> [5/5] Done — ArgoCD will now sync the cluster from git"
echo ""
echo "Useful commands:"
echo "  kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo "  kubectl argo rollouts dashboard -n self-healing"
echo "  kubectl argo rollouts get rollout healing-app -n self-healing --watch"

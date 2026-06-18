# Local Deployment Guide

Two options — pick one:

| Option | Best for | Kubernetes? | Time |
|--------|----------|-------------|------|
| **Option A** — Docker Compose | Quick demo, see metrics/dashboard | No | ~2 min |
| **Option B** — kind (Kubernetes) | Full stack with Argo Rollouts | Yes | ~10 min |

---

## Option A — Docker Compose (Recommended for first run)

### Step 1 — Install Docker

**WSL / Linux:**
```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker
```

**Windows:** Install [Docker Desktop](https://www.docker.com/products/docker-desktop/) and enable WSL2 backend.

---

### Step 2 — Clone and start

```bash
cd "Self-Healing Deployment Engine"

docker compose up --build -d
```

That's it. Docker builds both images and starts everything.

---

### Step 3 — Open the services

| Service | URL | Login |
|---------|-----|-------|
| App | http://localhost:8080 | — |
| Prometheus | http://localhost:9090 | — |
| Grafana | http://localhost:3000 | admin / admin |
| AlertManager | http://localhost:9093 | — |
| Anomaly Detector | http://localhost:8090/status | — |

---

### Step 4 — Test self-healing

**Inject a 50% error rate:**
```bash
curl -X POST http://localhost:8080/admin/inject-failure \
  -H "Content-Type: application/json" \
  -d '{"enabled": true, "error_rate": 0.5}'
```

**Watch Prometheus fire the alert:**
- Go to http://localhost:9090/alerts
- Within ~1 min you'll see `HighErrorRate` go from `PENDING` → `FIRING`

**Watch the Anomaly Detector react:**
```bash
# Check its status
curl http://localhost:8090/status

# Watch live history
curl http://localhost:8090/history
```

**Grafana dashboard:**
- Go to http://localhost:3000
- Dashboards → Self-Healing Deployment Engine

**Stop the failure:**
```bash
curl -X POST http://localhost:8080/admin/inject-failure \
  -H "Content-Type: application/json" \
  -d '{"enabled": false}'
```

**Stop everything:**
```bash
docker compose down
```

---

## Option B — Full Kubernetes with kind

### Step 1 — Install tools

**WSL / Linux (run each block):**

```bash
# Docker
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER && newgrp docker

# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/

# kind
curl -Lo kind https://kind.sigs.k8s.io/dl/v0.23.0/kind-linux-amd64
chmod +x kind && sudo mv kind /usr/local/bin/

# helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Argo Rollouts kubectl plugin
curl -LO https://github.com/argoproj/argo-rollouts/releases/download/v1.7.2/kubectl-argo-rollouts-linux-amd64
chmod +x kubectl-argo-rollouts-linux-amd64 && sudo mv kubectl-argo-rollouts-linux-amd64 /usr/local/bin/kubectl-argo-rollouts
```

---

### Step 2 — Run the setup script

```bash
cd "Self-Healing Deployment Engine"

bash local/setup-kind.sh
```

This script:
1. Creates a 3-node kind cluster
2. Builds Docker images and loads them into kind
3. Installs Prometheus + Grafana via Helm
4. Installs Argo Rollouts
5. Deploys the app, anomaly detector, and all configs

---

### Step 3 — Open the services

| Service | URL | Login |
|---------|-----|-------|
| App | http://localhost:8080 | — |
| Prometheus | http://localhost:9090 | — |
| Grafana | http://localhost:3000 | admin / admin |
| Argo Rollouts Dashboard | `kubectl argo rollouts dashboard` then http://localhost:3100 | — |

---

### Step 4 — Test self-healing (Kubernetes)

**Inject failure:**
```bash
bash scripts/inject-failure.sh enable 0.5
```

**Watch Argo Rollouts react:**
```bash
kubectl argo rollouts get rollout healing-app -n self-healing --watch
```

**Watch pods restart:**
```bash
kubectl get pods -n self-healing -w
```

**Deploy a new version (triggers canary):**
```bash
# Edit app/main.py to simulate a bad version, then:
docker build -t healing-app:2.0.0 app/
kind load docker-image healing-app:2.0.0 --name self-healing
kubectl argo rollouts set image healing-app healing-app=healing-app:2.0.0 -n self-healing

# Watch the 5%→20%→50%→80%→100% canary progression
kubectl argo rollouts get rollout healing-app -n self-healing --watch
```

**Manual rollback:**
```bash
bash scripts/rollback.sh
```

**Destroy the cluster when done:**
```bash
kind delete cluster --name self-healing
```

---

## Troubleshooting

**Docker Compose: port already in use**
```bash
# Find what's using port 8080
sudo lsof -i :8080
# Or change the port in docker-compose.yml
```

**kind: cluster creation fails on WSL**
```bash
# Ensure WSL2 memory limit isn't too low — add to %USERPROFILE%\.wslconfig on Windows:
# [wsl2]
# memory=4GB
# processors=2
```

**Prometheus not scraping**
```bash
# Check targets
curl http://localhost:9090/api/v1/targets | python3 -m json.tool | grep health
```

**Anomaly detector not detecting**
```bash
# It needs 10+ samples before the model trains
# Check how many it has collected:
curl http://localhost:8090/status
```

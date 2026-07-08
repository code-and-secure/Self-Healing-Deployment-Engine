# Local Deployment

Two ways to run this project on your own machine, depending on what you want to test:

| | Docker Compose | kind (local Kubernetes) |
|---|---|---|
| Setup time | ~2 minutes | ~5-10 minutes |
| Kubernetes required | No | Yes (via `kind`, runs in Docker) |
| App + metrics | Yes | Yes |
| Prometheus + Grafana | Yes | Yes |
| ML anomaly detection | Yes | Yes |
| Auto-remediation (rollback/scale/restart/abort) | Attempted, but the Rollout API it calls doesn't exist without Kubernetes — calls fail | Full — same Kubernetes API-based remediation as production |
| Canary progressive delivery (Argo Rollouts) | No | Yes |
| Pod-level self-healing (restarts, PDB-aware eviction) | No | Yes |

If you just want to see the app, metrics, and anomaly scoring working, use **Docker Compose**. If you want to actually exercise the full self-healing loop (canary steps, auto-rollback, pod restarts) without needing a cloud VM, use **kind**.

---

## Option A — Docker Compose

### Prerequisites
- Docker 24+ and Docker Compose v2
- 4 GB RAM available to Docker
- Ports 3000, 8080, 8090, 9090, 9093 free

**Install Docker (Linux / WSL2):**
```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER && newgrp docker
```
**Windows:** install [Docker Desktop](https://www.docker.com/products/docker-desktop/) with the WSL2 backend enabled.

### Start the stack
```bash
git clone https://github.com/code-and-secure/Self-Healing-Deployment-Engine.git
cd Self-Healing-Deployment-Engine

docker compose up --build -d
docker compose ps   # confirm all containers are running
```
This builds both images (`healing-app`, `anomaly-detector`) and starts five containers: the app, anomaly detector, Prometheus, Grafana, and Alertmanager.

### Open the dashboards

| Service | URL | Credentials |
|---|---|---|
| App | http://localhost:8080 | — |
| Prometheus | http://localhost:9090 | — |
| Grafana | http://localhost:3000 | `admin` / `admin` |
| Alertmanager | http://localhost:9093 | — |
| Anomaly Detector | http://localhost:8090/status | — |

Grafana opens to the **Self-Healing Deployment Engine** dashboard automatically — no manual import needed here (unlike the Kubernetes path, see [CLOUD-DEPLOY.md](CLOUD-DEPLOY.md)).

### Generate traffic
The anomaly detector needs real requests flowing through the app to collect samples and train its model:
```bash
bash compose/generate-traffic.sh          # 5 req/s against http://localhost:8080
```
Wait until it reports `model_trained: true` (roughly 5 minutes at default settings) before running failure tests.

### Test self-healing
```bash
# Inject a 50% error rate
curl -X POST http://localhost:8080/admin/inject-failure \
  -H "Content-Type: application/json" -d '{"enabled": true, "error_rate": 0.5}'
```
Keep the traffic generator running. Within 30-60 seconds:
- Grafana's **HTTP Error Rate** panel spikes above the 20% critical threshold
- The Prometheus `HighErrorRate` alert goes **FIRING**
- Alertmanager shows it under **Alerts**
- Anomaly Detector `/status` reports `recent_anomalies > 0`

Restore normal behavior:
```bash
curl -X POST http://localhost:8080/admin/inject-failure \
  -H "Content-Type: application/json" -d '{"enabled": false}'
```

Note: the detector *will* log an attempted remediation action, but the call fails since there's no Kubernetes/Argo Rollouts here to act on — that's expected. Use the **kind** path below to see the actual remediation succeed.

### Useful commands
```bash
docker logs -f anomaly-detector                                     # follow detector logs
curl -s http://localhost:8090/status | python3 -m json.tool         # detector status
curl -s http://localhost:8090/history | python3 -m json.tool        # last 50 detection samples
curl -s http://localhost:9090/api/v1/targets | python3 -m json.tool | grep health   # scrape targets
docker compose down          # stop everything, keep data
docker compose down -v       # stop and delete all data
```

---

## Option B — kind (local Kubernetes)

This mirrors the cloud deployment's architecture (Argo Rollouts canary + Kubernetes-API-driven self-healing) entirely on your own machine — no cloud VM needed.

### Prerequisites
- Docker
- [`kind`](https://kind.sigs.k8s.io/) — `go install sigs.k8s.io/kind@latest` or see kind's install docs
- `kubectl`, `helm`

### Run it
```bash
bash compose/setup-kind.sh
```
This single script:
1. Creates a 3-node `kind` cluster (`compose/kind-cluster.yaml`)
2. Builds the `healing-app` and `anomaly-detector` images locally and loads them into the cluster (no registry needed)
3. Installs `kube-prometheus-stack` (Prometheus + Grafana + Alertmanager) via Helm
4. Installs the Argo Rollouts controller
5. Deploys the app as a canary `Rollout`, the anomaly detector, and the Prometheus alert rules

### Access

| Service | URL |
|---|---|
| App | http://localhost:8080 |
| Prometheus | http://localhost:9090 |
| Grafana | http://localhost:3000 (`admin`/`admin`) |
| Alertmanager | `kubectl port-forward -n self-healing svc/alertmanager-operated 9093:9093` |

Import the Grafana dashboard manually the same way as the cloud path — see [CLOUD-DEPLOY.md](CLOUD-DEPLOY.md#import-the-grafana-dashboard) — since it's the same `kube-prometheus-stack` Grafana without dashboard auto-provisioning wired up.

### Test self-healing (the real thing this time)
```bash
bash scripts/inject-failure.sh enable 0.5
kubectl argo rollouts get rollout healing-app -n self-healing --watch
kubectl logs -n self-healing -l app=anomaly-detector -f
```
You should see the detector call the Kubernetes API directly to patch the `Rollout` (restart/abort/scale/rollback depending on severity), and the pods actually recycle — see [CLOUD-DEPLOY.md](CLOUD-DEPLOY.md#how-self-healing-actually-works) for exactly what triggers each action.

Turn it off:
```bash
bash scripts/inject-failure.sh disable
```

### Tear down
```bash
kind delete cluster --name self-healing
```

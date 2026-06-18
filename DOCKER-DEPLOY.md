# Docker Compose Deployment

Run the full Self-Healing Deployment Engine stack locally in under 2 minutes using Docker Compose. No Kubernetes required.

---

## Prerequisites

- Docker 24+ and Docker Compose v2
- 4 GB RAM available to Docker
- Ports 3000, 8080, 8090, 9090, 9093 free

**Install Docker (Linux / WSL2):**
```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER && newgrp docker
```

**Windows:** Install [Docker Desktop](https://www.docker.com/products/docker-desktop/) with the WSL2 backend enabled.

---

## Start the Stack

```bash
git clone https://github.com/your-username/self-healing-deployment-engine.git
cd self-healing-deployment-engine

docker compose up --build -d
```

Docker builds both images (`healing-app` and `anomaly-detector`) and starts five containers: the app, anomaly detector, Prometheus, Grafana, and AlertManager.

Verify all containers are running:
```bash
docker compose ps
```

---

## Open the Dashboards

| Service | URL | Credentials |
|---|---|---|
| App | http://localhost:8080 | — |
| Prometheus | http://localhost:9090 | — |
| Grafana | http://localhost:3000 | `admin` / `admin` |
| AlertManager | http://localhost:9093 | — |
| Anomaly Detector | http://localhost:8090/status | — |

Grafana opens to the **Self-Healing Deployment Engine** dashboard automatically — no import needed.

---

## Generate Traffic

The anomaly detector needs requests flowing through the app to collect metric samples and train its model. Run the traffic generator in a separate terminal:

```bash
bash compose/generate-traffic.sh
```

The script prints a live status line every 10 seconds showing request counts, error rate, anomaly score, and deployment score pulled directly from Prometheus and the detector API.

Wait until the script reports `model_trained: true` (roughly 5 minutes at default settings) before running chaos tests.

---

## Test Self-Healing

### Inject a failure

```bash
curl -X POST http://localhost:8080/admin/inject-failure \
  -H "Content-Type: application/json" \
  -d '{"enabled": true, "error_rate": 0.5}'
```

Keep the traffic generator running. Within 30–60 seconds you will see:

- Grafana **HTTP Error Rate** panel spike above the 20% critical threshold
- Prometheus `AnomalyDetected` alert go **FIRING**
- AlertManager show the alert under **Alerts**
- Anomaly Detector `/status` report `recent_anomalies > 0`

### Restore healthy state

```bash
curl -X POST http://localhost:8080/admin/inject-failure \
  -H "Content-Type: application/json" \
  -d '{"enabled": false}'
```

Alerts resolve within ~1 minute and the deployment score returns to 100%.

---

## Useful Commands

```bash
# Follow anomaly detector logs
docker logs -f anomaly-detector

# Check detector status
curl -s http://localhost:8090/status | python3 -m json.tool

# View last 20 detection samples
curl -s http://localhost:8090/history | python3 -m json.tool

# Check Prometheus scrape targets
curl -s http://localhost:9090/api/v1/targets | python3 -m json.tool | grep health

# Stop everything (data is preserved in Docker volumes)
docker compose down

# Stop and delete all data
docker compose down -v
```

---

## What Works vs. Kubernetes-Only

| Feature | Docker Compose | Kubernetes |
|---|---|---|
| App + metrics | Yes | Yes |
| Prometheus + alerts | Yes | Yes |
| Grafana dashboard | Yes | Yes |
| AlertManager routing | Yes | Yes |
| ML anomaly detection | Yes | Yes |
| Auto-remediation (rollback/scale) | Attempted, API unreachable | Full |
| Canary progressive delivery | No | Yes (Argo Rollouts) |
| Pod-level self-healing | No | Yes |

For the full self-healing loop including canary rollouts and pod restarts, see [CLOUD-DEPLOY.md](CLOUD-DEPLOY.md).

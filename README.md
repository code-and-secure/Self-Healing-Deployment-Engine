# Self-Healing Deployment Engine

Automatically detects unhealthy deployments and recovers without human intervention.

```
Deploy → Health Check → Prometheus Metrics → Argo Rollouts → Rollback
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Kubernetes Cluster (namespace: self-healing)                    │
│                                                                  │
│  ┌──────────────┐    ┌──────────────┐    ┌───────────────────┐  │
│  │  healing-app │───▶│  Prometheus  │───▶│  AlertManager     │  │
│  │  (Flask)     │    │  + Rules     │    │  → Slack          │  │
│  │              │    └──────────────┘    └───────────────────┘  │
│  │  /healthz    │           │                                    │
│  │  /readyz     │           ▼                                    │
│  │  /metrics    │    ┌──────────────┐    ┌───────────────────┐  │
│  └──────────────┘    │  Anomaly     │───▶│  Argo Rollouts    │  │
│         ▲            │  Detector    │    │  (Canary +        │  │
│         │            │  (ML/IsoFor) │    │   Auto-Rollback)  │  │
│         └────────────│              │    └───────────────────┘  │
│                      └──────────────┘                           │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  Grafana Dashboard  (deployment score, error rate, P99)  │   │
│  └──────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

---

## Project Layout

```
.
├── app/                        # Flask application
│   ├── main.py                 # App + /healthz /readyz /metrics endpoints
│   ├── requirements.txt
│   └── Dockerfile
├── k8s/                        # Phase 1 — Kubernetes
│   ├── namespace.yaml
│   ├── deployment.yaml         # Liveness, readiness, startup probes
│   ├── service.yaml            # Service + PodDisruptionBudget
│   └── hpa.yaml                # HorizontalPodAutoscaler
├── monitoring/                 # Phase 2 — Observability
│   ├── prometheus/
│   │   ├── prometheus.yaml     # Prometheus deployment + RBAC
│   │   └── rules/
│   │       └── alerts.yaml     # Error rate / latency / availability rules
│   └── grafana/
│       ├── dashboard.json      # Grafana dashboard (import manually)
│       └── provisioning.yaml   # Auto-provision via ConfigMap sidecar
├── argo-rollouts/              # Phase 3 — Progressive delivery
│   ├── rollout.yaml            # 5%→20%→50%→80%→100% canary + auto-rollback
│   └── analysis-template.yaml # Prometheus gates + smoke-test job
├── alertmanager/               # Phase 4 — Slack alerts
│   └── alertmanager.yaml       # Critical / warning routing to Slack channels
├── ml/                         # Advanced — ML anomaly detection
│   ├── anomaly_detector.py     # Isolation Forest + auto-remediation
│   ├── requirements.txt
│   ├── Dockerfile
│   └── deployment.yaml
└── scripts/
    ├── install.sh              # Install all dependencies (Helm, Argo Rollouts)
    ├── deploy.sh               # Build → push → canary deploy
    ├── rollback.sh             # Manual rollback
    └── inject-failure.sh       # Inject failures to test self-healing
```

---

## Quick Start

### Prerequisites
- Kubernetes cluster (kind / minikube / EKS / GKE)
- `kubectl`, `helm`, `docker`

### 1. Install all components

```bash
bash scripts/install.sh
```

### 2. Build and deploy the app

```bash
# Build image
docker build -t localhost:5000/healing-app:1.0.0 app/
docker push localhost:5000/healing-app:1.0.0

# Apply Phase 1 manifests
kubectl apply -f k8s/

# Deploy via Argo Rollout (Phase 3)
kubectl apply -f argo-rollouts/
```

### 3. Deploy the ML anomaly detector

```bash
docker build -t localhost:5000/anomaly-detector:1.0.0 ml/
docker push localhost:5000/anomaly-detector:1.0.0
kubectl apply -f ml/deployment.yaml
```

### 4. Import the Grafana dashboard

```bash
# Port-forward Grafana
kubectl port-forward -n self-healing svc/kube-prometheus-stack-grafana 3000:80

# Then import monitoring/grafana/dashboard.json via the Grafana UI
# Dashboards → Import → Upload JSON file
```

### 5. Configure Slack alerts

Edit `alertmanager/alertmanager.yaml` and replace:
```yaml
slack_webhook_url: "https://hooks.slack.com/services/YOUR/SLACK/WEBHOOK"
```
Then apply: `kubectl apply -f alertmanager/alertmanager.yaml`

---

## Testing Self-Healing

### Inject failures

```bash
# Inject 50% error rate
bash scripts/inject-failure.sh enable 0.5

# Watch Argo Rollouts react
kubectl argo rollouts get rollout healing-app -n self-healing --watch

# Disable failures
bash scripts/inject-failure.sh disable
```

### Deploy a bad version

```bash
# Deploy v2 — canary will gate at 5% and roll back automatically if error rate >20%
bash scripts/deploy.sh v2
```

### Manual rollback

```bash
bash scripts/rollback.sh
```

---

## Key Metrics

| Metric | Warning | Critical |
|--------|---------|----------|
| Error Rate | >5% | >20% |
| P99 Latency | >1s | >5s |
| Availability | — | <100% for 1m |
| Anomaly Score | — | <-0.15 |

---

## Self-Healing Flow

```
1. New version deployed via Argo Rollouts (canary: 5%)
2. AnalysisTemplate queries Prometheus every 30 s
3. If error_rate >= 20% OR p99 >= 5s → AnalysisRun FAILED
4. Argo Rollouts automatically aborts canary and reverts to stable
5. AlertManager sends Slack notification
6. ML Anomaly Detector (runs in parallel):
   - Isolation Forest scores current metric vector
   - Score < -0.15 → anomaly
   - deployment_score < 30 → full rollback
   - high error rate → abort active rollout
   - high latency → scale up
   - otherwise → restart unhealthy pods
```

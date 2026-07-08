# Self-Healing Deployment Engine

## What this is

A deployment pipeline that detects when a release is unhealthy and fixes it **without a human in the loop**. It's built as a learning project covering four layers that build on each other:

1. **Health checks** — liveness/readiness/startup probes so Kubernetes itself knows when a pod is broken
2. **Observability** — Prometheus metrics + Grafana dashboards, so the state of the system is actually visible
3. **Progressive delivery** — Argo Rollouts canary deployments (traffic shifts gradually: 20% → 50% → 100%, with a smoke-test gate), so a bad release only ever affects a fraction of traffic
4. **ML-based auto-remediation** — an anomaly detector (Isolation Forest) watches the same Prometheus metrics, scores the deployment's health, and — when something looks wrong — **acts on its own**: restarts pods, aborts an in-progress canary, scales up under latency pressure, or rolls back to the last known-good revision

The interesting part isn't any one of these pieces individually — it's that layer 4 closes the loop. Most "self-healing" demos stop at Kubernetes restarting a crashed container. This one has a model deciding *which* of several remediation strategies fits the specific failure it's seeing, and driving that decision through the Kubernetes API itself.

## How it works, end to end

```
Push to main
     │
     ▼
GitHub Actions builds + pushes images, bumps image tags in the manifests,
triggers an ArgoCD sync, then watches the canary rollout
     │
     ▼
ArgoCD (GitOps) — pulls this repo directly, applies everything to the cluster
     │
     ▼
Argo Rollouts — runs the canary: 20% traffic → smoke test → 50% → 100%
     │
     ▼
The anomaly detector, in parallel, continuously:
  1. queries Prometheus for error rate / p99 latency / availability / CPU / memory
  2. scores that vector with an Isolation Forest model
  3. if anomalous, picks a remediation and patches the Rollout's Kubernetes
     object directly — restart (spec.restartAt), abort (status.abort),
     scale (spec.replicas), or rollback (spec.template ← last stable RS)
```

Two deployment targets are supported:
- **[CLOUD-DEPLOY.md](CLOUD-DEPLOY.md)** — the real thing: a cloud VM running k3s + ArgoCD + Argo Rollouts, driven by the GitHub Actions pipeline above. This is what's actually deployed and tested.
- **[LOCAL-DEPLOY.md](LOCAL-DEPLOY.md)** — run it on your own machine, either via Docker Compose (app + monitoring only, no canary/remediation) or `kind` (mirrors the cloud architecture exactly, no cloud VM needed).

For the day-to-day commands you'll actually use once it's running, see **[COMMANDS.md](COMMANDS.md)**. If something breaks, check **[TROUBLESHOOTING.md](TROUBLESHOOTING.md)** — every real issue hit while building this, with root cause and fix.

---

## Architecture

```
┌───────────────────────────────────────────────────────────────────────┐
│  Kubernetes namespace: self-healing                                    │
│                                                                          │
│  ┌──────────────┐        ┌───────────────┐                             │
│  │  healing-app │───────▶│  Prometheus   │  (custom — scrapes via      │
│  │  (Argo       │        │               │   prometheus.io/scrape     │
│  │   Rollout,   │        └───────┬───────┘   pod annotations)          │
│  │   canary)    │                │                                     │
│  │  /healthz    │                ▼                                     │
│  │  /readyz     │        ┌───────────────┐        ┌──────────────────┐ │
│  │  /metrics    │        │  Anomaly      │───────▶│  Argo Rollouts   │ │
│  └──────▲───────┘        │  Detector     │ patches│  controller      │ │
│         │                │  (Isolation   │ via k8s│  (canary steps,  │ │
│         └────────────────│   Forest)     │  API   │   restart/abort/ │ │
│                           └───────────────┘        │   scale/rollback)│ │
│                                                     └──────────────────┘ │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │  Grafana (kube-prometheus-stack) — deployment score, error rate,  │   │
│  │  P99 latency, anomaly score, pod count, remediation actions       │   │
│  └──────────────────────────────────────────────────────────────────┘   │
└───────────────────────────────────────────────────────────────────────┘
```

**Note on Prometheus:** there are two independent instances in the cloud/kind setup — the custom one above (which has your actual app metrics) and `kube-prometheus-stack-prometheus` (bundled with Grafana via Helm, which only scrapes standard cluster metrics). Grafana defaults to the wrong one; see the [Grafana dashboard setup](CLOUD-DEPLOY.md#import-the-grafana-dashboard) in CLOUD-DEPLOY.md.

---

## Project Layout

```
.
├── app/                         # Flask application under test
│   ├── main.py                  # /healthz /readyz /metrics + /admin/inject-failure
│   ├── requirements.txt
│   └── Dockerfile
├── k8s/                         # Base Kubernetes resources
│   ├── namespace.yaml
│   ├── service.yaml             # Service + NodePort + PodDisruptionBudget
│   └── hpa.yaml                 # HorizontalPodAutoscaler (targets the Rollout)
├── argo-rollouts/               # Canary progressive delivery
│   ├── rollout.yaml             # The Rollout itself: 20%→50%→100% + smoke test
│   └── analysis-template.yaml   # Smoke-test AnalysisTemplate
├── ml/                          # ML-based anomaly detection + auto-remediation
│   ├── anomaly_detector.py      # Isolation Forest + Kubernetes-API remediation
│   ├── requirements.txt
│   ├── Dockerfile
│   └── deployment.yaml          # Deployment + dedicated ServiceAccount/Role/RoleBinding
├── monitoring/                  # Observability
│   ├── prometheus/
│   │   ├── prometheus.yaml      # Custom Prometheus — the one with real app metrics
│   │   └── rules/alerts.yaml    # Error rate / latency / availability alert rules
│   └── grafana/
│       ├── dashboard.json       # Import manually — see CLOUD-DEPLOY.md
│       └── provisioning.yaml    # Placeholder ConfigMap (auto-provisioning isn't wired up)
├── argocd/
│   └── application.yaml         # ArgoCD Application manifests (GitOps source of truth)
├── compose/                     # Local deployment tooling — see LOCAL-DEPLOY.md
│   ├── prometheus.yml, alerts.yml, alertmanager.yml, grafana-*.yml   # Docker Compose stack
│   ├── generate-traffic.sh      # Traffic generator with a live status line
│   ├── kind-cluster.yaml        # kind cluster config (mirrors cloud architecture)
│   └── setup-kind.sh            # One-shot local Kubernetes setup via kind
├── docker-compose.yml
└── scripts/
    ├── server-setup.sh          # One-time cloud VM bootstrap (k3s, ArgoCD, Argo Rollouts, monitoring)
    ├── install.sh               # Installs Prometheus/Grafana + alert rules + AnalysisTemplates
    ├── inject-failure.sh        # Toggle simulated failures for testing self-healing
    ├── deploy.sh                # Manual build+push+deploy (bypasses the GitOps pipeline)
    └── rollback.sh              # Manual interactive rollback
```

---

## Key Metrics

| Metric | Warning | Critical | Drives |
|--------|---------|----------|--------|
| Error Rate | >5% | >20% | Prometheus alert, and the detector's "abort" threshold at >30% |
| P99 Latency | >1s | >5s | Prometheus alert, and the detector's "scale up" threshold at >4s |
| Availability | — | <100% for 1m | Prometheus alert |
| Anomaly Score | — | <-0.15 | The detector's trigger threshold — below this, a remediation fires |
| Deployment Score | — | <30 | The detector's "full rollback" threshold (0-100 composite score) |

---

## Testing self-healing

```bash
bash scripts/inject-failure.sh enable 0.5
kubectl argo rollouts get rollout healing-app -n self-healing --watch
kubectl logs -n self-healing -l app=anomaly-detector -f
```

Injecting the failure alone does nothing without traffic hitting the app — see [CLOUD-DEPLOY.md](CLOUD-DEPLOY.md#test-self-healing) or [LOCAL-DEPLOY.md](LOCAL-DEPLOY.md) for the full walkthrough including how to generate that traffic.

```bash
bash scripts/inject-failure.sh disable
```

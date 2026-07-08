# Cloud Deployment Guide

This is what's actually running in production for this project: a single Azure VM running **k3s** (lightweight Kubernetes), with **ArgoCD** doing GitOps sync and **Argo Rollouts** running canary deployments — driven end-to-end by a **GitHub Actions** pipeline over SSH. No manual `kubectl apply` in normal operation; every push to `main` flows through automatically.

For a lighter-weight local alternative that doesn't need a cloud VM (including a `kind`-based option that mirrors this same architecture), see [LOCAL-DEPLOY.md](LOCAL-DEPLOY.md).

---

## Architecture

```
GitHub push to main
      │
      ▼
┌─────────────────────────────────────────────────────────────────────┐
│ GitHub Actions (.github/workflows/deploy.yml)                        │
│  1. Build & push healing-app + anomaly-detector images → GHCR        │
│  2. Bump image tags in argo-rollouts/rollout.yaml + ml/deployment.yaml│
│     and push that commit back to main                                │
│  3. SSH to the VM → refresh git checkout → argocd app sync           │
│  4. SSH to the VM → watch the canary rollout to completion           │
└─────────────────────────────────────────────────────────────────────┘
      │ (ArgoCD pulls directly from GitHub — SSH steps just trigger/watch it)
      ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Azure VM — single-node k3s cluster                                   │
│                                                                        │
│  ArgoCD (namespace argocd)                                            │
│    └── watches this git repo, applies k8s/, argo-rollouts/,           │
│        ml/deployment.yaml, monitoring/**                              │
│                                                                        │
│  namespace: self-healing                                              │
│    ┌────────────┐   ┌──────────────┐   ┌─────────────────────────┐   │
│    │ healing-app│──▶│  Prometheus  │──▶│  kube-prometheus-stack   │   │
│    │ (Rollout,  │   │  (custom,    │   │  Grafana + Alertmanager  │   │
│    │  canary)   │   │  scrapes via │   └─────────────────────────┘   │
│    │            │   │  pod annota- │                                  │
│    │            │   │  tions)      │                                  │
│    └─────┬──────┘   └──────────────┘                                  │
│          │                  ▲                                         │
│          │                  │ queries                                 │
│          ▼                  │                                         │
│    ┌─────────────────────────────────┐                                │
│    │  anomaly-detector                │                                │
│    │  Isolation Forest model          │───▶ patches the Rollout        │
│    │  scores metrics every 30s        │     directly via the           │
│    │  decides: restart/abort/scale/   │     Kubernetes API             │
│    │  rollback                        │     (not the Argo Rollouts     │
│    └─────────────────────────────────┘     dashboard — see below)      │
│                                                                        │
│  Argo Rollouts controller — runs the canary steps, watches Analysis-  │
│  Run results, honors spec.restartAt / status.abort from the detector  │
└─────────────────────────────────────────────────────────────────────┘
```

**Two independent Prometheus instances exist on this cluster** — this trips people up, so it's worth calling out explicitly:
- `prometheus` (this repo's own `monitoring/prometheus/prometheus.yaml`) — discovers `healing-app`/`anomaly-detector` pods via `prometheus.io/scrape` annotations. **This is the one with your actual app metrics** (`app_availability`, `http_requests_total`, `anomaly_detector_score`, etc.)
- `kube-prometheus-stack-prometheus` (installed by Helm alongside Grafana) — only scrapes via ServiceMonitor/PodMonitor CRDs, which nothing here creates, so it has no visibility into the app at all.

Grafana's default datasource points at the second one. If your dashboard shows "No data," this is almost certainly why — see [Import the Grafana dashboard](#import-the-grafana-dashboard) below.

---

## How self-healing actually works

The anomaly detector (`ml/anomaly_detector.py`) runs a detection cycle every `SCRAPE_INTERVAL` (default 30s):

1. Pulls `app_availability`, `http_requests_total` (error rate), `http_request_duration_seconds` (p99 latency), CPU/memory from Prometheus
2. Scores the feature vector with an Isolation Forest model (trained online after `WARMUP_SAMPLES`, default 20 samples)
3. If the anomaly score falls below `ANOMALY_THRESHOLD` (default `-0.15`), it picks a remediation based on severity:

| Condition | Action |
|---|---|
| `deployment_score < 30` | **Rollback** — reads the Rollout's `status.stableRS`, finds that ReplicaSet's pod template, patches it back into `spec.template` |
| `error_rate > 0.30` | **Abort** — patches `status.abort: true` on the Rollout |
| `p99_latency > 4.0s` | **Scale up** — patches `spec.replicas: 6` |
| otherwise | **Restart** — patches `spec.restartAt` to now, triggering a rolling pod restart |

All four actions patch the `Rollout` custom resource **directly via the Kubernetes API** (using a dedicated `anomaly-detector` ServiceAccount + Role scoped to `get/patch` on `rollouts` and read-only on `replicasets`) — not through the Argo Rollouts dashboard. The dashboard only serves its own gRPC-Web UI backend, not a plain REST API, so an earlier version of this code that called it directly always failed with `501 Not Implemented`.

A **300s cooldown** (`REMEDIATION_COOLDOWN` env var) prevents the detector from re-triggering a new action before the previous one has had time to actually complete — without it, a model that keeps flagging anomalies will re-patch `restartAt` every cycle and the rollout never stabilizes.

**Known gotcha:** the `PodDisruptionBudget` (`k8s/service.yaml`) must allow at least one pod to be evicted at your current replica count — `minAvailable` equal to the replica count makes the disruption budget zero and permanently blocks restarts (this actually happened during initial testing; the fix was switching to `maxUnavailable: 1`).

---

## Part 1 — Provision the VM

Any Ubuntu 22.04 VM with at least 2 vCPU / 4GB RAM works. This was built and tested against **Azure**, but nothing here is Azure-specific beyond the IP address baked into a couple of files (see [Part 4](#part-4--point-the-scripts-at-your-server)).

| Provider | Recommended Size |
|---|---|
| Azure | Standard_B2s |
| AWS | t3.medium |
| GCP | e2-medium |
| DigitalOcean | Basic 4GB |

**Open these inbound ports** in your VM's firewall/NSG:
- **22** (SSH)
- **30080** (ArgoCD UI, also used by the CI pipeline)
- **30090** (the app, via NodePort)
- **80** (if you want the Nginx Ingress canary traffic-split to work over plain HTTP)
- Anything else you patch to NodePort later (e.g. **30030** for Grafana — see below)

---

## Part 2 — One-time server bootstrap

SSH into the VM (as a **non-root** user — see the note below on why this matters), clone the repo, and run the setup script:

```bash
ssh <your-user>@<your-server-ip>
git clone https://github.com/code-and-secure/Self-Healing-Deployment-Engine.git
cd Self-Healing-Deployment-Engine
bash scripts/server-setup.sh https://github.com/code-and-secure/Self-Healing-Deployment-Engine
```

This single script (`scripts/server-setup.sh`) does all of the following, in order:
1. Installs **k3s** (Traefik disabled — Nginx Ingress is used instead, for canary traffic splitting)
2. Installs **Helm**
3. Installs **Nginx Ingress Controller**
4. Installs **ArgoCD**, exposes it on NodePort `30080`, prints the initial admin password
5. Installs **Argo Rollouts** + its dashboard + the `kubectl argo rollouts` CLI plugin
6. Runs `scripts/install.sh` — installs `kube-prometheus-stack` (Prometheus + Grafana + Alertmanager) via Helm, applies Prometheus alert rules and Argo Rollouts AnalysisTemplates
7. Installs the `argocd` CLI, enables the `apiKey` capability on the admin account (required — the built-in admin only has `login` capability by default), and generates a non-expiring API token
8. Registers the ArgoCD `Application` manifests (`argocd/application.yaml`) so ArgoCD starts tracking this repo

**Important — always SSH in as the same non-root user afterward.** Everything here (the git checkout, `argocd` CLI config, RBAC) ends up owned by whichever user runs this script. If you later SSH in as `root` to do manual work, files can end up owned by `root`, and the CI pipeline (which connects as `SERVER_USER`) will start failing with permission errors on `git fetch`/`git pull`. If that happens: `sudo chown -R <ci-user>:<ci-user> ~/Self-Healing-Deployment-Engine`.

---

## Part 3 — Set GitHub Secrets

The pipeline needs exactly three secrets (Settings → Secrets and variables → Actions):

| Secret | Value |
|---|---|
| `SERVER_USER` | the SSH username you used above |
| `SERVER_SSH_KEY` | the private key matching that user's `authorized_keys` on the VM |
| `ARGOCD_AUTH_TOKEN` | printed by `server-setup.sh` in Step 7 above |

That's it — no `KUBECONFIG` secret. GitHub Actions never talks to the Kubernetes API directly; it SSHes to the VM and runs `argocd`/`kubectl` commands there.

If you ever need to regenerate the token (e.g. it was accidentally shared/leaked):
```bash
argocd account generate-token --account admin --insecure
```
then update the `ARGOCD_AUTH_TOKEN` secret with the new value.

---

## Part 4 — Point the scripts at your server

`SERVER_IP` is currently hardcoded in a few places rather than parameterized:
- `.github/workflows/deploy.yml` (`env.SERVER_IP`)
- `scripts/server-setup.sh` (`SERVER_IP` variable)

If you're deploying to your own server, update the IP in both places before pushing.

---

## Part 5 — Push and watch it deploy

```bash
git push origin main
```

Watch the Actions tab — four jobs run in sequence:
1. **Bootstrap Server (one-time)** — no-ops instantly on future runs once k3s+ArgoCD are detected as already installed
2. **Build & Push Images** — builds and pushes both images to GHCR, tagged with the commit SHA
3. **Update Image Tags in Manifests** — bumps the image tag in `argo-rollouts/rollout.yaml` and `ml/deployment.yaml`, commits, and pushes (with retry-on-conflict, since concurrent runs can race on this push)
4. **Trigger ArgoCD Sync** — SSHes in, refreshes the server's git checkout, and syncs both ArgoCD Applications
5. **Monitor Canary Rollout** — SSHes in and watches `kubectl argo rollouts status --watch` until the canary (20% → 50% → 100%, with a smoke-test gate) completes or fails

---

## Access

| Service | URL | Notes |
|---|---|---|
| App | `http://<server-ip>:30090` | |
| ArgoCD | `https://<server-ip>:30080` | `admin` / password from Step 4 of `server-setup.sh` |
| Argo Rollouts dashboard | `kubectl argo rollouts dashboard -n self-healing` (port 3100) | UI only — not a REST API (see architecture note above) |
| Grafana | not exposed by default | see below |
| Prometheus (custom) | not exposed by default | `kubectl port-forward -n self-healing svc/prometheus 9090:9090` |

### Expose Grafana (optional)
Grafana isn't tracked by ArgoCD (it's Helm-managed, outside git), so this is a one-off `kubectl patch` rather than a committed manifest change:
```bash
kubectl patch svc kube-prometheus-stack-grafana -n self-healing \
  -p '{"spec":{"type":"NodePort","ports":[{"port":80,"targetPort":3000,"nodePort":30030}]}}'
```
Then open the port in your firewall/NSG and visit `http://<server-ip>:30030` (`admin`/`admin` — change this password after first login).

### Import the Grafana dashboard
Because of the two-Prometheus-instances issue explained above, the pre-provisioned dashboard ConfigMap (`monitoring/grafana/provisioning.yaml`) only contains a placeholder — it was never actually wired up to auto-load. Import it manually:
1. Grafana → **Connections** → **Data sources** → **Add data source** → **Prometheus**
   URL: `http://prometheus.self-healing:9090` (the custom one, not the Helm one) → **Save & test**
2. Under this new datasource's settings, toggle it **Default** (so the imported dashboard's panels, which don't specify a datasource per-panel, use it automatically)
3. **Dashboards** → **New** → **Import** → upload `monitoring/grafana/dashboard.json` (or paste its contents)

---

## Test self-healing

```bash
# Terminal 1 — watch the rollout
kubectl argo rollouts get rollout healing-app -n self-healing --watch

# Terminal 2 — watch the detector reason about it live
kubectl logs -n self-healing -l app=anomaly-detector -f

# Terminal 3 — inject a failure
bash scripts/inject-failure.sh enable 0.5

# Terminal 4 — generate real traffic so the injected error rate actually
# shows up in Prometheus (nothing calls the app otherwise)
for i in $(seq 1 200); do
  curl -s -o /dev/null http://<server-ip>:30090/api/data
  curl -s -o /dev/null http://<server-ip>:30090/
  sleep 0.2
done
```
Turn it off: `bash scripts/inject-failure.sh disable`

---

## Manual operations (outside the normal CI/CD path)

These scripts talk to a `localhost:5000`-style registry and drive the Rollout directly — useful for ad hoc testing on a cluster you have direct `kubectl` access to (e.g. the `kind` local setup), but **not** what the GitHub Actions pipeline uses for the real deployment:

```bash
bash scripts/deploy.sh v2       # build, push, kubectl argo rollouts set image, watch
bash scripts/rollback.sh        # interactive: kubectl argo rollouts undo, with confirmation prompt
```

See [COMMANDS.md](COMMANDS.md) for the full command reference with what each one is actually for.

---

## Troubleshooting

Real issues hit while building this out, and their causes — in case any of these come back:

| Symptom | Cause |
|---|---|
| `git fetch`/`git pull` on the server fails with `Permission denied` | The checkout is owned by a different user than `SERVER_USER` (usually because someone `sudo su`'d and did manual work as root). Fix: `sudo chown -R <ci-user>:<ci-user> ~/Self-Healing-Deployment-Engine` |
| ArgoCD sync fails: `invalid session: token has invalid claims: token is expired` | The pipeline was relying on a cached interactive CLI login session instead of the non-expiring `ARGOCD_AUTH_TOKEN`. Make sure that secret is actually set. |
| `argocd account generate-token` fails: `account 'admin' does not have apiKey capability` | Run: `kubectl -n argocd patch configmap argocd-cm --type merge -p '{"data":{"accounts.admin":"apiKey,login"}}'` then restart `argocd-server` |
| ArgoCD sync fails: `another operation is already in progress` | Transient — `terminate-op` is async and can race a following `sync`. The pipeline already retries this a few times. |
| Rollout resources exist in git but never show up in `kubectl get rollout` / ArgoCD's tracked resources | Check `argocd/application.yaml`'s `include` glob for YAML folding bugs — an indented continuation line under `>-` preserves literal newlines instead of folding to spaces, silently corrupting the glob pattern. Use single-line flow strings instead: `include: "{a/*.yaml,b/*.yaml}"` |
| Both a plain `Deployment` and a `Rollout` exist for `healing-app`, doubling pod count | `k8s/deployment.yaml` used to be tracked by ArgoCD alongside `argo-rollouts/rollout.yaml`. It's been removed — if you see this again, check `argocd/application.yaml`'s include pattern. |
| Anomaly detector logs `501 Not Implemented` on every remediation attempt | It was calling the Argo Rollouts dashboard as if it were a REST API. Fixed by patching the Kubernetes API directly instead (see [How self-healing actually works](#how-self-healing-actually-works)). |
| Rollout stuck forever in `Progressing` / `rollout is restarting`, pods never actually recycle | Check the PDB: `kubectl get pdb healing-app-pdb -n self-healing` — if `ALLOWED DISRUPTIONS` is permanently `0`, `minAvailable` is set equal to your replica count. Switch to `maxUnavailable: 1`. |
| Grafana dashboard shows "No data" on every panel | Wrong Prometheus datasource — see [Import the Grafana dashboard](#import-the-grafana-dashboard) above. |

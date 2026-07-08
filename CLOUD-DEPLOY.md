# Cloud Deployment Guide

## What's running

One Azure VM. On it:
- **k3s** — a lightweight Kubernetes
- **ArgoCD** — watches this GitHub repo and keeps the cluster in sync with it
- **Argo Rollouts** — rolls out new versions gradually (canary), instead of all at once
- **GitHub Actions** — builds the app, and tells ArgoCD to deploy it, every time you push to `main`

You never run `kubectl apply` by hand day-to-day. Push to `main`, and everything else happens on its own.

Don't have a cloud VM? See [LOCAL-DEPLOY.md](LOCAL-DEPLOY.md) instead — it can run entirely on your own machine.

---

## How a deploy actually happens

```
1. You push to main
2. GitHub Actions builds the app image and pushes it to GitHub's registry
3. GitHub Actions updates the deployment files with the new image, and pushes that
4. GitHub Actions tells ArgoCD (on the server) to sync
5. ArgoCD pulls the updated files from GitHub and applies them
6. Argo Rollouts rolls out the new version gradually: 20% traffic → test → 50% → 100%
```

---

## How self-healing works

A background process (the "anomaly detector") checks the app's health every 30 seconds. If something looks wrong, it picks one of these fixes automatically:

| How bad it is | What it does |
|---|---|
| Very bad | Rolls back to the last known-good version |
| High error rate | Stops the current rollout in its tracks |
| Slow responses | Adds more replicas |
| Anything else unusual | Restarts the unhealthy pods |

It does this by talking to Kubernetes directly — not through any dashboard or UI.

Full breakdown of the decision logic: see [README.md](README.md#how-it-works-end-to-end).

---

## One thing to know: two Prometheus installs

There are **two** separate Prometheus instances on this cluster:

1. `prometheus` — this project's own one. **This has your actual app data.**
2. `kube-prometheus-stack-prometheus` — comes bundled with Grafana. Has no app data at all.

Grafana defaults to using #2, which is why dashboards often show "No data" the first time. Fix: [TROUBLESHOOTING.md](TROUBLESHOOTING.md#fix-grafana-shows-no-data-on-every-panel).

---

## Step 1 — Get a server

Any Ubuntu 22.04 VM, 2 vCPU / 4GB RAM or more. Built and tested on Azure, but any cloud works the same way.

**Open these ports** on the VM's firewall:
- `22` — SSH
- `30080` — ArgoCD
- `30090` — the app
- `80` — optional, for plain HTTP traffic routing

---

## Step 2 — Run the setup script

SSH in, then:

```bash
git clone https://github.com/code-and-secure/Self-Healing-Deployment-Engine.git
cd Self-Healing-Deployment-Engine
bash scripts/server-setup.sh https://github.com/code-and-secure/Self-Healing-Deployment-Engine
```

This one script installs everything: Kubernetes, ArgoCD, Argo Rollouts, monitoring, and it registers this repo with ArgoCD. Takes a few minutes. At the end it prints an ArgoCD API token — copy it, you'll need it in Step 3.

**One rule to remember:** always SSH in as the same user going forward. If you switch to `root` and make changes, GitHub Actions will start failing to pull the latest code (permission errors). Fix if that happens: [TROUBLESHOOTING.md](TROUBLESHOOTING.md#fix-permission-denied-on-git-pull-on-the-server).

---

## Step 3 — Add 3 GitHub secrets

Go to your repo → **Settings → Secrets and variables → Actions**, and add:

| Secret name | Value |
|---|---|
| `SERVER_USER` | the SSH username you used in Step 2 |
| `SERVER_SSH_KEY` | your private SSH key for that server |
| `ARGOCD_AUTH_TOKEN` | the token printed at the end of Step 2 |

That's it — just these three. Nothing else is needed.

Token expired or need a new one? [TROUBLESHOOTING.md](TROUBLESHOOTING.md#fix-argocd-auth-token-expired).

---

## Step 4 — Update the server IP

Two files still have the IP hardcoded — update both if you're using your own server:
- `.github/workflows/deploy.yml` (`SERVER_IP`)
- `scripts/server-setup.sh` (`SERVER_IP`)

---

## Step 5 — Push and watch

```bash
git push origin main
```

Go to the **Actions** tab on GitHub and watch it run. It builds, deploys, and rolls out automatically.

---

## Where things live

| What | Where |
|---|---|
| The app | `http://<server-ip>:30090` |
| ArgoCD | `https://<server-ip>:30080` ( `admin` / password from Step 2) |
| Grafana | not public by default — see below |

### Turn on Grafana access
```bash
kubectl patch svc kube-prometheus-stack-grafana -n self-healing \
  -p '{"spec":{"type":"NodePort","ports":[{"port":80,"targetPort":3000,"nodePort":30030}]}}'
```
Then visit `http://<server-ip>:30030` (`admin` / `admin` — change this password).

### Load the dashboard
The dashboard doesn't load automatically. Do this once:
1. Grafana → **Connections** → **Data sources** → **Add data source** → **Prometheus**
2. URL: `http://prometheus.self-healing:9090`
3. **Save & test**, then toggle it **Default**
4. **Dashboards** → **New** → **Import** → upload `monitoring/grafana/dashboard.json`

---

## Try out self-healing

Open 4 terminals:

```bash
# 1 — watch the rollout
kubectl argo rollouts get rollout healing-app -n self-healing --watch

# 2 — watch the detector's decisions
kubectl logs -n self-healing -l app=anomaly-detector -f

# 3 — turn on simulated errors
bash scripts/inject-failure.sh enable 0.5

# 4 — send it real traffic (the error only shows up if requests happen)
for i in $(seq 1 200); do
  curl -s -o /dev/null http://<server-ip>:30090/api/data
  curl -s -o /dev/null http://<server-ip>:30090/
  sleep 0.2
done
```

Turn it back off:
```bash
bash scripts/inject-failure.sh disable
```

---

## Manual commands (skip the pipeline)

For quick manual testing only — not what the real pipeline uses:
```bash
bash scripts/deploy.sh v2      # manually build + deploy a version
bash scripts/rollback.sh       # manually roll back
```

Full list: [COMMANDS.md](COMMANDS.md)

---

## Something broken?

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — copy-paste fixes for every issue hit while building this, including password resets and expired-token fixes.

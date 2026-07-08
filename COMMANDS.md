# Useful Commands

A reference of the commands you'll actually reach for, grouped by what you're trying to do, with **why** you'd run each one. For full setup steps see [LOCAL-DEPLOY.md](LOCAL-DEPLOY.md) or [CLOUD-DEPLOY.md](CLOUD-DEPLOY.md). If something's actually broken, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

All Kubernetes commands below assume the cloud/kind path (namespace `self-healing`); Docker Compose equivalents are noted where relevant.

---

## See what's actually running

```bash
kubectl get rollout healing-app -n self-healing
```
Quick status: healthy/degraded, current step, image in use. This is the `Deployment` equivalent for canary-managed apps — `kubectl get deployment` won't show it since it's a different resource kind.

```bash
kubectl argo rollouts get rollout healing-app -n self-healing --watch
```
The real one to reach for — shows the canary steps as a live tree (revisions, ReplicaSets, AnalysisRuns, pods), not just a status line. `--watch` streams updates instead of a single snapshot.

```bash
kubectl get pods -n self-healing -l app=healing-app -o wide
```
Pod names, ready state, restart count, age. Compare pod `AGE` against a Rollout's `spec.restartAt` to confirm a restart actually happened rather than just being requested.

```bash
argocd app get self-healing-engine --insecure
```
Whether ArgoCD thinks git and the live cluster match (`Synced` vs `OutOfSync`) and overall health. Run this first whenever something "isn't showing up" — if a resource type isn't listed here, ArgoCD isn't tracking it at all (check `argocd/application.yaml`'s `include` glob).

```bash
argocd app diff self-healing-engine --insecure
```
Shows exactly which fields differ between git and live, when `OutOfSync` — the fastest way to tell a real problem from a harmless one (e.g. a controller-added default field, see `ignoreDifferences` in `argocd/application.yaml`).

---

## Logs

```bash
kubectl logs -n self-healing -l app=anomaly-detector -f
```
The most important one for understanding self-healing — every detection cycle logs its anomaly score and, when triggered, which remediation action it picked and whether the Kubernetes API patch succeeded.

```bash
kubectl logs -n self-healing -l app=healing-app -f
```
App-level request logs — useful when correlating injected failures with what the detector actually saw.

---

## Test self-healing end-to-end

```bash
bash scripts/inject-failure.sh enable 0.5
```
Flips a flag in the running app (`/admin/inject-failure`) so `/` and `/api/data` start returning 500/503 at the given rate. **This alone does nothing without traffic** — the error only shows up in Prometheus once real requests hit those endpoints.

```bash
for i in $(seq 1 200); do
  curl -s -o /dev/null http://<server-ip>:<port>/api/data
  curl -s -o /dev/null http://<server-ip>:<port>/
  sleep 0.2
done
```
Generates that traffic. In Docker Compose, use `bash compose/generate-traffic.sh` instead — it also prints a live status line pulled from Prometheus and the detector's own API.

```bash
bash scripts/inject-failure.sh disable
```
Turns the injected failure back off. Do this before walking away — otherwise the detector will keep firing remediations indefinitely (rate-limited by its 300s cooldown, but still noisy).

---

## Manual deploy / rollback (bypasses the GitOps pipeline)

These talk to a `localhost:5000`-style registry and act on the cluster directly — useful when you have direct `kubectl` access (e.g. `kind`) and want to test without going through GitHub Actions. **Not** what production actually uses (see [CLOUD-DEPLOY.md](CLOUD-DEPLOY.md) for the real pipeline).

```bash
bash scripts/deploy.sh v2
```
Builds `app/` as `<registry>/healing-app:v2`, pushes it, and does `kubectl argo rollouts set image` — then watches the canary through to completion.

```bash
bash scripts/rollback.sh          # rolls back to the previous stable revision
bash scripts/rollback.sh 5        # rolls back to a specific revision number
```
Interactive — prints current state and asks for confirmation before calling `kubectl argo rollouts undo`.

---

## ArgoCD

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```
Retrieves the auto-generated admin password. Only works before the password has ever been changed — ArgoCD deletes this secret once it is.

```bash
argocd account generate-token --account admin --insecure
```
Generates a **non-expiring** API token for CI to use — this is what `ARGOCD_AUTH_TOKEN` should be, instead of relying on an interactive CLI login session (which does expire, and did, repeatedly, before this was fixed).

```bash
argocd app sync self-healing-engine --insecure
argocd app sync self-healing-monitoring --insecure
```
Force an immediate sync instead of waiting for ArgoCD's periodic auto-sync. Useful right after manually editing `argocd/application.yaml` itself, since ArgoCD doesn't watch changes to its own `Application` object automatically — see the next command.

```bash
sed "s|https://github.com/YOUR_ORG/YOUR_REPO|<your-repo-url>|g" argocd/application.yaml | kubectl apply -f -
```
Re-applies the `Application` manifest itself. **You need this specifically whenever you change `argocd/application.yaml`** (e.g. its `include` glob or `ignoreDifferences`) — ArgoCD only auto-syncs resources it already tracks; it doesn't reconcile its own definition from git.

---

## Grafana / Prometheus

```bash
kubectl get svc -n self-healing | grep -i prometheus
```
Lists both Prometheus instances running in this cluster (`prometheus` — the custom one with your actual app metrics, and `kube-prometheus-stack-prometheus` — Helm's, which doesn't scrape the app). See [CLOUD-DEPLOY.md](CLOUD-DEPLOY.md#architecture) for why this matters.

```bash
kubectl patch svc kube-prometheus-stack-grafana -n self-healing \
  -p '{"spec":{"type":"NodePort","ports":[{"port":80,"targetPort":3000,"nodePort":30030}]}}'
```
Exposes Grafana over a NodePort so you can hit it directly at `<server-ip>:30030` instead of keeping an SSH tunnel + `kubectl port-forward` open. Not persisted in git (Grafana is Helm-managed) — re-run this if the service ever reverts to `ClusterIP`.

```bash
kubectl port-forward -n self-healing svc/prometheus 9090:9090
```
Direct access to the custom Prometheus (the one with real app metrics) for ad hoc PromQL queries at `http://localhost:9090`.

---

## Debugging a stuck rollout / restart

```bash
kubectl get pdb healing-app-pdb -n self-healing
```
Check `ALLOWED DISRUPTIONS`. If it's permanently `0`, nothing can ever be evicted — a restart/rolling-update will hang forever. This happened once: `minAvailable` was set equal to the total replica count, making the disruption budget mathematically zero.

```bash
kubectl get rollout healing-app -n self-healing -o jsonpath='{.spec.restartAt}'; echo
```
Confirms whether the anomaly detector's restart patch actually landed (should show a recent timestamp).

```bash
kubectl describe rollout healing-app -n self-healing
```
Full event history — use this when `kubectl argo rollouts get rollout` shows a stuck/unexpected state and you need to know *why*.

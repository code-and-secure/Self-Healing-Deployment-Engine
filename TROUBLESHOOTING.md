# Troubleshooting

Every real issue hit while building and operating this project, with root cause, fix, and how to verify it worked. If something breaks and it's not here, check [COMMANDS.md](COMMANDS.md) for the diagnostic command you need, then add the fix here once you find it.

---

## ArgoCD basics — password, login, tokens

### Get the initial admin password
```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```
Only works **before** the password has ever been changed — ArgoCD deletes this secret the moment it's rotated.

### Password already rotated / secret not found
Reset it by clearing the stored password, which makes ArgoCD regenerate a fresh initial-admin secret:
```bash
kubectl -n argocd patch secret argocd-secret \
  -p '{"stringData": {"admin.password": null, "admin.passwordMtime": null}}'
kubectl -n argocd rollout restart deployment argocd-server
```
Then re-run the `get secret argocd-initial-admin-secret` command above.

### Log in via CLI
```bash
argocd login localhost:30080 --username admin --password '<password>' --insecure
```
This also saves the server address into the CLI's local context (`~/.config/argocd/config`) — subsequent commands like `argocd app sync` work without needing `--server` again.

### Generate a non-expiring API token (for CI)
```bash
argocd account generate-token --account admin --insecure
```
Use this instead of relying on the interactive login session for anything automated — see [Issue: ArgoCD session token expires](#issue-argocd-session-token-expires) below for why.

---

## Issue: `Argo CD server address unspecified`
**When:** running `argocd account generate-token` (or any argocd command) directly, without having logged in first.
**Cause:** the CLI has no saved server context.
**Fix:** run `argocd login <server>:30080 --username admin --password '<password>' --insecure` first — this saves the context — then retry the original command.

---

## Issue: `account 'admin' does not have apiKey capability`
**When:** running `argocd account generate-token`.
**Cause:** the built-in `admin` account only has `login` capability by default, not `apiKey`.
**Fix:**
```bash
kubectl -n argocd patch configmap argocd-cm --type merge -p '{"data":{"accounts.admin":"apiKey,login"}}'
kubectl -n argocd rollout restart deployment argocd-server
kubectl -n argocd rollout status deployment argocd-server --timeout=120s
```
Then retry `argocd account generate-token --account admin --insecure`.

`scripts/server-setup.sh` now does this automatically — this only bites you if you're generating a token by hand on an existing cluster.

---

## Issue: ArgoCD session token expires
**Symptom:** CI job fails with `invalid session: token has invalid claims: token is expired`, sometimes after working fine for a while.
**Cause:** the pipeline was relying on the `argocd` CLI's cached interactive login session (a JWT with a default TTL, e.g. 24h) instead of a real API token. Nothing ever re-logs in, so it eventually expires and every subsequent sync fails.
**Fix:** generate a non-expiring account token (see above) and set it as the `ARGOCD_AUTH_TOKEN` GitHub secret. The pipeline passes it via `ARGOCD_AUTH_TOKEN`/`ARGOCD_SERVER`/`ARGOCD_INSECURE` environment variables instead of depending on any saved session.
**Verify:** re-run the failed workflow — the `Sync ArgoCD apps on server` step should succeed.

---

## Issue: `another operation is already in progress`
**When:** `argocd app sync` runs right after `argocd app terminate-op`.
**Cause:** `terminate-op` is asynchronous — the very next command can run before the controller has actually cleared the old operation. Made worse by `syncPolicy.automated` on the `Application`, since ArgoCD's own controller can kick off a sync at nearly the same moment as a manual CLI-triggered one.
**Fix:** the pipeline retries each sync a few times with a short backoff (see `.github/workflows/deploy.yml`, the `sync-argocd` job) instead of failing outright on the first race.

---

## Issue: `git fetch`/`git pull` fails with `Permission denied` on the server
**Symptom:** `error: cannot open '.git/FETCH_HEAD': Permission denied`.
**Cause:** the repo checkout on the server ended up owned by a different user than the one the CI pipeline SSHes in as (`SERVER_USER`) — usually because someone did `sudo su` or logged in as `root` and ran git commands there.
**Fix:**
```bash
sudo chown -R <ci-user>:<ci-user> ~/Self-Healing-Deployment-Engine
```
**Prevention:** always SSH in as the same non-root user the pipeline uses. If you need elevated privileges for something, use `sudo <command>` from that user rather than switching to a full root shell.

---

## Issue: Rollout / other resources exist in git but ArgoCD never tracks them
**Symptom:** `kubectl get rollout` shows nothing, or `argocd app get <app>` lists fewer resource types than you expect (e.g. missing the `Rollout`, `AnalysisTemplate`, or a specific `Deployment`), even though `argocd app diff` shows no differences.
**Cause:** a YAML folding bug in `argocd/application.yaml`'s `include` field. A folded block scalar (`>-`) with continuation lines indented *more* than the first line preserves literal newlines instead of folding them to spaces — so glob tokens after the first one end up with a leading `\n` baked into the string and never match any real path.
```yaml
# BROKEN — extra indentation on continuation lines prevents folding
include: >-
  {k8s/*.yaml,
   argo-rollouts/*.yaml,
   ml/deployment.yaml}
```
**Fix:** use a single-line flow string instead:
```yaml
include: "{k8s/*.yaml,argo-rollouts/*.yaml,ml/deployment.yaml}"
```
**Verify:**
```bash
kubectl -n argocd get application self-healing-engine -o jsonpath="{.spec.source.directory}"; echo
```
should print the include pattern with no embedded `\n` sequences.
**Important:** after fixing this file, ArgoCD does **not** pick up the change automatically — it doesn't watch its own `Application` object for git changes. Re-apply it manually:
```bash
sed "s|https://github.com/YOUR_ORG/YOUR_REPO|<your-repo-url>|g" argocd/application.yaml | kubectl apply -f -
argocd app sync self-healing-engine --insecure
```

---

## Issue: Both a plain `Deployment` and a `Rollout` exist for the same app
**Symptom:** double the expected pod count (e.g. 6 pods instead of 3), both matching the same `app: healing-app` label that the Service selects on — meaning traffic gets split across canary-managed and non-canary-managed pods, defeating the whole point of the canary.
**Cause:** `k8s/deployment.yaml` (a leftover from before Argo Rollouts was introduced) was still included in `argocd/application.yaml`'s glob alongside `argo-rollouts/rollout.yaml`, so ArgoCD kept both permanently reconciled side by side.
**Fix:** removed `k8s/deployment.yaml` entirely, narrowed the `include` glob to only the `k8s/` files still needed (`namespace.yaml`, `service.yaml`, `hpa.yaml`), and retargeted the HPA (`k8s/hpa.yaml`) at the `Rollout` instead of the `Deployment`.
**If you see this again:** check `argocd/application.yaml`'s include pattern for a stray `k8s/*.yaml` glob that would re-include a plain Deployment manifest.

---

## Issue: ArgoCD shows `OutOfSync` forever even though `argocd app diff` shows a trivial field
**Symptom:** `argocd app diff` repeatedly shows something like:
```
===== argoproj.io/Rollout self-healing/healing-app ======
130a131
>       autoPromotionEnabled: false
```
even right after a fresh sync, and it never resolves.
**Cause:** `autoPromotionEnabled` is a `bool` field with `omitempty` in the Rollout CRD's Go struct. Git's explicit `false` gets dropped during JSON serialization (since `false` is a bool's zero value) and becomes indistinguishable from "unset," while the live object — touched by the Argo Rollouts controller — keeps an explicit key. Git and live are semantically identical; this is a serialization quirk, not a real drift.
**Fix:** added an `ignoreDifferences` entry for this field in `argocd/application.yaml`, the same way `/spec/replicas` is already ignored for HPA-managed drift:
```yaml
ignoreDifferences:
  - group: argoproj.io
    kind: Rollout
    jsonPointers:
      - /spec/replicas
      - /spec/strategy/canary/autoPromotionEnabled
```
Remember: this also needs the manual re-apply step described above, since it's a change to `application.yaml` itself.

---

## Issue: Canary AnalysisRun errors with `reflect: slice index out of range`
**Symptom:** `kubectl argo rollouts get rollout` shows the rollout aborted with a message like:
```
RolloutAborted: Rollout aborted update to revision N: Metric "error-rate" assessed Error due to
consecutiveErrors (5) > consecutiveErrorLimit (4): "Error Message: reflect: slice index out of range"
```
even though nothing is actually wrong with the app.
**Cause:** the AnalysisTemplate's Prometheus query (e.g. `sum(rate(http_requests_total{status_code=~"5.."}[2m])) / sum(rate(http_requests_total[2m]))`) returns an **empty vector** — not `0` — when no matching series exist yet (e.g. no 5xx traffic at all on a fresh canary). Argo Rollouts then indexes `result[0]` on that empty result and panics, which counts as a consecutive error and aborts the rollout.
**Fix:** force a fallback value with `OR on() vector(n)` so the query always returns a sample:
```yaml
query: |
  (sum(rate(http_requests_total{status_code=~"5..",job="..."}[2m])) OR on() vector(0))
  /
  (sum(rate(http_requests_total{job="..."}[2m])) OR on() vector(1))
```
**Broader fix applied:** the canary was ultimately simplified from 13 steps with 3 Prometheus AnalysisTemplate gates down to 3 steps with just a lightweight smoke-test job — the ML anomaly detector (which queries Prometheus independently) is the project's actual automated-remediation gatekeeper, so the extra Argo Rollouts-native analysis gates were redundant on top of it and were the source of this whole class of bug.

---

## Issue: Anomaly detector logs `501 Not Implemented` on every remediation attempt
**Symptom:**
```
ERROR anomaly-detector Restart failed: 501 Server Error: Not Implemented for url:
http://argo-rollouts-dashboard.argo-rollouts:3100/api/v1/namespaces/self-healing/rollouts/healing-app/restart
```
— and this happens for every action (restart/abort/scale/rollback), including plain reads.
**Cause:** the Argo Rollouts dashboard only serves its own gRPC-Web UI backend, not a plain REST API. Calling it with a bare `curl`/`requests` GET/PUT falls through to a catch-all `501` handler regardless of the path.
**Fix:** rewrote all four remediation actions in `ml/anomaly_detector.py` to patch the `Rollout` custom resource **directly via the Kubernetes API** instead — the same mechanism `kubectl argo rollouts` itself uses:
- restart → merge-patch `spec.restartAt` to now
- abort → merge-patch `status.abort: true`
- scale up → merge-patch `spec.replicas`
- rollback → read `status.stableRS`, find that ReplicaSet's pod template, patch it into `spec.template`

Requires a dedicated `ServiceAccount` + `Role` (see `ml/deployment.yaml`) scoped to `get/patch` on `rollouts`/`rollouts/status` and read-only on `replicasets`, in the `self-healing` namespace.
**Verify:** `kubectl logs -n self-healing -l app=anomaly-detector -f` should show no more `ApiException`/`501` errors after a remediation attempt, and `kubectl get rollout healing-app -n self-healing -o jsonpath='{.spec.restartAt}'` should reflect a recent timestamp after a restart action.

---

## Issue: Rollout stuck forever in `Progressing` / `rollout is restarting`
**Symptom:** `spec.restartAt` is set correctly, but pods never actually recycle — same pod names, same ages, restart count stays 0, indefinitely.
**Cause:** the `PodDisruptionBudget` (`k8s/service.yaml`) had `minAvailable: 2` while the Rollout only had 2 total replicas (HPA's `minReplicas`). `minAvailable` equal to the replica count makes the disruption budget mathematically zero — the Eviction API permanently refuses to evict any pod, since doing so would (by definition) drop availability below `minAvailable`.
**Fix:**
```yaml
spec:
  maxUnavailable: 1   # instead of minAvailable: 2
```
This allows one pod at a time to be evicted regardless of total replica count, while still guaranteeing at least one pod stays up during any disruption.
**Verify:**
```bash
kubectl get pdb healing-app-pdb -n self-healing
```
`ALLOWED DISRUPTIONS` should show `1` (or briefly `0` mid-restart while a pod is temporarily not-ready — that's expected transient state, not the bug).

---

## Issue: Pods churn continuously, never reaching steady state
**Symptom:** pod names keep changing on every check — a restart never actually finishes, it just keeps starting a new one.
**Cause:** the anomaly detector's model was flagging `anomaly=True` continuously (even on idle/ambient traffic), so every ~30s detection cycle re-triggered `_restart_unhealthy_pods()`, patching `restartAt` with a **new** timestamp before the previous restart cycle had even finished.
**Fix:** added a cooldown (`REMEDIATION_COOLDOWN`, default 300s) so a new remediation action can't fire until the previous one has had time to actually complete:
```python
elapsed = time.time() - self._last_remediation_at
if elapsed < REMEDIATION_COOLDOWN:
    logger.info("Skipping remediation — %.0fs into %ds cooldown", elapsed, REMEDIATION_COOLDOWN)
    return
```
**Note:** this doesn't fix model miscalibration itself (worth tuning `ANOMALY_THRESHOLD`/`WARMUP_SAMPLES` if the detector fires too eagerly in a low-traffic environment) — it just stops that miscalibration from causing a disruptive restart loop.

---

## Issue: Grafana dashboard shows "No data" on every panel
**Cause:** two independent Prometheus instances exist in this cluster (the custom one this repo deploys, which actually has your app metrics, and `kube-prometheus-stack-prometheus`, bundled with Grafana via Helm, which only scrapes standard cluster metrics via ServiceMonitor/PodMonitor CRDs that nothing here creates). Grafana's default datasource points at the wrong one.
**Fix:**
1. Grafana → **Connections** → **Data sources** → **Add data source** → **Prometheus**, URL `http://prometheus.self-healing:9090` (the custom one) → **Save & test**
2. Toggle this new datasource **Default** (the dashboard's panels don't specify a datasource per-panel, so they all follow whichever one is marked default)
**Verify:** refresh the dashboard — panels should immediately show data, since the metrics were there the whole time.

---

## Issue: The `kind`-based local deployment never actually worked
**Symptom:** `compose/setup-kind.sh` runs without erroring, but `localhost:8080`/`:9090` don't respond, or Prometheus/healing-app Helm install fails with a port-already-allocated error.
**Causes (three separate bugs):**
1. The script referenced `local/kind-cluster.yaml`, but the file actually lives at `compose/kind-cluster.yaml`
2. `kind-cluster.yaml`'s port mapping still said `containerPort: 30080` for the app, but the app's real NodePort is `30090` (changed earlier to avoid conflicting with ArgoCD's own `30080`) — and the script's own Helm install also assigned Prometheus to NodePort `30090`, colliding with the app
3. The script built and loaded `healing-app:1.0.0`/`anomaly-detector:1.0.0` into the kind cluster, but then applied `argo-rollouts/rollout.yaml`/`ml/deployment.yaml` as-is — which still reference the GHCR image tags used in production, so the locally-built images were never actually used
**Fix:** corrected the file path, moved Prometheus to NodePort `30091` to avoid the collision, and piped the manifests through `sed` to substitute the local image tags before applying — mirroring the pattern the CI pipeline already uses for the cloud path.

---

## Issue: GitHub repo rename/case-change breaks `git push`
**Symptom:** `git push` succeeds but prints:
```
remote: This repository moved. Please use the new location:
remote:   https://github.com/<org>/<NewCasing>.git
```
**Cause:** the repository was renamed (in this case, a casing change). GitHub redirects pushes to the old URL automatically, but relying on the redirect indefinitely is fragile.
**Fix:**
```bash
git remote set-url origin https://github.com/<org>/<NewCasing>.git
```

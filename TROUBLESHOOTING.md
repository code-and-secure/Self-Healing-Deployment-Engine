# Troubleshooting

Quick fixes first, detailed explanations below. Full command reference: [COMMANDS.md](COMMANDS.md).

---

## Quick Fixes

### Get the ArgoCD UI password

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

Login is `admin` + whatever that prints. URL: `https://<server-ip>:30080`

**If that command returns nothing:** the password was already changed once, so ArgoCD deleted this secret. Reset it:

```bash
kubectl -n argocd patch secret argocd-secret \
  -p '{"stringData": {"admin.password": null, "admin.passwordMtime": null}}'
kubectl -n argocd rollout restart deployment argocd-server
```

Wait ~30 seconds, then run the first command again.

---

### Fix "ArgoCD auth token expired"

This means the pipeline is using an old login session instead of a real API token. Generate a new one:

```bash
# 1. Log in (replace with your real password from above)
argocd login localhost:30080 --username admin --password '<password>' --insecure

# 2. Generate a token that never expires
argocd account generate-token --account admin --insecure
```

**If step 2 fails with `does not have apiKey capability`:**

```bash
kubectl -n argocd patch configmap argocd-cm --type merge -p '{"data":{"accounts.admin":"apiKey,login"}}'
kubectl -n argocd rollout restart deployment argocd-server
kubectl -n argocd rollout status deployment argocd-server --timeout=120s
```

Then repeat steps 1 and 2 above.

**Last step:** copy the token it prints, and update the `ARGOCD_AUTH_TOKEN` secret in GitHub (Settings → Secrets and variables → Actions).

---

### Fix "Permission denied" on git pull (on the server)

```bash
sudo chown -R <ci-user>:<ci-user> ~/Self-Healing-Deployment-Engine
```

Replace `<ci-user>` with whatever `SERVER_USER` is set to in GitHub secrets. This happens if someone SSHed in as `root` and touched the files — always SSH in as the same user the pipeline uses.

---

### Fix "Grafana shows No data on every panel"

Grafana is pointed at the wrong Prometheus. Add the right one:

1. Grafana → **Connections** → **Data sources** → **Add data source** → **Prometheus**
2. URL: `http://prometheus.self-healing:9090`
3. Click **Save & test**
4. Scroll down, toggle **Default** on
5. Refresh the dashboard

---

### Fix "ArgoCD app stuck OutOfSync"

```bash
argocd app diff self-healing-engine --insecure
```

This shows exactly what's different. If it's a real difference, fix the manifest in git and push. If it's a trivial/cosmetic field (like `autoPromotionEnabled: false`), it's already handled — see [the OutOfSync details below](#argocd-shows-outofsync-forever-on-a-trivial-field).

---

### Fix "Rollout stuck restarting forever, pods never change"

```bash
kubectl get pdb healing-app-pdb -n self-healing
```

If `ALLOWED DISRUPTIONS` shows `0`, the PodDisruptionBudget is blocking it. Fix:

```bash
kubectl patch pdb healing-app-pdb -n self-healing --type=json \
  -p '[{"op":"remove","path":"/spec/minAvailable"},{"op":"add","path":"/spec/maxUnavailable","value":1}]'
```

(This is already fixed in git going forward — this command is for a cluster still running the old config.)

---

## Detailed Explanations

Each issue below: what you saw, why it happened, how it was fixed for good.

### ArgoCD session token expires
**Symptom:** `invalid session: token has invalid claims: token is expired`
**Why:** the pipeline was using a cached login session (expires after ~24h) instead of a real token.
**Fixed by:** using `ARGOCD_AUTH_TOKEN` (a token that doesn't expire) everywhere instead. See [Quick Fixes](#fix-argocd-auth-token-expired) above if it happens again.

### Account doesn't have apiKey capability
**Symptom:** `account 'admin' does not have apiKey capability`
**Why:** the default admin account can log in, but can't generate tokens, until you turn that on.
**Fixed by:** see [Quick Fixes](#fix-argocd-auth-token-expired) above — `server-setup.sh` now does this step automatically for new servers.

### "Another operation is already in progress"
**Symptom:** ArgoCD sync fails with this message.
**Why:** normal race condition — cancelling one sync and starting another happens almost instantly, and sometimes overlaps.
**Fixed by:** the pipeline just retries a few times automatically now. No action needed.

### ArgoCD shows OutOfSync forever on a trivial field
**Symptom:** `argocd app diff` keeps showing the same tiny difference (e.g. `autoPromotionEnabled: false`) even right after syncing.
**Why:** a quirk in how Kubernetes handles `false` boolean values — git and the live cluster actually agree, but the comparison tool can't tell.
**Fixed by:** told ArgoCD to ignore that specific field, since it's not a real difference (see `ignoreDifferences` in `argocd/application.yaml`).

### Resources in git never show up in the cluster
**Symptom:** a file exists in the repo, but `kubectl get` never shows it, and ArgoCD doesn't track it.
**Why:** a formatting mistake in `argocd/application.yaml`'s file-matching pattern silently broke it for everything except the first entry.
**Fixed by:** rewrote the pattern on one line instead of spreading it across multiple indented lines.
**If you edit `argocd/application.yaml` yourself:** you must re-apply it manually — ArgoCD doesn't watch changes to its own settings file automatically:
```bash
sed "s|https://github.com/YOUR_ORG/YOUR_REPO|<your-repo-url>|g" argocd/application.yaml | kubectl apply -f -
```

### Double the pods you expect
**Symptom:** twice as many pods as expected, all serving traffic.
**Why:** an old, unused deployment file was still being applied alongside the new canary deployment.
**Fixed by:** deleted the old file, so only the canary-managed pods exist now.

### Canary rollout aborts by itself, error mentions "slice index out of range"
**Symptom:** a healthy-looking canary suddenly aborts with a Prometheus-related error.
**Why:** a metrics query returned "no data" instead of "0" when there was no traffic yet, and the code crashed trying to read a value that didn't exist.
**Fixed by:** the canary process was simplified — those extra checks were removed since the ML anomaly detector already handles this job independently.

### Self-healing actions fail with "501 Not Implemented"
**Symptom:** the anomaly detector logs an error every time it tries to restart/rollback/scale.
**Why:** it was talking to the wrong thing — the Argo Rollouts dashboard (a UI, not something you can send plain commands to).
**Fixed by:** rewrote it to talk to Kubernetes directly instead, which is the correct and supported way to do this.

### Pods keep restarting over and over, never settling down
**Symptom:** pods keep getting recreated in an endless loop.
**Why:** the anomaly detector kept detecting a problem and kept trying to fix it again every 30 seconds, before the previous fix even finished.
**Fixed by:** added a 5-minute cooldown — once it takes an action, it waits before trying again.

### Local `kind` setup doesn't work
**Why:** three small bugs in the setup script — a wrong file path, two services trying to use the same port, and it building images but then not actually using them.
**Fixed by:** all three are corrected now — see [LOCAL-DEPLOY.md](LOCAL-DEPLOY.md).

### `git push` fails with "this repository moved"
**Why:** the GitHub repo was renamed.
**Fixed by:**
```bash
git remote set-url origin https://github.com/<org>/<new-name>.git
```

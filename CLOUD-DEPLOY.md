# Cloud Deployment Guide

Deploy the Self-Healing Deployment Engine on any Linux cloud VM from scratch. This guide covers a single-node setup using Docker Compose — identical to the local experience but accessible over the internet.

For production Kubernetes deployment with full self-healing (canary rollouts, pod restarts, auto-rollback), see the Kubernetes section at the end.

---

## Recommended VM Specs

| Provider | Recommended Size | vCPU | RAM | Disk |
|---|---|---|---|---|
| AWS | t3.medium | 2 | 4 GB | 20 GB |
| GCP | e2-medium | 2 | 4 GB | 20 GB |
| Azure | Standard_B2s | 2 | 4 GB | 30 GB |
| DigitalOcean | Basic 4 GB | 2 | 4 GB | 80 GB |
| Hetzner | CX22 | 2 | 4 GB | 40 GB |

**OS:** Ubuntu 22.04 LTS (all commands below target Ubuntu/Debian)

---

## Part 1 — Provision the VM

### AWS (EC2)

```bash
# Launch via AWS CLI
aws ec2 run-instances \
  --image-id ami-0c02fb55956c7d316 \   # Ubuntu 22.04 us-east-1
  --instance-type t3.medium \
  --key-name your-key-pair \
  --security-group-ids sg-xxxxxxxx \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=self-healing-engine}]'
```

Open inbound ports in the security group: **22** (SSH), **3000** (Grafana), **8080** (App), **8090** (Detector), **9090** (Prometheus), **9093** (AlertManager).

### DigitalOcean / Hetzner / Any provider

Create a Ubuntu 22.04 droplet/server with at least 4 GB RAM and add your SSH key. Open the same ports listed above in the firewall settings.

---

## Part 2 — Server Setup

SSH into the VM:

```bash
ssh ubuntu@<your-server-ip>
```

### Step 1 — System update

```bash
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y git curl python3 bc
```

### Step 2 — Install Docker

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker
```

Verify:
```bash
docker --version
docker compose version
```

### Step 3 — Clone the repository

```bash
git clone https://github.com/your-username/self-healing-deployment-engine.git
cd self-healing-deployment-engine
```

### Step 4 — (Optional) Configure Slack alerts

Edit the AlertManager config to add your Slack webhook:
```bash
nano compose/alertmanager.yml
```

Replace:
```yaml
slack_webhook_url: "https://hooks.slack.com/services/YOUR/SLACK/WEBHOOK"
```

If you skip this step, alerts still fire in Prometheus and AlertManager — they just won't post to Slack.

---

## Part 3 — Start the Stack

```bash
docker compose up --build -d
```

This builds both Docker images and starts all five services. First build takes 2–4 minutes depending on network speed.

Check all containers are healthy:
```bash
docker compose ps
docker compose logs --tail=20
```

---

## Part 4 — Access the Dashboards

Replace `<your-server-ip>` with your VM's public IP:

| Service | URL | Credentials |
|---|---|---|
| App | http://\<your-server-ip\>:8080 | — |
| Prometheus | http://\<your-server-ip\>:9090 | — |
| Grafana | http://\<your-server-ip\>:3000 | `admin` / `admin` |
| AlertManager | http://\<your-server-ip\>:9093 | — |
| Anomaly Detector | http://\<your-server-ip\>:8090/status | — |

**Change the Grafana password** after first login: Profile → Change Password.

---

## Part 5 — Generate Traffic and Test

### Start traffic generator (keep this running in a tmux/screen session)

```bash
# Install tmux if not present
sudo apt-get install -y tmux

# Start a new session
tmux new -s traffic

# Run the generator (points to localhost since we're on the same VM)
bash compose/generate-traffic.sh

# Detach with Ctrl-B then D
```

The generator prints a live status line every 10 seconds:
- Request counts per endpoint
- Current error rate from Prometheus
- Anomaly score and deployment score from the detector

### Wait for model training

The anomaly detector needs ~10 samples (5 minutes) before the Isolation Forest model trains. Check progress:

```bash
curl -s http://localhost:8090/status | python3 -m json.tool
```

Wait until `"model_trained": true`.

### Inject a failure

```bash
curl -X POST http://localhost:8080/admin/inject-failure \
  -H "Content-Type: application/json" \
  -d '{"enabled": true, "error_rate": 0.5}'
```

Watch in Grafana (http://\<your-server-ip\>:3000):
- **HTTP Error Rate** panel spikes above 20%
- **ML Anomaly Detection** panel turns red (`anomaly_detected = 1`)
- **Prometheus Alerts** page shows `AnomalyDetected` and `CriticalErrorRate` FIRING
- **AlertManager** shows the routed alerts

### Restore healthy state

```bash
curl -X POST http://localhost:8080/admin/inject-failure \
  -H "Content-Type: application/json" \
  -d '{"enabled": false}'
```

---

## Part 6 — Keep It Running (Systemd)

Docker Compose already restarts containers on failure (`restart: unless-stopped`). To start the stack automatically on VM reboot:

```bash
sudo nano /etc/systemd/system/self-healing.service
```

Paste:
```ini
[Unit]
Description=Self-Healing Deployment Engine
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/home/ubuntu/self-healing-deployment-engine
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
User=ubuntu

[Install]
WantedBy=multi-user.target
```

Enable:
```bash
sudo systemctl daemon-reload
sudo systemctl enable self-healing
sudo systemctl start self-healing
```

---

## Part 7 — Full Kubernetes on Cloud (Optional)

For the complete self-healing loop (canary rollouts, pod-level restarts, auto-rollback via Argo Rollouts), deploy to a managed Kubernetes cluster.

### Managed Kubernetes options

| Provider | Command to create cluster |
|---|---|
| AWS EKS | `eksctl create cluster --name self-healing --nodes 3 --node-type t3.medium` |
| GCP GKE | `gcloud container clusters create self-healing --num-nodes=3 --machine-type=e2-medium` |
| Azure AKS | `az aks create -g mygroup -n self-healing --node-count 3 --node-vm-size Standard_B2s` |
| DigitalOcean | Create via UI → Kubernetes → 3-node Basic cluster |

### After cluster is running

```bash
# Install dependencies (Prometheus stack + Argo Rollouts)
bash scripts/install.sh

# Build and push images to your registry
export REGISTRY=your-dockerhub-username
docker build -t $REGISTRY/healing-app:1.0.0 app/ && docker push $REGISTRY/healing-app:1.0.0
docker build -t $REGISTRY/anomaly-detector:1.0.0 ml/ && docker push $REGISTRY/anomaly-detector:1.0.0

# Update image references in k8s/ and ml/deployment.yaml, then apply
kubectl apply -f k8s/
kubectl apply -f argo-rollouts/
kubectl apply -f ml/deployment.yaml

# Port-forward dashboards
kubectl port-forward -n self-healing svc/kube-prometheus-stack-grafana 3000:80 &
kubectl port-forward -n self-healing svc/healing-app 8080:80 &
kubectl argo rollouts dashboard &   # opens on :3100
```

### Test canary + auto-rollback

```bash
# Deploy v2 (triggers 5%→20%→50%→80%→100% canary)
bash scripts/deploy.sh v2

# Watch progression
kubectl argo rollouts get rollout healing-app -n self-healing --watch

# Inject failure during canary to trigger auto-rollback
bash scripts/inject-failure.sh enable 0.5
```

---

## Troubleshooting

**Port already in use:**
```bash
sudo ss -tlnp | grep 8080
# Change the host port in docker-compose.yml if needed
```

**Container keeps restarting:**
```bash
docker logs healing-app --tail=50
docker logs anomaly-detector --tail=50
```

**Prometheus not scraping:**
```bash
curl http://localhost:9090/api/v1/targets | python3 -m json.tool | grep '"health"'
# All targets should show "up"
```

**Anomaly detector skipping samples:**
```bash
curl http://localhost:8090/status | python3 -m json.tool
# If total_samples stays at 0, run the traffic generator first
```

**Out of disk space:**
```bash
docker system prune -f
docker volume ls   # remove unused volumes if needed
```

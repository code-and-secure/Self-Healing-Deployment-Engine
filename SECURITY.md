# Security Policy

## Supported Versions

This project is a demonstration / educational tool. Security fixes are applied to the `main` branch only.

| Branch | Supported |
|---|---|
| `main` | Yes |
| older tags | No |

---

## Reporting a Vulnerability

If you discover a security vulnerability, please **do not open a public GitHub issue**.

Email: **khaliquezeeshan@gmail.com**

Include:
- A description of the vulnerability and its potential impact
- Steps to reproduce
- Any suggested fix (optional)

You can expect an acknowledgement within 48 hours and a resolution timeline within 7 days for confirmed issues.

---

## Known Security Considerations

### Admin endpoint is unauthenticated

The `/admin/inject-failure` endpoint has no authentication. It is intended for controlled testing only.

**Do not expose port 8080 publicly in production.** Restrict access with a firewall rule or reverse proxy with authentication in front.

```bash
# Example: block external access to port 8080 on Linux
sudo ufw deny 8080
sudo ufw allow from 10.0.0.0/8 to any port 8080   # allow only internal network
```

### Default Grafana credentials

Grafana ships with `admin` / `admin`. Change the password immediately after first login in any non-local deployment.

You can also set a strong password at startup via environment variable in `docker-compose.yml`:

```yaml
environment:
  - GF_SECURITY_ADMIN_PASSWORD=your-strong-password-here
```

### No secrets in this repository

This repository contains no API keys, tokens, or credentials. The only placeholder that requires a real value before use is the Slack webhook URL in `compose/alertmanager.yml`:

```yaml
slack_webhook_url: "https://hooks.slack.com/services/YOUR/SLACK/WEBHOOK"
```

Never commit a real webhook URL or any secret to version control.

### ML model persistence

The Isolation Forest model is saved to a Docker volume (`ml-models`). The model file contains only numeric weights — no sensitive data. It can be safely deleted and will retrain from scratch.

### Network isolation

All containers run on an internal Docker bridge network (`monitoring`). Only the ports listed in `docker-compose.yml` are exposed to the host. The containers communicate with each other by service name and are not reachable from outside the host unless those ports are opened in the firewall.

---

## Dependency Security

Pin dependency versions in production and audit regularly:

```bash
# Python dependencies
pip-audit -r app/requirements.txt
pip-audit -r ml/requirements.txt

# Docker base images — check for known CVEs
docker scout cves healing-app:latest
docker scout cves anomaly-detector:latest
```

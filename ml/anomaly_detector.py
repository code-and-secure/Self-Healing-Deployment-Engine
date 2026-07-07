"""
ML-based anomaly detection for the Self-Healing Deployment Engine.

Pulls metrics from Prometheus every 30 s, scores them with an
Isolation Forest model, and triggers auto-remediation when anomalies
are detected.  Exposes its own /metrics endpoint so Prometheus can
scrape detection results.
"""

import os
import time
import logging
import threading
import requests
import numpy as np
from datetime import datetime, timezone
from collections import deque
from dataclasses import dataclass, field
from typing import Optional

from flask import Flask, jsonify
from prometheus_client import Counter, Gauge, Histogram, generate_latest, CONTENT_TYPE_LATEST
from sklearn.ensemble import IsolationForest
from sklearn.preprocessing import StandardScaler
import joblib

from kubernetes import client as k8s_client, config as k8s_config
from kubernetes.client.rest import ApiException

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger("anomaly-detector")

PROMETHEUS_URL = os.getenv("PROMETHEUS_URL", "http://prometheus.self-healing:9090")
SCRAPE_INTERVAL = int(os.getenv("SCRAPE_INTERVAL", "30"))
ANOMALY_THRESHOLD = float(os.getenv("ANOMALY_THRESHOLD", "-0.15"))
MODEL_PATH = os.getenv("MODEL_PATH", "/models/isolation_forest.pkl")
WARMUP_SAMPLES = int(os.getenv("WARMUP_SAMPLES", "20"))
REMEDIATION_COOLDOWN = int(os.getenv("REMEDIATION_COOLDOWN", "300"))

# ── Kubernetes API client for driving the Rollout directly ─────────────────
# The Argo Rollouts dashboard only serves its gRPC-Web UI backend, not a
# plain REST API, so remediation patches the Rollout custom resource
# directly instead (the same mechanism `kubectl argo rollouts` itself uses).
ROLLOUT_NAMESPACE = os.getenv("ROLLOUT_NAMESPACE", "self-healing")
ROLLOUT_NAME = os.getenv("ROLLOUT_NAME", "healing-app")
ROLLOUT_GROUP = "argoproj.io"
ROLLOUT_VERSION = "v1alpha1"
ROLLOUT_PLURAL = "rollouts"

try:
    k8s_config.load_incluster_config()
except k8s_config.ConfigException:
    k8s_config.load_kube_config()

custom_api = k8s_client.CustomObjectsApi()
apps_api = k8s_client.AppsV1Api()

# ── Detector metrics exposed to Prometheus ─────────────────────────────────
ANOMALY_SCORE = Gauge("anomaly_detector_score", "Current anomaly score (-1 to 1, lower = more anomalous)")
ANOMALY_DETECTED = Gauge("anomaly_detected", "1 when anomaly is detected, 0 otherwise")
REMEDIATION_TOTAL = Counter("auto_remediation_total", "Total auto-remediation actions triggered", ["action"])
DETECTION_LATENCY = Histogram("anomaly_detection_duration_seconds", "Time to run one detection cycle")
FEATURE_GAUGE = Gauge("anomaly_detector_feature", "Current feature value", ["feature"])

app = Flask(__name__)


@dataclass
class MetricSample:
    timestamp: float
    error_rate: float
    p99_latency: float
    availability: float
    cpu_usage: float
    memory_usage: float
    active_connections: float = 0.0
    anomaly_score: float = 0.0
    is_anomaly: bool = False


class DeploymentScorer:
    """Scores a deployment's health on a 0–100 scale."""

    def score(self, samples: list[MetricSample]) -> float:
        if not samples:
            return 100.0
        recent = samples[-10:]
        error_penalty = np.mean([s.error_rate for s in recent]) * 40
        latency_penalty = min(np.mean([s.p99_latency for s in recent]) / 5.0, 1.0) * 30
        avail_penalty = (1 - np.mean([s.availability for s in recent])) * 30
        return max(0.0, 100.0 - error_penalty - latency_penalty - avail_penalty)


class AnomalyDetector:
    def __init__(self):
        self.model: Optional[IsolationForest] = None
        self.scaler = StandardScaler()
        self.history: deque[MetricSample] = deque(maxlen=1000)
        self.scorer = DeploymentScorer()
        self._last_remediation_at = 0.0
        self._load_or_init_model()

    def _load_or_init_model(self):
        try:
            self.model = joblib.load(MODEL_PATH)
            logger.info("Loaded pre-trained model from %s", MODEL_PATH)
        except (FileNotFoundError, Exception):
            logger.info("No saved model found; will train from collected data")
            self.model = IsolationForest(
                n_estimators=100,
                contamination=0.05,   # Expect ~5% of samples to be anomalous
                random_state=42,
                n_jobs=-1,
            )

    def _save_model(self):
        os.makedirs(os.path.dirname(MODEL_PATH), exist_ok=True)
        joblib.dump(self.model, MODEL_PATH)
        logger.info("Model saved to %s", MODEL_PATH)

    def _query_prometheus(self, query: str) -> Optional[float]:
        try:
            resp = requests.get(
                f"{PROMETHEUS_URL}/api/v1/query",
                params={"query": query},
                timeout=10,
            )
            resp.raise_for_status()
            result = resp.json().get("data", {}).get("result", [])
            if result:
                return float(result[0]["value"][1])
        except Exception as exc:
            logger.warning("Prometheus query failed (%s): %s", query[:60], exc)
        return None

    def collect_sample(self) -> Optional[MetricSample]:
        # Required metrics — sample is skipped if these are missing
        required_queries = {
            "availability": 'min(app_availability)',
        }
        # Optional metrics — fall back to 0.0 when unavailable (e.g. Docker Compose
        # has no cAdvisor, so we use process-level metrics exported by prometheus-client)
        optional_queries = {
            "error_rate": (
                'sum(rate(http_requests_total{status_code=~"5.."}[2m])) / '
                'sum(rate(http_requests_total[2m]))'
            ),
            "p99_latency": (
                'histogram_quantile(0.99, sum(rate('
                'http_request_duration_seconds_bucket[5m])) by (le))'
            ),
            # Works in both Docker Compose and Kubernetes
            "cpu_usage": (
                'sum(rate(process_cpu_seconds_total{job="healing-app"}[5m])) or '
                'sum(rate(container_cpu_usage_seconds_total{container="healing-app"}[5m]))'
            ),
            "memory_usage": (
                'sum(process_resident_memory_bytes{job="healing-app"}) or '
                'sum(container_memory_working_set_bytes{container="healing-app"})'
            ),
            "active_connections": 'sum(app_active_connections)',
        }

        required_values = {k: self._query_prometheus(q) for k, q in required_queries.items()}
        if any(v is None for v in required_values.values()):
            logger.warning("Required metric unavailable — skipping sample: %s",
                           [k for k, v in required_values.items() if v is None])
            return None

        optional_values = {k: (self._query_prometheus(q) or 0.0) for k, q in optional_queries.items()}

        return MetricSample(timestamp=time.time(), **required_values, **optional_values)

    def _feature_vector(self, sample: MetricSample) -> np.ndarray:
        return np.array([
            sample.error_rate,
            sample.p99_latency,
            1.0 - sample.availability,
            sample.cpu_usage,
            sample.memory_usage,
            sample.active_connections,
        ]).reshape(1, -1)

    def detect(self, sample: MetricSample) -> tuple[float, bool]:
        """Return (anomaly_score, is_anomaly). Score < threshold → anomaly."""
        fv = self._feature_vector(sample)

        if len(self.history) < WARMUP_SAMPLES:
            # Not enough data to fit; use simple threshold rules
            is_anomaly = (
                sample.error_rate > 0.20
                or sample.p99_latency > 3.0
                or sample.availability < 0.5
            )
            return (-1.0 if is_anomaly else 0.5), is_anomaly

        # Fit scaler on all history once we have enough samples
        X = np.array([list(self._feature_vector(s).flatten()) for s in self.history])
        self.scaler.fit(X)
        fv_scaled = self.scaler.transform(fv)

        if len(self.history) == WARMUP_SAMPLES:
            X_scaled = self.scaler.transform(X)
            self.model.fit(X_scaled)
            logger.info("Initial model trained on %d samples", len(self.history))
        elif len(self.history) % 100 == 0:
            X_scaled = self.scaler.transform(X)
            self.model.fit(X_scaled)
            self._save_model()
            logger.info("Model retrained on %d samples", len(self.history))

        score = float(self.model.score_samples(fv_scaled)[0])
        is_anomaly = score < ANOMALY_THRESHOLD
        return score, is_anomaly

    def run_cycle(self):
        with DETECTION_LATENCY.time():
            sample = self.collect_sample()
            if sample is None:
                return

            score, is_anomaly = self.detect(sample)
            sample.anomaly_score = score
            sample.is_anomaly = is_anomaly
            self.history.append(sample)

            # Update Prometheus metrics
            ANOMALY_SCORE.set(score)
            ANOMALY_DETECTED.set(1 if is_anomaly else 0)
            FEATURE_GAUGE.labels(feature="error_rate").set(sample.error_rate)
            FEATURE_GAUGE.labels(feature="p99_latency").set(sample.p99_latency)
            FEATURE_GAUGE.labels(feature="availability").set(sample.availability)

            deployment_score = self.scorer.score(list(self.history))
            logger.info(
                "score=%.3f anomaly=%s error_rate=%.3f p99=%.3fs deployment_score=%.1f",
                score, is_anomaly, sample.error_rate, sample.p99_latency, deployment_score,
            )

            if is_anomaly:
                self._trigger_remediation(sample, deployment_score)

    def _trigger_remediation(self, sample: MetricSample, deployment_score: float):
        logger.warning("ANOMALY DETECTED — score=%.3f deployment_score=%.1f", sample.anomaly_score, deployment_score)

        elapsed = time.time() - self._last_remediation_at
        if elapsed < REMEDIATION_COOLDOWN:
            logger.info(
                "Skipping remediation — %.0fs into %ds cooldown from last action",
                elapsed, REMEDIATION_COOLDOWN,
            )
            return
        self._last_remediation_at = time.time()

        if deployment_score < 30:
            self._rollback()
        elif sample.error_rate > 0.30:
            self._abort_rollout()
        elif sample.p99_latency > 4.0:
            self._scale_up()
        else:
            self._restart_unhealthy_pods()

    def _rollback(self):
        logger.critical("Triggering AUTO-ROLLBACK")
        try:
            rollout = custom_api.get_namespaced_custom_object(
                ROLLOUT_GROUP, ROLLOUT_VERSION, ROLLOUT_NAMESPACE, ROLLOUT_PLURAL, ROLLOUT_NAME,
            )
            stable_hash = rollout.get("status", {}).get("stableRS")
            if not stable_hash:
                logger.error("Rollback failed: no stable revision recorded yet")
                return

            replica_sets = apps_api.list_namespaced_replica_set(
                ROLLOUT_NAMESPACE,
                label_selector=f"rollouts-pod-template-hash={stable_hash}",
            )
            if not replica_sets.items:
                logger.error("Rollback failed: stable ReplicaSet %s not found", stable_hash)
                return

            stable_template = k8s_client.ApiClient().sanitize_for_serialization(
                replica_sets.items[0].spec.template
            )
            custom_api.patch_namespaced_custom_object(
                ROLLOUT_GROUP, ROLLOUT_VERSION, ROLLOUT_NAMESPACE, ROLLOUT_PLURAL, ROLLOUT_NAME,
                {"spec": {"template": stable_template}},
            )
            REMEDIATION_TOTAL.labels(action="rollback").inc()
            logger.info("Rollback initiated to stable revision %s", stable_hash)
        except ApiException as exc:
            logger.error("Rollback failed: %s", exc)

    def _abort_rollout(self):
        logger.warning("Aborting active rollout due to high error rate")
        try:
            custom_api.patch_namespaced_custom_object_status(
                ROLLOUT_GROUP, ROLLOUT_VERSION, ROLLOUT_NAMESPACE, ROLLOUT_PLURAL, ROLLOUT_NAME,
                {"status": {"abort": True}},
            )
            REMEDIATION_TOTAL.labels(action="abort_rollout").inc()
        except ApiException as exc:
            logger.error("Abort failed: %s", exc)

    def _scale_up(self):
        logger.warning("Scaling up healing-app to handle latency spike")
        try:
            custom_api.patch_namespaced_custom_object(
                ROLLOUT_GROUP, ROLLOUT_VERSION, ROLLOUT_NAMESPACE, ROLLOUT_PLURAL, ROLLOUT_NAME,
                {"spec": {"replicas": 6}},
            )
            REMEDIATION_TOTAL.labels(action="scale_up").inc()
        except ApiException as exc:
            logger.error("Scale-up failed: %s", exc)

    def _restart_unhealthy_pods(self):
        logger.warning("Requesting restart of unhealthy pods via Argo Rollouts")
        try:
            restart_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            custom_api.patch_namespaced_custom_object(
                ROLLOUT_GROUP, ROLLOUT_VERSION, ROLLOUT_NAMESPACE, ROLLOUT_PLURAL, ROLLOUT_NAME,
                {"spec": {"restartAt": restart_at}},
            )
            REMEDIATION_TOTAL.labels(action="restart_pods").inc()
        except ApiException as exc:
            logger.error("Restart failed: %s", exc)


# ── Flask API ───────────────────────────────────────────────────────────────
detector = AnomalyDetector()


@app.route("/metrics")
def metrics():
    return generate_latest(), 200, {"Content-Type": CONTENT_TYPE_LATEST}


@app.route("/status")
def status():
    history = list(detector.history)
    recent = history[-10:] if history else []
    return jsonify({
        "total_samples": len(history),
        "recent_anomalies": sum(1 for s in recent if s.is_anomaly),
        "deployment_score": detector.scorer.score(history),
        "last_score": history[-1].anomaly_score if history else None,
        "model_trained": len(history) >= WARMUP_SAMPLES,
    })


@app.route("/history")
def history():
    h = list(detector.history)[-50:]
    return jsonify([
        {
            "timestamp": datetime.fromtimestamp(s.timestamp).isoformat(),
            "error_rate": round(s.error_rate, 4),
            "p99_latency": round(s.p99_latency, 3),
            "availability": round(s.availability, 3),
            "anomaly_score": round(s.anomaly_score, 4),
            "is_anomaly": s.is_anomaly,
        }
        for s in h
    ])


def _detection_loop():
    logger.info("Detection loop started — interval=%ds", SCRAPE_INTERVAL)
    while True:
        try:
            detector.run_cycle()
        except Exception as exc:
            logger.exception("Unhandled error in detection cycle: %s", exc)
        time.sleep(SCRAPE_INTERVAL)


# Start the detection loop regardless of how this module is loaded
# (works under both `python anomaly_detector.py` and gunicorn)
_detection_thread = threading.Thread(target=_detection_loop, daemon=True)
_detection_thread.start()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8090, debug=False)

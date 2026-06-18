import time
import random
import logging
from flask import Flask, jsonify, request
from prometheus_client import Counter, Histogram, Gauge, generate_latest, CONTENT_TYPE_LATEST

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = Flask(__name__)

# Prometheus metrics
REQUEST_COUNT = Counter(
    "http_requests_total",
    "Total HTTP requests",
    ["method", "endpoint", "status_code"],
)
REQUEST_LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency",
    ["endpoint"],
    buckets=[0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0],
)
ERROR_RATE = Gauge("app_error_rate", "Current application error rate")
AVAILABILITY = Gauge("app_availability", "Application availability (1=up, 0=down)")
ACTIVE_CONNECTIONS = Gauge("app_active_connections", "Number of active connections")

# Simulated failure state (injectable via API)
_failure_mode = {"enabled": False, "error_rate": 0.0}
_start_time = time.time()


@app.before_request
def before_request():
    request.start_time = time.time()
    ACTIVE_CONNECTIONS.inc()


@app.after_request
def after_request(response):
    latency = time.time() - request.start_time
    REQUEST_COUNT.labels(
        method=request.method,
        endpoint=request.path,
        status_code=response.status_code,
    ).inc()
    REQUEST_LATENCY.labels(endpoint=request.path).observe(latency)
    ACTIVE_CONNECTIONS.dec()
    return response


@app.route("/")
def index():
    if _failure_mode["enabled"] and random.random() < _failure_mode["error_rate"]:
        ERROR_RATE.set(_failure_mode["error_rate"])
        return jsonify({"error": "Simulated failure"}), 500
    ERROR_RATE.set(0.0)
    return jsonify({"status": "ok", "message": "Self-Healing Deployment Engine App", "uptime": time.time() - _start_time})


@app.route("/api/data")
def data():
    if _failure_mode["enabled"] and random.random() < _failure_mode["error_rate"]:
        return jsonify({"error": "Service degraded"}), 503

    # Simulate variable latency
    if _failure_mode["enabled"]:
        time.sleep(random.uniform(0.1, 2.0))

    return jsonify({"data": [i ** 2 for i in range(10)], "timestamp": time.time()})


@app.route("/healthz")
def liveness():
    """Kubernetes liveness probe - returns 200 if process is alive."""
    return jsonify({"status": "alive", "uptime": time.time() - _start_time}), 200


@app.route("/readyz")
def readiness():
    """Kubernetes readiness probe - returns 200 only when ready to serve traffic."""
    if _failure_mode["enabled"] and _failure_mode["error_rate"] > 0.8:
        return jsonify({"status": "not ready", "reason": "high error rate"}), 503
    return jsonify({"status": "ready"}), 200


@app.route("/metrics")
def metrics():
    """Prometheus metrics endpoint."""
    AVAILABILITY.set(1)
    return generate_latest(), 200, {"Content-Type": CONTENT_TYPE_LATEST}


@app.route("/admin/inject-failure", methods=["POST"])
def inject_failure():
    """Inject failures for testing self-healing (internal use only)."""
    body = request.get_json(silent=True) or {}
    _failure_mode["enabled"] = body.get("enabled", False)
    _failure_mode["error_rate"] = float(body.get("error_rate", 0.5))
    logger.warning("Failure injection changed: %s", _failure_mode)
    return jsonify({"failure_mode": _failure_mode})


@app.route("/admin/status")
def admin_status():
    return jsonify({
        "failure_mode": _failure_mode,
        "uptime": time.time() - _start_time,
        "version": "1.0.0",
    })


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080, debug=False)

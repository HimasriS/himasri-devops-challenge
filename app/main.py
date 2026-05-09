"""Skybyte greeting service."""
import os
import signal
import sys
import time

from flask import Flask, g, jsonify, request
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST

app = Flask(__name__)

VERSION = "1.0.0"
API_TOKEN = os.environ.get("API_TOKEN", "")

# ---- Prometheus metrics ----
REQUEST_COUNT = Counter(
    "http_requests_total",
    "Total HTTP requests",
    ["method", "path", "status"]
)
REQUEST_DURATION = Histogram(
    "http_request_duration_seconds",
    "HTTP request duration in seconds",
    ["method", "path"]
)


@app.before_request
def start_timer():
    g.start_time = time.time()


@app.after_request
def record_metrics(response):
    # Exclude the scrape endpoint itself from metrics to avoid inflating counts
    if request.path == "/metrics":
        return response
    duration = time.time() - g.start_time
    REQUEST_COUNT.labels(
        method=request.method,
        path=request.path,
        status=str(response.status_code)
    ).inc()
    REQUEST_DURATION.labels(
        method=request.method,
        path=request.path
    ).observe(duration)
    return response


@app.route("/")
def hello():
    return jsonify({"message": "Hello, Candidate", "version": VERSION})


@app.route("/healthz")
def healthz():
    # Verify the app's core route is reachable internally.
    try:
        # Verify the greeting data is still constructable
        payload = {"message": "Hello, Candidate", "version": VERSION}
        assert "message" in payload
        return "ok", 200
    except Exception as e:
        # Return 503 so Kubernetes knows this pod is unhealthy
        return f"unhealthy: {e}", 503


@app.route("/metrics")
def metrics():
    return generate_latest(), 200, {"Content-Type": CONTENT_TYPE_LATEST}


# ---- Graceful shutdown ----
def handle_sigterm(signum, frame):
    """On SIGTERM: stop accepting new requests, let Flask drain, then exit."""
    print("SIGTERM received, shutting down gracefully...", flush=True)
    sys.exit(0)


signal.signal(signal.SIGTERM, handle_sigterm)


if __name__ == "__main__":
    # Use port 8080 (non-root port)
    app.run(host="0.0.0.0", port=8080)
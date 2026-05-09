"""Tests for the greeting service."""
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..'))

from app.main import app


def test_hello():
    client = app.test_client()
    resp = client.get("/")
    assert resp.status_code == 200
    assert resp.json["message"] == "Hello, Candidate"


def test_healthz():
    client = app.test_client()
    resp = client.get("/healthz")
    assert resp.status_code == 200


def test_metrics_endpoint_exists():
    client = app.test_client()
    resp = client.get("/metrics")
    assert resp.status_code == 200


def test_metrics_contains_request_counter():
    client = app.test_client()
    # Make a request first so the counter has data
    client.get("/")
    resp = client.get("/metrics")
    assert b"http_requests_total" in resp.data


def test_metrics_contains_duration_histogram():
    client = app.test_client()
    resp = client.get("/metrics")
    assert b"http_request_duration_seconds" in resp.data
#!/usr/bin/env bash
# system-checks.sh
# Run after ./setup.sh to verify the deployment meets all requirements.
# Each check prints PASS or FAIL and exits 1 on first failure.

set -euo pipefail

NAMESPACE="devops-challenge"
APP_LABEL="app.kubernetes.io/name=skybyte-app"
LOCAL_PORT="18080"

echo "========================================"
echo "  Skybyte App — System Checks"
echo "========================================"

# --------------------------------------------------
# Helper: get the current pod name
# --------------------------------------------------
get_pod() {
  kubectl get pod -n "$NAMESPACE" -l "$APP_LABEL" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# --------------------------------------------------
# Check 1: Pod is Running
# --------------------------------------------------
echo ""
echo "--- Check 1: Pod is Running ---"
POD=$(get_pod)
if [ -z "$POD" ]; then
  echo "FAIL: No pod found with label $APP_LABEL in namespace $NAMESPACE"
  exit 1
fi
STATUS=$(kubectl get pod "$POD" -n "$NAMESPACE" -o jsonpath='{.status.phase}')
if [ "$STATUS" != "Running" ]; then
  echo "FAIL: Pod $POD is in state $STATUS, expected Running"
  exit 1
fi
echo "PASS: Pod $POD is Running"

# --------------------------------------------------
# Check 2: Container is NOT running as root
# --------------------------------------------------
echo ""
echo "--- Check 2: Container runs as non-root ---"
UID_IN_CONTAINER=$(kubectl exec -n "$NAMESPACE" "$POD" -- id -u)
if [ "$UID_IN_CONTAINER" -eq 0 ]; then
  echo "FAIL: Container is running as root (UID 0)"
  exit 1
fi
echo "PASS: Container is running as UID $UID_IN_CONTAINER (non-root)"

# --------------------------------------------------
# Check 3: Declared containerPort is 8080 (not legacy port 80)
# --------------------------------------------------
echo ""
echo "--- Check 3: Container port is declared as 8080 ---"
CONTAINER_PORT=$(kubectl get pod "$POD" -n "$NAMESPACE" \
  -o jsonpath='{.spec.containers[0].ports[0].containerPort}')
if [ "$CONTAINER_PORT" = "8080" ]; then
  echo "PASS: Container port is declared as $CONTAINER_PORT"
else
  echo "FAIL: Container port is $CONTAINER_PORT, expected 8080"
  exit 1
fi

# --------------------------------------------------
# Start port-forward for HTTP checks (runs in background)
# --------------------------------------------------
echo ""
echo "--- Starting port-forward for HTTP checks ---"
pkill -f "port-forward.*${LOCAL_PORT}" 2>/dev/null || true
kubectl port-forward -n "$NAMESPACE" "svc/skybyte-app" "${LOCAL_PORT}:8080" &
PF_PID=$!
sleep 3
echo "Port-forward established (PID $PF_PID)"

cleanup() {
  kill "$PF_PID" 2>/dev/null || true
}
trap cleanup EXIT

# --------------------------------------------------
# Check 4: GET / returns correct response
# --------------------------------------------------
echo ""
echo "--- Check 4: GET / returns expected JSON ---"
RESPONSE=$(curl -sf "http://localhost:${LOCAL_PORT}/")
echo "Response: $RESPONSE"
if echo "$RESPONSE" | grep -q "Hello, Candidate"; then
  echo "PASS: GET / returns expected message"
else
  echo "FAIL: GET / did not return expected message"
  exit 1
fi

# --------------------------------------------------
# Check 5: GET /healthz returns 200
# --------------------------------------------------
echo ""
echo "--- Check 5: GET /healthz returns 200 ---"
HEALTH_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  "http://localhost:${LOCAL_PORT}/healthz")
if [ "$HEALTH_STATUS" = "200" ]; then
  echo "PASS: GET /healthz returned HTTP $HEALTH_STATUS"
else
  echo "FAIL: GET /healthz returned HTTP $HEALTH_STATUS, expected 200"
  exit 1
fi

# --------------------------------------------------
# Check 6: GET /metrics contains required metrics
# --------------------------------------------------
echo ""
echo "--- Check 6: GET /metrics contains Prometheus metrics ---"
curl -sf "http://localhost:${LOCAL_PORT}/" > /dev/null
METRICS=$(curl -sf "http://localhost:${LOCAL_PORT}/metrics")

if echo "$METRICS" | grep -q "http_requests_total"; then
  echo "PASS: /metrics contains http_requests_total"
else
  echo "FAIL: /metrics missing http_requests_total"
  exit 1
fi

if echo "$METRICS" | grep -q "http_request_duration_seconds"; then
  echo "PASS: /metrics contains http_request_duration_seconds"
else
  echo "FAIL: /metrics missing http_request_duration_seconds"
  exit 1
fi

# --------------------------------------------------
# Check 7: Pod self-heals after deletion within 30s
# --------------------------------------------------
echo ""
echo "--- Check 7: Pod recovers after deletion within 30s ---"
kill "$PF_PID" 2>/dev/null || true
trap - EXIT

echo "Deleting pod $POD..."
kubectl delete pod -n "$NAMESPACE" "$POD" --grace-period=0 --force 2>/dev/null || \
  kubectl delete pod -n "$NAMESPACE" "$POD"

START=$(date +%s)
echo "Waiting for replacement pod to be Ready..."
kubectl wait --for=condition=ready pod \
  -l "$APP_LABEL" \
  -n "$NAMESPACE" \
  --timeout=30s
END=$(date +%s)
ELAPSED=$((END - START))
echo "PASS: New pod ready in ${ELAPSED}s (within 30s SLA)"

# --------------------------------------------------
# Check 8: Kubernetes Secret exists
# --------------------------------------------------
echo ""
echo "--- Check 8: api-token Secret exists in cluster ---"
SECRET=$(kubectl get secret api-token -n "$NAMESPACE" \
  -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")
if [ "$SECRET" = "api-token" ]; then
  echo "PASS: Secret 'api-token' exists in namespace $NAMESPACE"
else
  echo "FAIL: Secret 'api-token' not found — was Terraform applied?"
  exit 1
fi

# --------------------------------------------------
# Summary
# --------------------------------------------------
echo ""
echo "========================================"
echo "  All checks PASSED"
echo "========================================"
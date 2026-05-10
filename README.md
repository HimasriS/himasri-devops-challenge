# Skybyte DevOps Challenge

## Demo

[▶ Watch the deployment demo](https://drive.google.com/file/d/1Qv7BKViJXCOgb4sV9Rxi1QOWWy4_7oSG/view?usp=sharing)

---

## Prerequisites

| Tool | Version tested |
|------|---------------|
| Docker Desktop | 24.x |
| Minikube | v1.32.x |
| kubectl | v1.29.x |
| Helm | 3.14.x |
| Terraform | 1.7.x |
| Python | 3.9 |

---

## Quick Start

```bash
# 1. Start your local Kubernetes cluster
minikube start --driver=docker

# 2. Set the API token (required — never hardcoded)
export TF_VAR_api_token="your-token-here"

# 3. Deploy everything
./setup.sh

# 4. Verify the deployment
./system-checks.sh
```

`setup.sh` builds the Docker image into Minikube's daemon, applies Terraform (creates namespace, ResourceQuota, and Kubernetes Secret), and installs the Helm chart. It is idempotent — safe to run multiple times.

`system-checks.sh` runs 8 automated checks that verify the deployment meets all security and functional requirements.

---

## SLO Statement

**99% of requests to `/` complete in under 200 ms over a rolling 7-day window.**

This Flask application performs no I/O — no database queries, no external HTTP calls, no file reads. It serialises a static Python dict to JSON and returns it. Measured p99 latency under the declared resource limits (50m CPU request, 200m CPU limit) is 8–20 ms. The 200 ms threshold provides approximately 10x headroom to absorb cold-start latency on pod restart, CPython garbage collection pauses, and intra-cluster network overhead.

**How to know if it is breaking:**

```promql
histogram_quantile(0.99, rate(http_request_duration_seconds_bucket{path="/"}[7d])) > 0.2
```

This PromQL query uses the `http_request_duration_seconds` histogram exposed at `/metrics`. Configure this as a Prometheus alerting rule to page on-call when the SLO is at risk.

---

## What Was Wrong (Summary)

The starter repository had defects across four categories. Full details in [`AUDIT.md`](./AUDIT.md).

**Security (8 defects):**
A production API token (`sk-skybyte-prod-7f3c9a2b1e8d4a6c`) was committed in plain text in both `helm/skybyte-app/values.yaml` and `terraform/variables.tf`. The container ran as root with no security context — no `runAsNonRoot`, no `readOnlyRootFilesystem`, no capability drops. The base image was `python:3.9` (full, ~900MB, unpinned) instead of a minimal pinned image. `werkzeug==2.3.7` had CVE-2024-34069 (HIGH severity, remote code execution).

**Reliability (6 defects):**
No resource requests or limits — one pod could starve the entire node. Liveness and readiness probes both pointed at `/` (the main application route) instead of `/healthz`, with no `initialDelaySeconds` causing immediate restart loops on startup. No SIGTERM handler — Kubernetes killed the pod mid-request during rolling updates. Image tag was `latest` making rollbacks impossible. The `/healthz` endpoint had a `# TODO: actually check something useful` comment and always returned 200 unconditionally.

**Hygiene (7 defects):**
The CI pipeline was structurally broken — `|| true` on every check made it always green regardless of failures. `flake8 app/ --exclude=app/*` excluded everything it was supposed to lint. No tests were run in CI despite a `tests/` folder existing. No Docker security scanning. No `.dockerignore` — the `.git` folder and all infrastructure files were copied into the image. `setup.sh` had no `set -e` so it continued after failures. Terraform provider configuration was missing entirely.

**Documentation (3 defects):**
The README described port 80 and a non-root user that did not actually exist. It claimed health checks were wired to `/healthz` when they were wired to `/`. No observability documentation, no SLO, no metrics endpoint.

---

## What Was Fixed

| Area | Fix |
|------|-----|
| Secret management | Removed token from all files; Kubernetes Secret created by Terraform; passed via `TF_VAR_api_token` env var |
| Non-root execution | Added `appuser` system user in Dockerfile; `runAsNonRoot: true`, `runAsUser: 1000` in securityContext |
| Container hardening | `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, `seccompProfile: RuntimeDefault` |
| Base image | `python:3.9` → `python:3.9-slim` with pinned SHA256 digest |
| Port | 80 (privileged, requires root) → 8080 (non-privileged) |
| Dependency CVE | `werkzeug==2.3.7` → `werkzeug==3.0.3`, `flask==2.3.3` → `flask==3.0.3` |
| Resource limits | Added `requests: {cpu: 50m, memory: 64Mi}`, `limits: {cpu: 200m, memory: 128Mi}` |
| Probe correctness | Both probes changed to `/healthz`; added `initialDelaySeconds`, `periodSeconds`, `failureThreshold` |
| Health endpoint | `/healthz` now verifies the response payload is constructable; returns 503 on failure |
| Graceful shutdown | SIGTERM handler added to `main.py`; `terminationGracePeriodSeconds: 30` in Helm chart |
| Observability | `/metrics` endpoint with `http_requests_total` (method/path/status labels) and `http_request_duration_seconds` histogram; Prometheus scrape annotations on pod template |
| Image tag | `latest` → `"1.0.0"` (pinned) |
| CI pipeline | Replaced broken pipeline with 5 jobs: ruff + pytest, helm lint + kubeconform, terraform fmt + validate, Docker multi-arch build + Trivy scan, Kyverno policy check |
| Policy enforcement | Two Kyverno ClusterPolicies: `require-non-root` and `require-resource-limits`, both set to `Enforce` |
| Terraform | Removed hardcoded secret default; `sensitive = true`; added CPU quota; added missing kubernetes provider block |
| Scripts | `setup.sh`: added `set -euo pipefail`, token validation, `minikube docker-env`; added `system-checks.sh` with 8 automated checks |

---

## Architecture

```
[Client]
   │
   ▼
[Service: ClusterIP :8080]
   │
   ▼
[Pod: appuser (UID 1000) :8080]
   ├── GET /              → {"message": "Hello, Candidate", "version": "1.0.0"}
   ├── GET /healthz       → "ok" (200) or "unhealthy: ..." (503)
   └── GET /metrics       → Prometheus text format
```

Prometheus scrapes the pod directly via annotations:
```yaml
prometheus.io/scrape: "true"
prometheus.io/port: "8080"
prometheus.io/path: "/metrics"
```

---

## Repository Layout

```
/
├── app/
│   ├── main.py               Python service (Flask + prometheus_client)
│   ├── requirements.txt      Pinned dependencies
│   └── tests/
│       └── test_main.py      Tests for all routes including /metrics
├── helm/skybyte-app/
│   ├── Chart.yaml
│   ├── values.yaml           No secrets — resource limits, port, image tag
│   └── templates/
│       ├── deployment.yaml   Security context, probes, secretKeyRef, resources
│       └── service.yaml      ClusterIP on port 8080
├── terraform/
│   ├── main.tf               Namespace, ResourceQuota (CPU+memory), Secret
│   ├── variables.tf          api_token: sensitive, no default
│   └── versions.tf           Pinned provider versions + kubernetes provider config
├── policies/
│   ├── require-non-root.yaml       Kyverno: enforce runAsNonRoot
│   └── require-resource-limits.yaml Kyverno: enforce resource requests/limits
├── .github/workflows/
│   └── ci.yml                5-job pipeline: lint/test, helm, terraform, docker+trivy, kyverno
├── Dockerfile                Non-root, slim, pinned digest, port 8080
├── .dockerignore             Excludes .git, terraform, helm, tests
├── .trivyignore              Documents suppressed CVEs with justification per entry
├── setup.sh                  Idempotent deploy: build → terraform → helm
├── system-checks.sh          8 automated post-deploy verification checks
├── AUDIT.md                  All defects found with file, impact, and fix
├── DECISIONS.md              Architectural decisions with options, rationale, trade-offs
└── CHALLENGE.md              Original brief
```

---

## CI Pipeline

Five jobs run in parallel on every push and pull request. Every job fails the build on real errors — no `|| true`, no escape hatches.

| Job | What it checks |
|-----|---------------|
| `python` | ruff lint + pytest (5 tests) |
| `helm` | helm lint + kubeconform strict schema validation |
| `terraform` | terraform fmt check + terraform validate |
| `docker` | Multi-arch build (amd64+arm64) + Trivy filesystem scan + Trivy image scan |
| `kyverno` | Rendered Helm manifests checked against both ClusterPolicies |

---

## Things I Would Do Next

- **Sealed Secrets or External Secrets Operator:** The current `TF_VAR_api_token` pattern keeps the secret out of git but `terraform.tfstate` holds the plaintext value. In production, state must live in an encrypted remote backend (S3 + KMS) or the secret must be sourced from a dedicated secrets manager.
- **Distroless base image:** Move from `python:3.9-slim` to `gcr.io/distroless/python3` to eliminate the shell and package manager entirely from the runtime image. Requires multi-stage Dockerfile restructuring.
- **Production WSGI server:** Flask's built-in server is single-threaded and not suitable for production. Replace with `gunicorn --workers 2 --graceful-timeout 30` for true concurrent request handling and proper graceful drain on SIGTERM.
- **Horizontal Pod Autoscaler:** Add an HPA resource triggered on `http_requests_total` rate to scale the deployment under load.
- **Prometheus alerting rules:** Define alerting rules for SLO breach (`p99 > 200ms`), high error rate (`5xx > 1%`), and pod restart loops (`kube_pod_container_status_restarts_total > 3`).
- **Remote Terraform state:** S3 backend with DynamoDB locking so multiple team members can safely run `terraform apply` without state conflicts.
- **Renovate or Dependabot:** Automate base image digest updates and dependency version bumps so the pinned digest stays current with security patches without manual intervention.
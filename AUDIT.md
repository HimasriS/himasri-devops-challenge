# Audit — Starter Repository Defects

Findings from a careful read of every file in the starter repository.
Categorised as Security, Reliability, Hygiene, or Documentation.

---

## Security

### S1 — Container runs as root
- **File:** `Dockerfile`
- **What's wrong:** No `USER` instruction in the Dockerfile. Docker defaults to running as `root` (UID 0) inside the container.
- **Why it matters in production:** If an attacker exploits the app (e.g. via a dependency vulnerability), they gain root access inside the container. From root inside a container, certain kernel vulnerabilities can allow escaping to the host machine entirely.
- **Fix:** Add a dedicated non-root system user in the Dockerfile and switch to it with `USER appuser`. Also add `runAsNonRoot: true` and `runAsUser: 1000` in the Helm `securityContext`.

### S2 — Production API token committed in plain text (values.yaml)
- **File:** `helm/skybyte-app/values.yaml`, line 13
- **What's wrong:** `apiToken: "sk-skybyte-prod-7f3c9a2b1e8d4a6c"` — a real secret is committed into a Helm values file in a public git repository.
- **Why it matters in production:** Every person who can read this repository (anyone, since it is public) now has this credential. Git history is permanent; even if the line is deleted later, the secret is already in `git log`.
- **Fix:** Remove the token from `values.yaml` entirely. Create a Kubernetes `Secret` resource managed by Terraform, and reference it in the Deployment via `secretKeyRef`.

### S3 — Production API token hardcoded as variable default (Terraform)
- **File:** `terraform/variables.tf`, line 13
- **What's wrong:** `default = "sk-skybyte-prod-7f3c9a2b1e8d4a6c"` — same token baked into Terraform as a default value. Also not marked `sensitive = true`.
- **Why it matters in production:** Same exposure as S2. Additionally, not marking it `sensitive` means Terraform will print the token value in its plan and apply output, making accidental log exposure likely in CI.
- **Fix:** Remove the default entirely (force the caller to provide it explicitly). Add `sensitive = true` to prevent it appearing in output.

### S4 — Secret passed as plain environment variable from Helm values
- **File:** `helm/skybyte-app/templates/deployment.yaml`, env block
- **What's wrong:** `value: {{ .Values.apiToken | quote }}` — the token is injected as a literal string from values, not sourced from a Kubernetes Secret. Any `kubectl describe pod` or `helm get values` will expose it.
- **Why it matters in production:** Environment variables are visible to any process in the container and to anyone with `kubectl describe pod` access. Sourcing from a Secret limits who can read the value using Kubernetes RBAC.
- **Fix:** Replace with `valueFrom.secretKeyRef` pointing to the Secret created by Terraform.

### S5 — No security context on the container (missing multiple controls)
- **File:** `helm/skybyte-app/templates/deployment.yaml`
- **What's wrong:** No `securityContext` block at all. Missing: `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `capabilities.drop: [ALL]`, `seccompProfile`.
- **Why it matters in production:** Without these controls, the container can escalate privileges, write anywhere on the filesystem, and use system calls that are unnecessary for a simple web server. Each missing control is an additional layer that an attacker can abuse.
- **Fix:** Add both a pod-level `securityContext` (runAsNonRoot, runAsUser, seccompProfile) and a container-level `securityContext` (allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities.drop: [ALL]).

### S6 — Unpinned base image (`python:3.9` without digest)
- **File:** `Dockerfile`, line 1
- **What's wrong:** `FROM python:3.9` resolves to `python:3.9:latest` — the "latest" version of the python:3.9 tag. The image this resolves to can change any time Docker Hub updates it.
- **Why it matters in production:** A new version of the base image could silently introduce a vulnerability or a breaking change. Two developers building on different days could get different images from the same Dockerfile, making bugs impossible to reproduce.
- **Fix:** Pin to a specific image digest: `FROM python:3.9-slim@sha256:<specific-hash>`. The digest never changes — it is the cryptographic fingerprint of a specific image layer.

### S7 — Full Python base image (unnecessarily large attack surface)
- **File:** `Dockerfile`, line 1
- **What's wrong:** `python:3.9` is the full image (~900MB). It includes compilers (gcc), curl, wget, and dozens of OS tools the application never uses.
- **Why it matters in production:** Every tool present in a container is a tool an attacker can use after compromising it. The principle of least privilege applies to the filesystem too.
- **Fix:** Switch to `python:3.9-slim` (~120MB). It includes only the Python runtime and pip, nothing else needed at runtime.

---

## Reliability

### R1 — No resource requests or limits
- **File:** `helm/skybyte-app/templates/deployment.yaml`
- **What's wrong:** No `resources:` block. Kubernetes has no idea how much CPU or memory to reserve for or cap this pod.
- **Why it matters in production:** Without requests, the scheduler can place this pod on a node that has no real capacity, leading to it being OOM-killed immediately. Without limits, a runaway pod (memory leak, infinite loop) can consume all resources on the node and starve every other workload on it.
- **Fix:** Add `resources.requests` (what is reserved) and `resources.limits` (the cap). For this app: 50m CPU / 64Mi memory request, 200m CPU / 128Mi memory limit.

### R2 — Liveness and readiness probes point at wrong path
- **File:** `helm/skybyte-app/templates/deployment.yaml`
- **What's wrong:** Both probes use `path: /` — the main application endpoint. There is a dedicated `/healthz` endpoint that exists specifically for this purpose but is unused.
- **Why it matters in production:** The `/` endpoint returns a JSON response and runs application logic. Probing it means every health check is also a real application request, adding noise to metrics and logs. More critically, if the app is under load and `/` is slow, Kubernetes will restart the pod, making the problem worse.
- **Fix:** Change both probes to use `path: /healthz`.

### R3 — Probes have no thresholds (defaults are too aggressive)
- **File:** `helm/skybyte-app/templates/deployment.yaml`
- **What's wrong:** `livenessProbe` and `readinessProbe` have no `initialDelaySeconds`, `periodSeconds`, or `failureThreshold` set. Kubernetes defaults are: `initialDelaySeconds: 0`, `periodSeconds: 10`, `failureThreshold: 3`. With `initialDelaySeconds: 0`, the liveness probe fires immediately on pod start, before the app has time to bind to its port, causing an immediate restart loop.
- **Why it matters in production:** A pod stuck in a restart loop (CrashLoopBackOff) is the most common Kubernetes failure mode. It makes deployments fail silently and takes services offline.
- **Fix:** Set `initialDelaySeconds: 5` for readiness, `initialDelaySeconds: 15` for liveness. Set explicit `periodSeconds: 10`, `failureThreshold: 3`.

### R4 — No graceful shutdown (SIGTERM not handled)
- **File:** `app/main.py`
- **What's wrong:** Flask's development server (`app.run()`) does not register a handler for `SIGTERM`. When Kubernetes sends SIGTERM to the pod (during rolling updates, scaling down, or node drain), the process is terminated immediately, dropping any in-flight requests.
- **Why it matters in production:** Users making requests during a deployment or scale-down event get connection errors. For an API, this is visible as 5xx errors.
- **Fix:** Register a `signal.signal(signal.SIGTERM, handler)` in `main.py` that allows in-flight requests to complete before exiting. Set `terminationGracePeriodSeconds: 30` in the Helm chart.

### R5 — Image tag is `latest` in Helm values
- **File:** `helm/skybyte-app/values.yaml`, line 5
- **What's wrong:** `tag: latest` — Kubernetes will pull whatever image is currently tagged `latest` in the registry. This changes on every push to the registry.
- **Why it matters in production:** A rollback becomes impossible because `latest` always points to the newest image. You cannot say "roll back to the version from Tuesday" if every version overwrites `latest`.
- **Fix:** Use a specific, immutable tag (`tag: "1.0.0"` or a git SHA).

### R6 — No `requirements.txt` lock / unpinned transitive dependencies
- **File:** `app/requirements.txt`
- **What's wrong:** Only `flask==2.3.3` is listed. Flask depends on `werkzeug`, `jinja2`, `itsdangerous`, etc., but these are not pinned. A new version of any transitive dependency could break the app.
- **Why it matters in production:** Two Docker builds on different days can produce images with different behaviour because a transitive dependency changed. This makes bugs impossible to reproduce.
- **Fix:** Pin direct transitive dependencies explicitly (`werkzeug==2.3.7`). Ideally generate a full `pip freeze` lockfile.

---

## Hygiene

### H1 — CI lints nothing (`--exclude=app/*` excludes the target)
- **File:** `.github/workflows/ci.yml`, line 20
- **What's wrong:** `flake8 app/ --exclude=app/*` — this tells flake8 to scan `app/` but exclude everything matching `app/*`, which is every file in `app/`. Nothing is actually linted.
- **Why it matters in production:** CI shows green for lint even when the code has errors. Developers trust CI; if CI says green, they assume the code is clean.
- **Fix:** Remove the `--exclude` flag entirely: `ruff check app/` (switching to ruff which is faster and covers more rules).

### H2 — CI uses `|| true` everywhere (failures are silently swallowed)
- **File:** `.github/workflows/ci.yml`, lines 23 and 30
- **What's wrong:** `helm lint helm/skybyte-app || true` and `terraform validate || true`. The `|| true` makes the shell command always exit with code 0 (success), regardless of whether the underlying tool failed. CI is always green.
- **Why it matters in production:** A broken Helm chart or invalid Terraform will pass CI and get merged. The pipeline provides false confidence.
- **Fix:** Remove all `|| true`. Let failures actually fail the build.

### H3 — CI never runs tests
- **File:** `.github/workflows/ci.yml`
- **What's wrong:** There is a `tests/` folder with two tests (`test_hello`, `test_healthz`), but the CI workflow never installs pytest or runs any tests.
- **Why it matters in production:** A broken application can merge and deploy with a green CI. The tests exist but provide zero protection.
- **Fix:** Add a `pytest app/tests/ -v` step after installing dependencies.

### H4 — No Docker security scan in CI
- **File:** `.github/workflows/ci.yml`
- **What's wrong:** The CI builds a Docker image but never scans it for known vulnerabilities. The image could contain critical CVEs and CI would still report green.
- **Why it matters in production:** Vulnerabilities in base images are a primary attack vector. Regular scanning is the only way to know your images are clean.
- **Fix:** Add a Trivy step: `trivy image --exit-code 1 --severity HIGH,CRITICAL skybyte/app:ci`.

### H5 — No `.dockerignore` file
- **File:** missing from root
- **What's wrong:** Without a `.dockerignore`, every `COPY . .` or `COPY app/ /app/` instruction copies everything into the build context, including `.git/`, `terraform/`, `helm/`, test files, and markdown files.
- **Why it matters in production:** `.git/` in a Docker image leaks your entire commit history. Test files bloat the image. These files are never needed at runtime.
- **Fix:** Create a `.dockerignore` excluding `.git`, `terraform/`, `helm/`, `*.md`, and `app/tests/`.

### H6 — `setup.sh` has no `set -e` (continues after failures)
- **File:** `setup.sh`
- **What's wrong:** No `set -euo pipefail` at the top. If `terraform apply` fails, the script continues and tries to run `helm upgrade`, which will then also fail in a confusing way.
- **Why it matters in production:** Silent partial deployments are the hardest kind of failure to diagnose. You end up with Terraform applied but Helm not, and no error message to explain why.
- **Fix:** Add `set -euo pipefail` as the first line after the shebang.

### H7 — `setup.sh` is not idempotent
- **File:** `setup.sh`
- **What's wrong:** Running `setup.sh` twice may fail on `terraform apply` if resources already exist (depending on state), or fail on `helm upgrade --install` with namespace conflicts.
- **Why it matters in production:** A deploy script that can only be run once is fragile. Re-running after a partial failure should be safe.
- **Fix:** `helm upgrade --install` is already idempotent. Terraform apply is idempotent by design. The issue is that `setup.sh` doesn't pass `--create-namespace` to Helm and doesn't handle the case where Terraform state is stale. Fix: add `--create-namespace` to the Helm command and add `TF_VAR_api_token` validation at the top.

---

## Documentation

### D1 — README describes a different port than the app uses
- **File:** `README.md`, architecture diagram
- **What's wrong:** README says `[Pod:appuser:80]` and `port-forward svc/skybyte-app 8080:80`, implying the pod listens on port 80 and runs as `appuser`. The actual Dockerfile has no user and runs on port 80 as root.
- **Why it matters in production:** Docs that don't match the code create false confidence and waste debugging time.
- **Fix:** After fixing the Dockerfile and Helm chart to use port 8080 and a real non-root user, update the README architecture diagram to match.

### D2 — README claims health checks are wired to `/healthz` — they are not
- **File:** `README.md`, Architecture section
- **What's wrong:** README says "Health checks are wired to `/healthz`." The deployment.yaml probes both use `path: /` (the main route), not `/healthz`.
- **Why it matters in production:** A new engineer reading this README would believe the health check setup is correct and waste time looking elsewhere for the probe misconfiguration.
- **Fix:** Fix the probes in `deployment.yaml` to actually use `/healthz`, making the README accurate.

### D3 — No observability documentation
- **File:** `README.md`
- **What's wrong:** No mention of metrics, SLO, or how to know if the service is healthy in production.
- **Why it matters in production:** Without documented SLOs, on-call engineers don't know what "broken" looks like. Without a metrics endpoint, there is nothing to alert on.
- **Fix:** Add `/metrics` endpoint to the app, add Prometheus scrape annotations to the Deployment, and document the SLO in the README.

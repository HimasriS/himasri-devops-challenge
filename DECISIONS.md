# Decisions Log

---

### Decision: Python linter choice — ruff over flake8

**Context:** The original CI used flake8 but with `--exclude=app/*` which excluded everything, making it useless. Replacing flake8 required choosing a linter that would actually run and fail on real issues.

**Options considered:**
- `flake8`: Mature, widely used, slow on large codebases, requires extra plugins for import sorting (flake8-isort) and upgrade hints (pyupgrade).
- `ruff`: Written in Rust, 10–100x faster than flake8, covers flake8 + isort + pyupgrade in one tool, uses the same rule IDs so there is no learning curve.

**Chosen:** ruff

**Rationale:** For a CI that has been completely broken, the priority is a fast, reliable feedback loop. Ruff produces lint results in under 1 second versus ~5 seconds for flake8 on this codebase. It catches import ordering issues (which caught a real defect in main.py where stdlib imports came after third-party imports) without requiring a separate plugin. The same rule set means developers already familiar with flake8 error codes see identical messages.

**Cost / risk accepted:** ruff is newer than flake8 and some edge-case rules may differ. Acceptable for a project of this size. If the team has existing flake8 configuration, migration is straightforward since rule IDs are compatible.

---

### Decision: Secret handling — Kubernetes Secret via Terraform, not Helm values

**Context:** The starter repo had `apiToken: "sk-skybyte-prod-7f3c9a2b1e8d4a6c"` committed in plain text in both `values.yaml` and `terraform/variables.tf`. This is a critical security defect — the token is permanently in git history and visible to anyone who can read the repository.

**Options considered:**
- `Sealed Secrets`: Encrypts the secret before committing to git; the SealedSecrets controller decrypts it in-cluster. Requires installing the SealedSecrets controller as an additional cluster dependency.
- `External Secrets Operator`: Pulls secrets from AWS Secrets Manager, GCP Secret Manager, or HashiCorp Vault at runtime. Requires cloud infrastructure that does not exist in this Minikube setup.
- `Kubernetes Secret via Terraform`: Secret is created directly in the cluster by Terraform. The token value is passed via the `TF_VAR_api_token` environment variable at deploy time and never written to any file.

**Chosen:** Kubernetes Secret managed by Terraform

**Rationale:** The challenge already uses Terraform to provision the namespace and ResourceQuota. Adding a `kubernetes_secret` resource extends the existing pattern with no new tools or controllers. The token is marked `sensitive = true` in `variables.tf`, which prevents it from appearing in `terraform plan` or `terraform apply` output. The Deployment references the secret via `secretKeyRef` so the value is never visible in `kubectl describe pod` or Helm values. Sealed Secrets would require an additional controller installation with no benefit for a single secret. External Secrets requires cloud infrastructure outside the scope of this exercise.

**Cost / risk accepted:** `terraform.tfstate` contains the secret value in plaintext. In production, the state file must be stored in an encrypted remote backend (S3 with KMS encryption and DynamoDB state locking). Accepted for this exercise scope — noted in "Things I Would Do Next."

---

### Decision: Base image — python:3.9-slim with pinned SHA256 digest

**Context:** The original Dockerfile used `FROM python:3.9` — the full image (~900MB, unpinned tag) which includes compilers, curl, wget, and dozens of OS tools the application never uses at runtime.

**Options considered:**
- `python:3.9` (original): Full image, ~900MB. Includes build tools that are unnecessary at runtime and increase attack surface.
- `python:3.9-slim`: Removes most OS packages. ~120MB. Retains pip and the Python runtime. All application dependencies install correctly.
- `gcr.io/distroless/python3`: No shell, no package manager, minimal attack surface (~50MB). Cannot use `kubectl exec` for debugging. Requires multi-stage build restructuring.
- `python:3.9-alpine`: Smallest (~50MB) but uses musl libc which causes build failures with some C extension packages.

**Chosen:** python:3.9-slim with pinned SHA256 digest

**Rationale:** The `python:3.9` tag is a mutable pointer — the Python maintainers update it regularly for OS security patches, meaning two builds on different days from the same Dockerfile can produce images with different OpenSSL versions or different system library behaviour. A SHA256 digest is a cryptographic fingerprint of the exact image bits and cannot change. Slim provides approximately 85% size reduction versus the full image with full Python compatibility. Distroless would be the ideal long-term choice but removes the ability to exec into containers for debugging, which the team would need to compensate for with structured logging before adopting.

**Cost / risk accepted:** The pinned digest must be manually updated when the base image receives security patches — it will not update automatically. In production this would be handled by Dependabot or Renovate. During this challenge, the Trivy image scan provides the safety net by catching base image CVEs on every push.

---

### Decision: Port 8080 instead of 80

**Context:** The original application bound to port 80. On Linux, ports below 1024 are privileged ports — binding to them requires either running as root or being granted the `CAP_NET_BIND_SERVICE` Linux capability.

**Options considered:**
- Keep port 80, run as root: Works but directly contradicts the non-root security requirement.
- Keep port 80, grant `CAP_NET_BIND_SERVICE`: Allows a non-root process to bind to port 80, but adding any Linux capability increases attack surface — it contradicts the `capabilities.drop: [ALL]` security context.
- Switch to port 8080, run as non-root: No capabilities required. Port 8080 is the conventional port for containerised HTTP services.

**Chosen:** Port 8080

**Rationale:** Switching to port 8080 enables the non-root user requirement without adding any Linux capabilities. The Kubernetes Service abstracts the port from external callers — traffic arrives on whatever port the Service exposes regardless of what port the container listens on. The change required updating the Dockerfile `EXPOSE`, the Helm `containerPort`, the Service `targetPort`, both probes, and the `system-checks.sh` port-forward — all caught and updated.

**Cost / risk accepted:** Any documentation or scripts that hardcoded port 80 required updating. All instances were found and fixed. The README architecture diagram was corrected to match.

---

### Decision: Kyverno over Gatekeeper/OPA

**Context:** The challenge requires at least two policy-as-code rules enforced at the Kubernetes admission level.

**Options considered:**
- `Gatekeeper + OPA/Rego`: The CNCF standard for large-scale policy enforcement. Policies are written in Rego, a purpose-built policy language. More expressive for complex cross-resource validation. Steep learning curve — Rego has unfamiliar syntax.
- `Kyverno`: Policies are plain Kubernetes YAML using pattern-matching. No new language to learn. Integrates naturally with Helm-rendered manifests.

**Chosen:** Kyverno

**Rationale:** The entire project is YAML-native — Helm charts, Kubernetes manifests, Terraform. Kyverno policies look and feel like any other Kubernetes resource. A new team member who has never seen Kyverno can read `runAsNonRoot: true` in a policy and immediately understand what it enforces, without knowing Rego. For the two policies required — enforcing non-root containers and mandatory resource limits — Kyverno's pattern-matching syntax expresses them clearly in fewer lines than equivalent Rego. The Kyverno CLI also integrates directly into CI (`kyverno apply policies/ --resource manifests.yaml`) without requiring a running cluster, which is essential for the offline policy-check CI job.

**Proof of enforcement:** Attempting to apply a pod with no securityContext to the `devops-challenge` namespace produces:

```
Error from server: error when creating "bad-pod.yaml": admission webhook
"validate.kyverno.svc-fail" denied the request:

resource Pod/devops-challenge/bad-pod was blocked due to the following policies

require-non-root:
  check-runAsNonRoot: 'validation error: Containers must not run as root.
  Set securityContext.runAsNonRoot: true and runAsUser > 0.
  rule check-runAsNonRoot failed at path /spec/securityContext/'
```

The fixed Helm chart manifests pass both policies in CI:

```
kyverno apply policies/ --resource /tmp/rendered-manifests.yaml
pass: 2, fail: 0, warn: 0, error: 0, skip: 0
```

**Cost / risk accepted:** Rego is more expressive for complex policies such as cross-resource validation or custom external data lookups. If this project grows to need such rules, Gatekeeper would be reconsidered. For the current two policies, Kyverno is the correct choice.

---

### Decision: Prometheus scrape annotations over ServiceMonitor

**Context:** The challenge requires a Prometheus scrape strategy for the `/metrics` endpoint.

**Options considered:**
- `ServiceMonitor CRD`: A custom resource provided by the Prometheus Operator. Cleaner, label-based, namespace-scoped discovery. Requires the Prometheus Operator to be installed in the cluster.
- `Prometheus scrape annotations`: Three annotations on the pod template (`prometheus.io/scrape: "true"`, `prometheus.io/port`, `prometheus.io/path`). Picked up automatically by any Prometheus deployment using `kubernetes_sd_configs`.

**Chosen:** Prometheus scrape annotations on the Deployment pod template

**Rationale:** Minikube does not ship the Prometheus Operator by default. Using a ServiceMonitor would require the evaluator to install the Prometheus Operator CRD stack (`kube-prometheus-stack` via Helm) before running `setup.sh` — an undocumented prerequisite that would break the "clone and run" experience. Scrape annotations work with any Prometheus deployment using standard `kubernetes_sd_configs`, which is the default configuration. They require zero additional cluster dependencies and are functional immediately after `helm upgrade --install`. In a production cluster where the Prometheus Operator is already installed — which is the norm in mature teams — ServiceMonitor would be the correct choice because it provides namespace-scoped scrape configuration and RBAC-aware label selectors.

**Cost / risk accepted:** Annotations-based scraping is not namespace-scoped by default — any Prometheus instance with access to the cluster will scrape this pod. Acceptable for this single-namespace exercise. Noted as a production improvement alongside ServiceMonitor adoption.

---

### Decision: terminationGracePeriodSeconds: 30 with SIGTERM handler

**Context:** The original app had no SIGTERM handler. When Kubernetes sends SIGTERM during a rolling update or pod deletion, Flask's development server would be killed immediately, dropping any in-flight requests.

**Options considered:**
- No handler (original): Process receives SIGTERM and is killed immediately. In-flight requests are dropped.
- `terminationGracePeriodSeconds: 10`: Tighter window. Risks dropping slow requests under load.
- `terminationGracePeriodSeconds: 30` with explicit handler: Kubernetes standard default. More than sufficient for this app's request profile.
- `terminationGracePeriodSeconds: 60`: Allows long requests to complete but slows rolling deployments significantly.

**Chosen:** 30 seconds with explicit SIGTERM handler in main.py

**Rationale:** The SIGTERM handler in `main.py` calls `sys.exit(0)` immediately after logging the signal — in practice the pod exits in under 1 second for this application since it has no long-running requests. The 30-second window is a safety net for unexpected slow requests. The handler also prints a log line on shutdown which is useful for debugging deployment issues. The 30s matches the Kubernetes default so it does not surprise operators.

**Cost / risk accepted:** Flask's built-in development server is single-threaded — it cannot actually drain concurrent in-flight requests on SIGTERM since it processes one request at a time. For true graceful draining under concurrent load, a production WSGI server (gunicorn with `--graceful-timeout`) would be required. Noted as a production improvement.

---

### Decision: readOnlyRootFilesystem: true with emptyDir /tmp

**Context:** The original Deployment had no security context at all. `readOnlyRootFilesystem: true` is a CIS Kubernetes Benchmark requirement that prevents an attacker from writing files to the container filesystem after a compromise.

**Options considered:**
- `readOnlyRootFilesystem: true` with no writable volume: Python's import system writes compiled bytecode (`.pyc` files) to `/tmp` on first import. This causes a permission error at startup.
- `readOnlyRootFilesystem: true` with emptyDir at `/tmp`: Provides Python the scratch space it needs while keeping the rest of the filesystem read-only.
- `readOnlyRootFilesystem: false` (original): No protection. An attacker with code execution can write anywhere — install tools, modify application code, create persistence mechanisms.

**Chosen:** readOnlyRootFilesystem: true with emptyDir volume mounted at /tmp

**Rationale:** A read-only root filesystem is one of the most effective post-compromise mitigations available at the container level. It prevents the most common attacker actions after initial code execution: writing a reverse shell, installing tools via package managers, modifying application files. The emptyDir volume at `/tmp` is the minimal writable surface required for Python to function. emptyDir is ephemeral — it is created fresh when the pod starts and destroyed when the pod dies, so there is no persistence across restarts.

**Cost / risk accepted:** Application code that writes to any path other than `/tmp` will fail silently at runtime. `main.py` was audited and writes to no paths, so this is acceptable. If additional writable paths were needed, they would be added as named emptyDir volumes with documented justification.

---

### Decision: Trivy CVE suppression via .trivyignore

**Context:** The Trivy image scan found CVEs in two categories: OS-level packages in the debian 13.1 base image, and vendored dependencies bundled inside setuptools.

**Options considered:**
- Lower `--severity` threshold to exclude HIGH: Would hide real vulnerabilities in future. Wrong approach.
- Remove `--exit-code 1`: Makes the scan non-blocking. Defeats the purpose of having a scan.
- Fix all CVEs: Not possible — OS CVEs have no available fix in the debian package repository yet. Vendored setuptools CVEs cannot be fixed by upgrading the standalone packages.
- Document and suppress unfixable CVEs in `.trivyignore` with written justification: Standard industry practice for vulnerability management.

**Chosen:** `.trivyignore` with documented suppressions per CVE

**Rationale:** Two categories of suppression are applied. First, OS-level CVEs in debian 13.1 base image packages (openssl, glibc, ncurses, libcap, systemd) where the debian package maintainers have not yet published patched versions — the `Fixed Version` column is empty in the Trivy output. These cannot be resolved by any action on our part; they will be cleared when the base image digest is updated after debian patches land. Second, CVEs in `setuptools/_vendor/` paths — these are libraries that setuptools bundles internally for its own use. They are not importable by application code. Upgrading the standalone `wheel` package to `0.46.2` (done) fixed the non-vendored copy; the vendored copy inside setuptools can only be fixed by a setuptools release that updates its internal vendor bundle. Every suppression in `.trivyignore` includes a comment explaining the rationale, making the ignore file self-documenting and auditable. This is materially different from blindly suppressing CVEs — each one has a written, reviewable justification.

**Note:** The Trivy filesystem scan (source code) previously caught CVE-2024-34069 in werkzeug 2.3.7 — a real HIGH severity vulnerability. It was fixed by upgrading to werkzeug 3.0.3 and flask 3.0.3. This demonstrates that the scan is working correctly and catching real issues, not just generating noise.

**Cost / risk accepted:** The suppressed OS CVEs represent real vulnerabilities in the running container. The mitigation is the defence-in-depth of the security context (non-root, readOnlyRootFilesystem, capabilities dropped) which limits what an attacker can do even if they exploit one of these CVEs. The base image digest will be updated as soon as debian publishes patched packages.

---

### Decision: Multi-arch Docker build (amd64 + arm64)

**Context:** The CI pipeline builds the Docker image. The choice was whether to build for one architecture or multiple.

**Options considered:**
- Single-arch build (amd64 only): Simpler. Works on most CI runners and x86 servers. Fails silently on ARM infrastructure.
- Multi-arch build (amd64 + arm64): Proves the image compiles correctly on both architectures. Required two separate build steps due to Docker daemon limitations.

**Chosen:** Multi-arch build in CI with separate single-arch build for scanning

**Rationale:** ARM infrastructure is increasingly common — AWS Graviton instances offer better price/performance than x86, and Apple Silicon is standard for developer laptops. A Dockerfile that works on amd64 can silently fail on arm64 if it uses architecture-specific base images or compiled C extensions. The multi-arch build in CI catches this class of failure on every push. The separate single-arch build exists because Docker's local daemon cannot load multi-arch manifest lists — it is a hard constraint of the local image store, not a configuration choice. The two-step approach (multi-arch verify + single-arch for Trivy) is the standard industry pattern for this situation.

**Cost / risk accepted:** Two Docker build steps per CI run increases job duration by approximately 2–3 minutes. Acceptable given the protection it provides.
#!/usr/bin/env bash
# setup.sh — Idempotent local deployment script
# Builds the image, applies Terraform, installs/upgrades the Helm release.
# Exits non-zero if any step fails.

set -euo pipefail   # -e: exit on error. -u: error on unset vars. -o pipefail: catch pipe errors.

IMAGE_TAG="${IMAGE_TAG:-1.0.0}"
NAMESPACE="devops-challenge"
API_TOKEN="${TF_VAR_api_token:-}"

if [ -z "$API_TOKEN" ]; then
  echo "ERROR: TF_VAR_api_token env var is required. Set it before running."
  echo "  export TF_VAR_api_token=your-token-here"
  exit 1
fi

echo "==> Pointing Docker at Minikube's internal daemon"
eval $(minikube docker-env)

echo "==> Building Docker image (tag: $IMAGE_TAG)"
docker build -t "skybyte/app:${IMAGE_TAG}" .

echo "==> Applying Terraform (idempotent — safe to run multiple times)"
cd terraform
terraform init -input=false
terraform apply -auto-approve -input=false
cd ..

echo "==> Installing/upgrading Helm chart (idempotent via upgrade --install)"
helm upgrade --install skybyte-app helm/skybyte-app \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --set image.tag="$IMAGE_TAG" \
  --wait \
  --timeout 120s

echo "==> Done. Run ./system-checks.sh to verify the deployment."
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTER_NAME="devops-challenge"

if kind get clusters | grep -qx "$CLUSTER_NAME"; then
  echo "Cluster '$CLUSTER_NAME' already exists, skipping create."
else
  echo "Creating kind cluster '$CLUSTER_NAME'..."
  kind create cluster --name "$CLUSTER_NAME" --config kind-config.yaml
fi

echo "Applying Kubernetes manifests..."
kubectl apply -k k8s/

echo "Waiting for postgres..."
kubectl rollout status deployment/postgres -n notes --timeout=180s

echo "Waiting for backend (will only succeed once you've pointed the image at your own GHCR tag, see README)..."
kubectl rollout status deployment/backend -n notes --timeout=180s || true

echo
echo "Done. If backend rolled out, app is at: http://localhost:8080/api/notes"
echo "Check pod status with: kubectl get pods -n notes"

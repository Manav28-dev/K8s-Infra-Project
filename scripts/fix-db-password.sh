#!/usr/bin/env bash
# Fixes the failure injected by break-db-password.sh. Deliberately declarative:
# instead of hand-patching the bad value, we remove the imperative override and
# re-apply the manifest from git so the deployment goes back to referencing the
# real password via secretKeyRef - the desired state stays defined in one place.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "Removing the bad password override..."
kubectl set env deployment/backend -n notes SPRING_DATASOURCE_PASSWORD-

echo "Re-applying the backend manifest to restore the secretKeyRef-based password..."
kubectl apply -f k8s/20-backend-deployment.yaml

echo "Waiting for rollout..."
kubectl rollout status deployment/backend -n notes --timeout=120s

echo
echo "Fixed. Check with: kubectl get pods -n notes"

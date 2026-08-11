#!/usr/bin/env bash
# Intentional failure injection for the video's debugging section.
# Overwrites the backend's DB password with a wrong value. This does NOT crash
# the process - the JVM stays up and the liveness probe stays green. What
# breaks is the readiness group (which includes the "db" health indicator),
# so the pod flips to NotReady, the Service drops it from its endpoints, and
# traffic stops - without a restart and without CrashLoopBackOff. That
# distinction (NotReady vs crashing) is the whole point of the demo.
set -euo pipefail
echo "Injecting a bad SPRING_DATASOURCE_PASSWORD into deployment/backend..."
kubectl set env deployment/backend -n notes SPRING_DATASOURCE_PASSWORD=this-is-the-wrong-password
echo
echo "Watch it go NotReady with:"
echo "  kubectl get pods -n notes -w"

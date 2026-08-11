# Notes API — Kubernetes + CI/CD Infrastructure Challenge

A minimal, production-style stack: a Java/Spring Boot REST API backed by PostgreSQL,
containerized, deployed to a local `kind` Kubernetes cluster, with a GitHub Actions
CI/CD pipeline (self-hosted runner) and readiness/liveness probes as the reliability
improvement.

```
Browser/curl → NodePort Service (backend:80→8080) → Deployment "backend" (2 replicas)
                                                          │
                                                          ▼
                                              Service "postgres" (ClusterIP:5432)
                                                          │
                                                          ▼
                                          Deployment "postgres" (1 replica, PVC-backed)

GitHub push → self-hosted Actions runner → docker build → push to GHCR
            → kubectl apply -k k8s/ → kubectl set image deployment/backend
            → kubectl rollout status
```

## 1. Prerequisites (one-time, on your machine)

Your machine currently has **none** of these installed — install them before starting
the clock on your 90 minutes:

1. **Docker Desktop** — https://www.docker.com/products/docker-desktop/ (enable WSL2
   backend if prompted). Start it and confirm `docker ps` works.
2. **kubectl** — https://kubernetes.io/docs/tasks/tools/install-kubectl-windows/
3. **kind** — https://kind.sigs.k8s.io/docs/user/quick-start/#installation
4. A **GitHub account** with a new repo (public or private) to push this project to.

Verify:

```bash
docker ps
kubectl version --client
kind version
```

## 2. Push this project to GitHub

```bash
git remote add origin https://github.com/<you>/<repo>.git
git branch -M main
git push -u origin main
```

## 3. Point the manifest at your image

Edit [`k8s/20-backend-deployment.yaml`](k8s/20-backend-deployment.yaml) and replace
`ghcr.io/CHANGE_ME/notes-app:latest` with `ghcr.io/<your-github-username>/notes-app:latest`
(all lowercase). Commit and push that change.

After your first CI run pushes the image, go to your GitHub profile → **Packages** →
`notes-app` → Package settings → **Change visibility to Public** (simplest path — avoids
setting up an `imagePullSecret` for kind to pull a private GHCR image).

## 4. Register a self-hosted GitHub Actions runner on this machine

In your repo: **Settings → Actions → Runners → New self-hosted runner** (choose Windows
or Linux/WSL to match where you'll run it) and follow GitHub's generated commands — they
include a one-time registration token you must copy from the browser, so this step has
to be done by you interactively. Keep the runner running (`run.cmd` / `./run.sh`) in a
terminal for the whole demo — it's the thing that executes `docker build` and `kubectl`
directly against your local `kind` cluster, which is what makes "self-hosted runner"
the right architecture choice here (a cloud-hosted GitHub runner has no route to your
laptop's cluster).

## 5. Bring up the cluster

```bash
./scripts/setup-cluster.sh
```

This creates the `kind` cluster (with a port mapping so the app is reachable at
`localhost:8080` without an Ingress controller — kept out of scope since probes are
this project's chosen reliability improvement), applies all manifests, and waits for
rollout.

The very first `backend` rollout will only succeed once you've completed step 3 (real
image) and pushed at least once (step 6 below runs CI, which sets the working image).

## 6. Trigger CI/CD

```bash
echo "// trigger" >> app/src/main/java/com/example/notes/NotesApplication.java
git add -A && git commit -m "trigger pipeline" && git push
```

Watch it run under the repo's **Actions** tab, and watch the rollout locally:

```bash
kubectl get pods -n notes -w
```

Once done:

```bash
curl -X POST localhost:8080/api/notes -H "Content-Type: application/json" -d '{"content":"hello"}'
curl localhost:8080/api/notes
```

## 7. Reliability improvement: readiness/liveness probes

**What it is:** `k8s/20-backend-deployment.yaml` defines two separate HTTP probes
against Spring Boot Actuator's health-groups endpoint:

- `livenessProbe` → `/actuator/health/liveness` — only reflects whether the JVM
  process itself is in a healthy running state.
- `readinessProbe` → `/actuator/health/readiness` — reflects `readinessState` **plus**
  the database connectivity check (`db`), wired together explicitly in
  [`app/src/main/resources/application.yml`](app/src/main/resources/application.yml).

**Why this split, not one combined probe:** a database outage or bad credential is not
something restarting the Java process can fix. If the DB check were in the liveness
probe, Kubernetes would kill and restart pods in a loop for a problem restarting can't
solve — actively making the outage worse (CrashLoopBackOff, backoff delays, wasted
scheduling churn) while the real cause (DB down) goes unaddressed. Keeping DB health
in the **readiness** probe instead means: stop routing user traffic to a pod that can't
serve requests correctly, but don't kill the process — let it recover on its own once
the DB comes back, and let a human/alert deal with the actual DB problem.

**Problem it solves:** without readiness gating, a pod that's `Running` but can't reach
its DB still receives traffic from the Service and returns 500s to real users. With it,
the Service's endpoint list drops the pod immediately and traffic only goes to
instances that can actually serve it.

**Tradeoff:** coupling DB health into readiness means a full DB outage takes the whole
app to "no capacity" (all pods NotReady) instead of degrading gracefully with a
fallback/cache — there's no partial-availability mode here. It also adds a tuning
burden: probe thresholds/timeouts have to be set carefully, or transient network blips
cause pods to flap in and out of the Service's endpoint list under load.

## 8. Failure simulation (the debugging demo)

**Break it:**

```bash
./scripts/break-db-password.sh
```

This overwrites `SPRING_DATASOURCE_PASSWORD` on the `backend` Deployment with a wrong
value — a classic "bad environment variable" failure.

**Observe the symptom:**

```bash
kubectl get pods -n notes
```

Pods show `Running` and `1/1 → 0/1` under `READY`, **not** `CrashLoopBackOff`. That's
the key signal: this is a readiness failure, not a crash. (A natural wrong first
assumption to voice on camera: "is it crashing?" — check `RESTARTS` stays at `0`, which
rules that out immediately.)

```bash
curl localhost:8080/api/notes          # times out / connection refused — Service has 0 endpoints
kubectl get endpoints backend -n notes # confirms: empty
kubectl describe pod -n notes -l app=backend   # Events show "Readiness probe failed"
kubectl logs -n notes -l app=backend --tail=50 # shows Postgres auth failure (password authentication failed)
curl localhost:8080/actuator/health/readiness --max-time 2  # will fail too (endpoint unreachable via Service);
# instead port-forward directly to a pod to query it even while NotReady:
kubectl port-forward -n notes deploy/backend 8081:8080 &
curl localhost:8081/actuator/health/readiness   # {"status":"DOWN", ... db: DOWN, readinessState: UP}
```

That last command is the root-cause confirmation: `readinessState` itself is fine (the
app isn't shutting down), but the nested `db` indicator is `DOWN` — pointing straight at
the datasource, not the app logic.

**Fix it:**

```bash
./scripts/fix-db-password.sh
```

This removes the bad env override and re-applies the manifest from git (declarative
fix, not a hand-patch), restoring the correct password via `secretKeyRef`. Watch pods
flip back to `1/1 Running` and endpoints repopulate:

```bash
kubectl get pods -n notes -w
kubectl get endpoints backend -n notes
curl localhost:8080/api/notes
```

## 9. Video script (8–12 min)

**Live demo (3–4 min)** — `kubectl get all -n notes`, `curl` the API, show a GitHub
Actions run completing end-to-end (push → build → GHCR push → deploy → rollout).

**Architecture walkthrough (2–3 min)** — draw the diagram above: `kind` cluster,
namespace `notes`, two Deployments/Services, PVC for Postgres persistence, why a
self-hosted runner (needs direct access to your local cluster — a hosted runner
can't reach it), why probes were the chosen reliability feature.

**Failure debugging walkthrough (2–3 min)** — run through section 8 live: break it,
show `kubectl get pods` (Running but not Ready, restarts = 0), voice the "is it
crashing?" wrong assumption and rule it out, check logs/describe/port-forwarded health
endpoint to find the real cause, fix it, show recovery.

**Tradeoff discussion (1–2 min)**, straight from what's already simplified here:

- Plaintext `Secret` in git instead of a real secret manager.
- No Ingress/TLS — NodePort + a kind port mapping instead, fine for one local cluster,
  not for multiple services or external traffic.
- `spring.jpa.hibernate.ddl-auto=update` instead of versioned migrations (Flyway/
  Liquibase) — fine for a demo, dangerous for a real schema history.
- Single Postgres replica, no managed backups/replication — a real deployment would use
  a managed DB (RDS/Cloud SQL) or an operator (Zalando/CloudNativePG) with backups.
- No autoscaling — fixed 2 replicas; under real load you'd add an HPA plus the
  metrics-server this local setup doesn't run.
- No resource-based circuit breaking/retries between backend and DB — a sustained DB
  outage currently just means "not ready" indefinitely, not graceful degradation.

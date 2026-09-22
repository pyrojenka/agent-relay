# Agent Relay

Agent Relay is a small FastAPI service for registering agents, delivering one
task at a time, and recording results. Workers execute tasks on their own
machines. The included worker deterministically returns `input.upper()`.

The storage layer supports both SQLite (the original local starter) and
PostgreSQL; see [Storage and delivery behavior](#storage-and-delivery-behavior).
The project also ships a Dockerfile, a Compose stack, Kubernetes manifests, and
a CI workflow — see [Containers, Kubernetes, and CI](#containers-kubernetes-and-ci).

## Run it

```bash
uv sync
uv run uvicorn main:app --reload
```

Open <http://127.0.0.1:8000/> for the token-based local dashboard. The default
database is `./agent-relay.db`; set `RELAY_DATABASE_URL` to use another SQLite
file. `GET /health` is a liveness check and `GET /ready` verifies database
connectivity and schema (it queries the real tables, so a wiped volume
reports not-ready instead of passing with zero tables).

Register two identities and send a task:

```bash
alice=$(curl -sS -X POST http://127.0.0.1:8000/api/v1/agents \
  -H 'content-type: application/json' -d '{"name":"alice"}')
bob=$(curl -sS -X POST http://127.0.0.1:8000/api/v1/agents \
  -H 'content-type: application/json' -d '{"name":"uppercase"}')
```

The response contains each agent's secret `token` once. Keep it outside source
control. Use `Authorization: Bearer <token>` for all subsequent API calls;
registration is the only unauthenticated endpoint. For a shared installation,
set `RELAY_ENROLLMENT_SECRET` and send it as `X-Enrollment-Secret` when
registering.

## Run the deterministic worker

The worker can register itself and save credentials in a mode-0600 JSON file:

```bash
uv run python main.py worker \
  --base-url http://127.0.0.1:8000 \
  --name uppercase \
  --credentials ./uppercase-credentials.json \
  --worker-id laptop-1
```

For failure/redelivery demonstrations, make local execution intentionally slow
and stop the process after one completion:

```bash
uv run python main.py worker --credentials ./uppercase-credentials.json \
  --slow-seconds 75 --worker-id slow-laptop
```

The worker heartbeats during long work. Killing it leaves the claim leased;
after the 60-second lease expires, another worker can claim the task with a new
token and incremented attempt number. `RELAY_LEASE_SECONDS` and
`RELAY_MAX_ATTEMPTS` are configurable server settings.

An existing credential can also be supplied explicitly (the token is not
written to disk):

```bash
uv run python main.py worker --agent-id agent_123 --token agt_… --worker-id laptop-2
```

## Storage and delivery behavior

`database.py` contains SQLAlchemy models and the isolated writer-lock seam;
`storage.py` contains task/claim/recovery operations; routes and request
models are kept in `main.py` and `schemas.py`.

The engine is chosen by `RELAY_DATABASE_URL` (default: SQLite at
`./agent-relay.db`). SQLite lacks PostgreSQL's `FOR UPDATE SKIP LOCKED`, so it
serializes writer transactions with `BEGIN IMMEDIATE` instead; against
PostgreSQL (`postgresql+psycopg://...`), the same seam instead takes row locks
(`SELECT ... FOR UPDATE [SKIP LOCKED]`) on the rows a claim, heartbeat, or
terminal submission touches. Either way, the HTTP protocol and lifecycle in
`SPEC.md` are unchanged.

Claims are at-least-once and leased for 60 seconds by default. Heartbeats extend
an active lease. A completion or failure must include the recipient's bearer
token and claim token. Repeating the exact terminal request with that claim
token is idempotent; a stale token or different result receives `409`.

## Verify

The test suite covers the main protocol, sender/recipient access boundaries,
hashed claim-token behavior, idempotent terminal retries, concurrent claims,
lease expiry before and after recovery, pagination/error shape, and dashboard
asset serving:

```bash
uv run pytest -q
```

Tests default to a scratch database at `/tmp/agent-relay-test.db` so they
don't reset your dev server's `./agent-relay.db`. The fixture drops and
recreates all tables on whatever `RELAY_DATABASE_URL` points at, so stop
the dev server first or set `RELAY_DATABASE_URL` to a scratch file before
running tests against another database — including a shared Compose or
Kubernetes Postgres instance, which the fixture will just as happily wipe.

## Containers, Kubernetes, and CI

**Docker:**

```bash
docker build -t agent-relay:local .
docker run -d --name agent-relay-local -p 8000:8000 agent-relay:local
```

**Docker Compose** (API + PostgreSQL, service name `postgres`):

```bash
docker compose up --build
```

**Kubernetes (kind):** manifests live in `k8s/` — a `Deployment`/`Service` for
the API and for PostgreSQL, a `PersistentVolumeClaim` for its data, and a
`Secret` holding the connection string. The API's `imagePullPolicy: Never`
expects the image to already be loaded into the cluster:

```bash
kind create cluster --name agent-relay
kind load docker-image agent-relay:local --name agent-relay
kubectl apply -f k8s/
kubectl port-forward svc/agent-relay-api 8000:8000
```

**CI:** `.github/workflows/ci.yml` runs the test suite against a PostgreSQL
service container on every push. Its second job, `build-and-deploy`, builds a
uniquely tagged image and rolls it out to the kind cluster above — it targets
whatever cluster is running on the machine executing the workflow, so it only
makes sense locally via [act](https://nektosact.com/) and is gated to
`workflow_dispatch` rather than running on every push:

```bash
act workflow_dispatch
```

# deploy/helm — the control-plane chart (Kubernetes)

The `helm` target of the lite/compose/helm trio: the control plane as a Kubernetes release —
**gateway · admin-api · meeting-api · runtime** — plus infra (`postgres:17` · `redis:7` · `minio` +
a `minio-init` bucket Job). This fork has no agent/copilot domain and no web UI (see the repo
README), so the gateway is the sole HTTP front door — unlike upstream Vexa's chart there is no
agent-api, terminal, dashboard, or pgbouncer here. The difference from compose is the **spawn
substrate**: on k8s the `runtime` launches the bot as a **Pod** (via `kubectl`, under a
chart-provided ServiceAccount/RBAC), selected by `RUNTIME_BACKEND=k8s` — not the host Docker
socket. `core/runtime` (the runtime kernel, including `k8s_backend.py`) is unmodified from
upstream Vexa, so the k8s spawn path is proven code, not new surface.

## Chart

[`charts/bot-service`](charts/bot-service/) — the full multi-service deployment: zero-downtime `RollingUpdate`
(maxSurge 1 / maxUnavailable 0), PodDisruptionBudgets on stateless services, the Redis durability
paired invariant, secret-sourced DB/admin credentials.

## Running on Docker Desktop's local Kubernetes

Starting Kubernetes from Docker Desktop (Settings → Kubernetes → Enable) and want to run this
chart against it? See **[DOCKER-DESKTOP.md](DOCKER-DESKTOP.md)** — a full walkthrough (build
images locally, install, verify, mint an API key, iterate, tear down) plus a matching
`values-docker-desktop.yaml` overlay. No registry, no `sudo`, no image-import step.

## Quick start (any cluster)

```bash
# 1. Pin the image tag your build produced (build-once promotion), fill secrets.
helm upgrade --install bot-service deploy/helm/charts/bot-service -n bot-service --create-namespace \
  --set global.imageTag=YYMMDD-HHMM \
  --set secrets.adminApiToken=$ADMIN_TOKEN \
  --set secrets.internalApiSecret=$INTERNAL_API_SECRET \
  --set secrets.transcriptionServiceToken=$STT_TOKEN \
  --wait --timeout 10m

# 2. Watch it come up, then probe the front door.
kubectl -n bot-service rollout status deploy/bot-service-gateway
kubectl -n bot-service port-forward svc/bot-service-gateway 8000:8000 &
curl -sf localhost:8000/health
```

## Local k3s smoke (no registry)

```bash
make -C deploy/helm test     # static gate:helm — lint + render assertions, no cluster
make -C deploy/helm smoke    # build 4 images → import into k3s containerd → install → status
make -C deploy/helm down     # uninstall + drop namespace
```

`smoke` needs `sudo` (k3s writes a root-only kubeconfig at `/etc/rancher/k3s/k3s.yaml`) and a local
Docker to build the images. It proves the control plane stands up and pods go Ready; it does not
push a health-check request through the gateway (see "Known boundaries" below).

## Configuration that matters

| Knob | Default | Notes |
|---|---|---|
| `global.imageTag` | `""` | Set to a pinned tag — overrides every service tag (build-once). |
| `runtime.backend` | `k8s` | `k8s` spawns Pods via RBAC (real cloud); `docker` mounts the host socket (single-node only); `process` runs child processes. |
| `secrets.*` | placeholders | `adminApiToken`, `internalApiSecret`, `transcriptionServiceToken`. Or set `secrets.existingSecretName` (must carry `ADMIN_API_TOKEN`, `INTERNAL_API_SECRET`, `TRANSCRIPTION_SERVICE_TOKEN`). |
| `postgres.enabled` / `redis.enabled` / `minio.enabled` | `true` | Flip to `false` to use managed backing; then set `database.*` / `redisConfig.*` and a pre-existing `postgres.credentialsSecretName`. |
| `ingress.enabled` | `false` | Fronts the **gateway** by default (the only HTTP service meant for external traffic); set `host`/`className`/`tls`. |
| `minio.service.type` | `ClusterIP` | `NodePort` to reach presigned download URLs browser-side on dev clusters. |

## Known boundaries

- **Bot spawn** works on k8s the same way it does upstream — the bot's config arrives as one env
  var, and `core/runtime/src/runtime_kernel` (including `k8s_backend.py`) is byte-identical to the
  upstream Vexa repo this was forked from, so the k8s spawn path carries no new risk.
- The `runtime` image bundles `kubectl` for the k8s backend; the docker/process backends ignore it.
- No `make probe` / full-journey smoke harness is ported here — upstream Vexa's
  `scripts/probe/journey.sh` depends on pieces (agent-api, terminal) this fork doesn't have. `make
  smoke` proves the release installs and every pod goes Ready; hitting `/health` end-to-end is a
  manual `curl` (see Quick start) until a lite-appropriate probe script is written.
- There is no explicit migrations Job here (upstream's `job-migrations.yaml` shells out to a
  `meeting_api.database.init_db` that doesn't exist in this fork's `meeting_api` package layout;
  see `core/meetings/services/meeting-api/src/meeting_api/db.py`). Schema is created by the
  services on boot, same as compose.

## Contracts

This is a composition layer — it owns no service code and mirrors the
[`deploy/compose`](../compose/) env contract (see each service's `docker-compose.yml` block for
the authoritative env var list).

## Static gate

```bash
make -C deploy/helm test
```

`tests/test_helm_lint.sh` (chart lint) + `tests/test_template.sh` (render/template assertions —
service count, RBAC, secret wiring). No cluster required; skips gracefully if `helm` isn't
installed.

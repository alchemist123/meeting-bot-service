# Running Bot Service Lite on Docker Desktop's Kubernetes

A step-by-step guide to standing up the whole control plane (gateway · admin-api · meeting-api ·
runtime + postgres · redis · minio) on the single-node Kubernetes cluster built into Docker
Desktop — no registry, no cloud, everything built and run locally.

This is the `helm` deploy target of the lite/compose/helm trio (see [`README.md`](README.md) for
the general chart docs); this file is the Docker-Desktop-specific walkthrough.

---

## 0. Safety check — which cluster are you actually pointed at?

Docker Desktop's Kubernetes registers as a context named **`docker-desktop`** in your kubeconfig,
alongside any other clusters you talk to (a GKE/EKS/staging cluster, etc.). Every command below
that touches a cluster is written with an explicit `--context docker-desktop` (or
`--kube-context docker-desktop` for helm) for exactly this reason — **never rely on "whatever the
current context happens to be"** when a stray `kubectl apply`/`helm install` against the wrong
context can land on a real cluster.

Check what you have and confirm `docker-desktop` is present:

```bash
kubectl config get-contexts
```

If you don't see a `docker-desktop` row, Kubernetes isn't enabled yet — see step 1. If you'd
rather not type `--context` on every command, switch your *current* context once you've confirmed
it's safe to do so:

```bash
kubectl config use-context docker-desktop
```

The rest of this guide uses the explicit `--context`/`--kube-context` flags so it's safe to copy-paste
regardless of what your current context is.

## 1. Prerequisites

- **Docker Desktop**, with Kubernetes enabled: Settings → Kubernetes → check "Enable Kubernetes" →
  Apply & Restart. Wait for the whale icon to go steady and `kubectl --context docker-desktop get nodes`
  to show a single `Ready` node.
- **Helm** (v3):
  ```bash
  brew install helm
  ```
- From the repo root, a `.env` for the image build step:
  ```bash
  cd deploy/compose && cp -n .env.example .env && cd -
  ```

## 2. Build the images locally

Docker Desktop's Kubernetes shares the **same image store** as `docker build` on your host — an
image you build locally is immediately schedulable by the cluster, no push/pull, no registry, no
separate "import into the node" step (that's only needed for k3s/minikube-style VMs).

All commands in this guide are written to run **from the repo root** (`new-vexa/`, the directory
containing the top-level `Makefile`) — `pwd` should end in `new-vexa` before you run them:

```bash
# From the repo root (new-vexa/).
make -C deploy/compose build     # the 4 core services -> bot-service-lite/{admin-api,runtime,meeting-api,gateway}:dev
make compose-bot                 # the meeting-bot image -> bot-service-lite/bot-service-bot:dev
```

Already `cd`'d into `deploy/compose`? Its own `Makefile` has the same two steps without the
`deploy/compose`/`compose-` prefixes:

```bash
# From inside deploy/compose/.
make build   # the 4 core services
make bot     # the meeting-bot image
```

Confirm all five images landed:

```bash
docker images | grep bot-service-lite
```

Re-run either target any time you change service or bot source — the chart's
`imagePullPolicy: Never` (see `values-docker-desktop.yaml`) means the cluster will only ever use
what's already in your local image store, never try to fetch from a registry.

## 3. Install the chart

```bash
helm upgrade --install bot-service deploy/helm/charts/bot-service \
  --kube-context docker-desktop \
  -n bot-service --create-namespace \
  -f deploy/helm/charts/bot-service/values-docker-desktop.yaml \
  --wait --timeout 5m
```

`--wait` blocks until every Deployment/StatefulSet reports Ready — expect ~1-2 minutes on a cold
cluster (postgres + minio need their PVCs to bind first). If it times out, skip straight to
Troubleshooting below rather than re-running blind.

## 4. Verify

```bash
kubectl --context docker-desktop -n bot-service get pods
```

You should see 7 pods Running: `gateway`, `admin-api`, `meeting-api`, `runtime`, `redis`,
`postgres-0`, `minio-0` (StatefulSet pods carry a `-0` suffix). Plus a completed `minio-init-*`
Job pod (`Completed`, not `Running` — that's correct, it's a one-shot bucket-creation Job).

```bash
curl -sf http://localhost:30056/health && echo
```

`values-docker-desktop.yaml` exposes the gateway as a NodePort on `30056` — Docker Desktop
forwards NodePort services straight to `localhost` on the host, so no `port-forward` or node-IP
lookup is needed (unlike k3s/minikube). A `{"status":"ok", ...}`-shaped response means the whole
chain (gateway → admin-api/meeting-api → postgres/redis) is healthy.

If you'd rather not open a NodePort, `kubectl --context docker-desktop -n bot-service port-forward
svc/bot-service-gateway 18056:8000` works identically.

## 5. Mint an API key and join a meeting

```bash
# Port-forward admin-api so provision-token (a compose-flavored script, still reusable here) can reach it.
kubectl --context docker-desktop -n bot-service port-forward svc/bot-service-admin-api 18057:8001 &

ADMIN_API_URL=http://127.0.0.1:18057 ADMIN_TOKEN=dev-admin-token \
  deploy/compose/bin/provision-token
# -> vxa_...   (your API key; ADMIN_TOKEN matches values-docker-desktop.yaml's secrets.adminApiToken)
```

Then drive the gateway the same way you would against compose (see the [gateway API
docs](http://localhost:30056/docs) for the full surface):

```bash
curl -sS -X POST http://localhost:30056/bots \
  -H "X-API-Key: <the vxa_... token>" \
  -H "Content-Type: application/json" \
  -d '{"native_meeting_id": "abc-defg-hij", "platform": "google_meet"}'
```

The runtime spawns the bot as its **own Pod** (`kubectl --context docker-desktop -n bot-service get pods
-w` to watch it appear) — that's the thing this whole chart exists to prove: `runtime.backend: k8s`
in `values-docker-desktop.yaml` exercises the exact same `k8s_backend.py` spawn path a real cloud
deployment uses, just against your laptop's single-node cluster instead of a managed cluster.

## 6. Iterate

Changed service code? Rebuild the image and roll the one Deployment that owns it — no full
reinstall needed:

```bash
make -C deploy/compose build   # or scope to one service: docker compose -f deploy/compose/docker-compose.yml build meeting-api
kubectl --context docker-desktop -n bot-service rollout restart deployment/bot-service-meeting-api
kubectl --context docker-desktop -n bot-service rollout status deployment/bot-service-meeting-api
```

(`imagePullPolicy: Never` + an unchanged `:dev` tag means Kubernetes won't notice a new image
unless you force it — `rollout restart` does that.)

Changed a values file or a chart template? Re-run the same `helm upgrade --install` from step 3;
Helm diffs and only touches what changed.

## 7. Tear down

```bash
helm uninstall bot-service --kube-context docker-desktop -n bot-service
kubectl --context docker-desktop delete namespace bot-service
```

PVCs are deleted with the namespace, so this also drops the postgres/redis/minio data. To keep the
cluster but stop paying its CPU/RAM tax, you can also just disable Kubernetes in Docker Desktop
settings instead of deleting the release.

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `helm install` times out waiting on a Deployment | `kubectl -n bot-service describe pod <name>` — almost always `ImagePullBackOff` (an image wasn't built — re-run step 2 and check the exact repo:tag it's requesting against `docker images`). |
| `postgres-0` / `minio-0` stuck `Pending` | `kubectl -n bot-service get pvc` — if a PVC is `Pending`, Docker Desktop's default StorageClass isn't there; `kubectl get storageclass` should show one marked `(default)`. Reset Kubernetes (Docker Desktop → Troubleshoot → Clean/Purge data) if it's missing after enabling. |
| `curl localhost:30056` connection refused | Gateway pod not Ready yet (`kubectl -n bot-service get pods`), or you're hitting a stale NodePort from a previous `helm uninstall` — re-check `kubectl -n bot-service get svc bot-service-gateway`. |
| A spawned bot Pod never appears / meeting silently fails | `kubectl -n bot-service logs deploy/bot-service-runtime` — check the runtime actually has RBAC (`kubectl -n bot-service get sa,role,rolebinding | grep runtime`) and that `bot-service-lite/bot-service-bot:dev` exists locally (`make compose-bot`). |
| You ran a command against the wrong cluster | Always double-check `kubectl config current-context` (or better, always pass `--context docker-desktop` explicitly, as this guide does) before anything destructive. |

## Why this differs from `README.md`'s k3s instructions

The chart's general README documents a k3s-based smoke flow (`make -C deploy/helm smoke`) because
that's the reproducible CI-style path. Docker Desktop needs no `sudo`, no separate kubeconfig, and
no image-import step — its Kubernetes node reads directly from the same Docker image store your
`docker build` writes to. This guide (and `values-docker-desktop.yaml`) exists so you don't have to
translate the k3s instructions in your head.

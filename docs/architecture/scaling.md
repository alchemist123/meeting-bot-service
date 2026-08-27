# Scaling bot-service

## What the runtime already supports today

`core/runtime/src/runtime_kernel/` ships **three** interchangeable spawn backends, selected by `RUNTIME_BACKEND`:

| Backend | How it spawns a bot | Isolation | Deploy mode |
|---|---|---|---|
| `process` | `subprocess.Popen`, own process group | POSIX uid/gid only — all bots share one host's Xvfb/PulseAudio/kernel | `deploy/lite` |
| `docker` | `POST /containers/create` over `/var/run/docker.sock` | real container boundary; sets `NetworkMode` + `ShmSize` (2g, for Chromium's `/dev/shm`) | `deploy/compose` |
| `k8s` | `kubectl run <name> --restart=Never` — a **bare Pod**, not a Job | real pod boundary; only injects volumes/tolerations/nodeSelector | not shipped as a `deploy/` target yet |

Two things worth knowing before you pick a scaling strategy, confirmed directly in the code:

- **Neither `docker_backend.py` nor `k8s_backend.py` sets any CPU/memory request or limit anywhere.** No `Resources`/`NanoCpus`/`Memory` in the Docker payload, no `resources.requests/limits` in the k8s pod spec. Today, one runaway Chromium can starve its neighbors, and a k8s scheduler/autoscaler has nothing to bin-pack against.
- **The only capacity control that exists is `max_concurrent_bots`** (default 3), a *per-user* concurrency ceiling enforced in `meeting-api`. It's tenant fairness, not cluster capacity planning — size your infrastructure for the sum across all tenants, not per-tenant.
- All three backends re-adopt orphaned containers/pods on restart (via `runtime.managed` + `workload_id` labels), so a node recycle is survivable — but nothing auto-restarts a bot that itself failed (`restart=Never`, no backoff).
- No GPU is ever needed for the bot process itself — GPU only matters for the *optional* self-hosted STT worker (`deploy/transcription`), which scales completely separately.
- Per-bot footprint is Chromium (Playwright) + Xvfb + PulseAudio + Node — CPU/memory bound, no GPU. Treat **~1–2 vCPU / 2–4 GB RAM per active bot** as a starting estimate to load-test against, not a guarantee.

## Two ways to scale it in production

### A) Container-native platform (Kubernetes / Cloud Run / Fargate / Azure Container Apps) — builds on `k8s_backend`

One bot = one pod/task. The platform's own scheduler places pods on nodes, and a cluster autoscaler (Cluster Autoscaler, Karpenter, or the managed equivalent under Cloud Run/Fargate/Container Apps) adds or removes **nodes** — which are VMs under the hood — in response to pods that can't be scheduled. You get elastic capacity without building any placement logic yourself.

**What has to be added to make this real** (none of it exists yet):
1. Resource `requests`/`limits` on the bot pod spec — without these, the scheduler can't bin-pack and the autoscaler has no signal to react to.
2. A memory-backed `/dev/shm` volume (`emptyDir: {medium: Memory}`) — `docker_backend` already gives Chromium 2g of shared memory via `ShmSize`; `k8s_backend` has no equivalent today and Chromium will crash under load without it.
3. Bare Pod → **Job** (or Pod + TTL controller) — for completion tracking, backoff, and automatic cleanup instead of relying on the runtime's own orphan-reaping.
4. Pre-pulled/warm node pool for the bot image, or accept a cold-start pull hit (the Playwright + browser image is not small) when scaling from zero.

**Pros:** off-the-shelf scheduler and autoscaler, strong per-bot isolation, no custom placement code, works the same whether you self-run k8s or use a managed serverless-container product.
**Cons:** either a real cluster to operate, or a managed platform's constraints (e.g. Cloud Run/Fargate don't give you a Docker socket, so you'd adapt to their task/job API rather than reuse `docker_backend` as-is); cold-start latency for a heavy browser image.

### B) VM pool + Docker socket — scaling out today's `docker_backend` / `deploy/compose` model

A VM Scale Set / ASG of hosts, each running Docker Engine and its own `runtime` instance with its own socket; the VM count autoscales on some aggregate load signal.

**The catch:** `meeting-api` today talks to exactly **one** `RUNTIME_API_URL`. There is no placement/routing layer that spreads spawn requests across many runtime instances/VMs — you would have to build one (round-robin or least-loaded routing, health checks, draining a VM's in-flight bots before it's removed on scale-in). You'd also need to add the same CPU/memory limits to `docker_backend`'s container-create payload, and invent and emit your own capacity metric (e.g. "concurrent active bots" as a custom CloudWatch/Stackdriver metric) to drive the ASG — Kubernetes gives you "pending/unschedulable pods" as that signal for free; a VM pool doesn't.

**Pros:** matches the existing `deploy/compose` mental model exactly, no k8s learning curve, still real per-bot container isolation.
**Cons:** the placement layer, the capacity signal, and graceful-drain-on-scale-in are all things you'd build from scratch — which is most of what a k8s scheduler + cluster autoscaler already gives you for free under option A.

## Recommendation

If real autoscaling is the goal, **A is the shorter path** — `k8s_backend` already exists, so the remaining work is the four items listed above (resource limits, shared memory, Job instead of bare Pod, warm node pool), not a new orchestration layer. **B is worth it only** if you specifically want to avoid operating Kubernetes and are willing to build the missing placement/capacity-signal/drain logic yourself for a modest, predictable number of VMs.

## Before either approach "autoscales" safely

1. Add resource requests/limits — `docker_backend` (`HostConfig.NanoCpus`/`Memory`) and `k8s_backend` (`resources.requests/limits`) both need this; today neither sets it.
2. Give k8s bot pods the `/dev/shm` memory volume `docker_backend` already provides via `ShmSize`.
3. Move k8s bot lifecycle from a bare `kubectl run` Pod to a Job for backoff/cleanup semantics.
4. Pick and wire up a capacity signal — free with k8s (pending pods), must be built for a VM pool.
5. Keep `max_concurrent_bots` as the tenant-fairness knob; don't confuse it with cluster sizing.

## Deploying `deploy/lite` specifically to Azure Container Apps (ACA)

ACA can absolutely run the lite image and can scale its **replica count** (KEDA-based rules: HTTP concurrency, queue length, CPU/memory %, or a custom scaler). But that scaling knob doesn't map onto "more bot capacity" the way it would for a stateless web app, for two concrete reasons specific to this image:

1. **The `process` backend is single-instance by nature.** A bot spawned by replica A exists only as a child process inside replica A — no other replica can see, poll, or stop it. ACA's session affinity is HTTP-cookie-based and only applies in single-revision mode; an API client authenticating with `X-API-Key` (like NoteTaker) carries no cookie, so ACA has no way to route a later `GET /meetings/{id}` or `DELETE /bots/...` for that same bot back to the replica that owns it. The instant you go above 1 replica, control calls for an in-flight bot can land on the wrong replica and silently fail or return stale state.
2. **`/dev/shm` is fixed at the container default (64 MB) on ACA**, and there's no supported way to raise it to the `--shm-size=2g` that `deploy/lite/Makefile`'s plain `docker run` already gives Chromium ([Microsoft Q&A confirms this isn't configurable for Container Apps](https://learn.microsoft.com/en-us/answers/questions/2148521/size-of-dev-shm-in-container-app-job), with only an unofficial `EmptyDir`-mount workaround reported). Chromium is known to be unstable on undersized `/dev/shm` — this is a real crash risk for concurrent bots, not a theoretical one, and should be load-tested before you trust it.

Two structural facts close off the alternatives: ACA gives your container no Docker socket (so `docker_backend` can't run there) and no Kubernetes API access (so `k8s_backend` can't either) — confirmed by [Azure Container Apps' sidecar docs](https://docs.azure.cn/en-us/container-apps/containers), which describe sidecars as sharing disk/network only *within one container app's replica*, not across replicas or as a general-purpose Docker host.

**What this means practically:**

- Run the lite image on ACA with **`minReplicas = maxReplicas = 1`**. That's not really "autoscaling" — it's "a managed way to run one container with a public endpoint, TLS, and restarts." Scale *up*, not *out*: pick a bigger CPU/memory allocation for that one replica (ACA workload profiles support much larger single-instance sizes than the Consumption plan default) to host more concurrent bots, bounded by CPU/RAM and the `/dev/shm` risk above.
- Externalize Postgres/Redis/MinIO to managed services (Azure Database for PostgreSQL, Azure Cache for Redis, Blob Storage) regardless of replica count — sidecars-in-one-revision only work for that one instance and block you from ever safely going beyond `maxReplicas=1` later.
- If you actually need elastic, multi-instance bot capacity, ACA + the lite/process image is the wrong pairing. The two real paths: (a) move `runtime` to **AKS** and use the existing `k8s_backend` (gateway/admin-api can stay on ACA if you like, just point them at the AKS-hosted runtime) — this is the path described above under "Container-native platform"; or (b) write a **new runtime backend targeting Azure Container Instances (ACI)** — one bot = one ACI container instance via Azure's REST API, no cluster to operate, closer to Fargate's model and a more natural fit for "serverless, one-shot container per bot" than ACA's replica-scaling model.

Sources: [Session Affinity in Azure Container Apps](https://learn.microsoft.com/en-us/azure/container-apps/sticky-sessions) · [Set scaling rules in Azure Container Apps](https://learn.microsoft.com/en-us/azure/container-apps/scale-app) · [Size of /dev/shm in container app job (Microsoft Q&A)](https://learn.microsoft.com/en-us/answers/questions/2148521/size-of-dev-shm-in-container-app-job) · [Containers in Azure Container Apps](https://docs.azure.cn/en-us/container-apps/containers)

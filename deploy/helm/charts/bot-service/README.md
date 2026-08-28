# bot-service — Bot Service Lite Helm chart

Deploys the meetings-only control plane to Kubernetes: **gateway · admin-api · meeting-api ·
runtime**, and infra (`postgres` · `redis` · `minio` + a `minio-init` bucket Job). The `runtime`
spawns the bot as an on-demand Pod (`RUNTIME_BACKEND=k8s`, under the chart's ServiceAccount/RBAC);
it is not a long-running service. There is no agent/copilot domain and no web UI in this fork —
the gateway is the sole HTTP front door.

```
            ┌──────────┐
  client ──>│ gateway  │──> admin-api ──┐
            └────┬─────┘                ├─> postgres
                 └────> meeting-api ────┘
                          │  └─> minio (recordings)
                          └─> runtime ──(kubectl run)──> bot Pod
                                                          redis (streams/pubsub)
```

## Install

```bash
helm upgrade --install bot-service . -n bot-service --create-namespace \
  --set global.imageTag=YYMMDD-HHMM \
  --set secrets.adminApiToken=$ADMIN_TOKEN \
  --set secrets.internalApiSecret=$INTERNAL_API_SECRET
```

See [`../../README.md`](../../README.md) for the cookbook (local k3s smoke, managed backing,
ingress) and the values table. Key knobs: `global.imageTag`, `runtime.backend`
(`k8s`|`docker`|`process`), `secrets.*` (or `secrets.existingSecretName`),
`postgres/redis/minio.enabled`, `ingress.*`.

## Spreading replicas across nodes

`replicaCount > 1` alone buys rolling-update safety, not availability — the scheduler may place
every replica on one node, so losing that node takes the whole component down. Add pod topology
spread to force replicas apart. `global.topologySpreadConstraints` applies to **every** component
(gateway · admin-api · meeting-api · runtime); when a constraint omits `labelSelector`, the chart
injects **that component's own pod selector**, so one block means "spread each component's own
replicas":

```yaml
global:
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: kubernetes.io/hostname
      whenUnsatisfiable: ScheduleAnyway   # best-effort — small/single-node clusters still schedule
```

Override per component with `<component>.topologySpreadConstraints` (same shape, wins over the
global default for that component only). Provide your own `labelSelector` in a constraint to opt
out of the automatic injection. Empty default (the shipped value) renders nothing — single-node /
k3s installs are unaffected. Use `ScheduleAnyway`, not `DoNotSchedule`, unless you can guarantee
enough nodes, or pods stay Pending.

## Validate (no cluster)

```bash
helm lint .
helm template bot-service . -n bot-service -f values-test.yaml
```

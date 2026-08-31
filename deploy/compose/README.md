# deploy/compose — per-service containers, bot-per-container

The meeting-bot control plane as separate containers: `postgres` · `redis` · `minio` +
`minio-init` infra, then four long-running services — **admin-api · runtime · meeting-api ·
gateway** — each its own slim `uv`-based image. Every service carries a healthcheck; bring-up is
ordered via `depends_on: condition: service_healthy`.

The **bot is not a compose service** — `runtime` spawns it on demand, **one container per
meeting**, over the mounted `/var/run/docker.sock` (`BROWSER_IMAGE`). That's the difference from
[`../lite`](../lite/): here every bot gets its own container (full isolation, matches how you'd
run this in production); in lite, bots are child processes sharing one container.

## Quick start

```bash
cd deploy/compose
cp .env.example .env                # then set TRANSCRIPTION_SERVICE_URL/_TOKEN if you have a token
make bot                             # build the meeting-bot image (one-time, or after bot changes)
make dev                             # build the 4 core services from this checkout + bring the stack up
```

`make dev` prints your gateway URL and a minted API key when it's done. Re-run `make bot` any
time you change bot/capture-module source — no restart needed, the next spawned bot picks it up.

```bash
make -C deploy/compose down           # stop + remove (volumes persist; docker volume rm to wipe)
make -C deploy/compose logs           # follow all service logs
make -C deploy/compose ps             # service status
```

## Requirements

Docker engine ≥ v26 (the runtime's Docker backend needs the Mounts API's named-volume subpath
support used for per-bot workspace isolation).

## Configuration

See [`.env.example`](.env.example) — host ports, DB/MinIO credentials, `BROWSER_IMAGE`,
transcription, and the gateway edge guard (`GUARD_*`).

## Provisioning more API keys

```bash
make -C deploy/compose provision-token ADMIN_TOKEN=<your ADMIN_TOKEN>
```

Mints an idempotent `bot,tx`-scoped token for `self-host@vexa.ai` (override `EMAIL=`), prints only
the token.

## Shared-secret auth (skip token provisioning entirely)

Set `SHARED_API_TOKEN` in `.env` and send that exact value as `X-API-Key` on every request — it
authenticates with full scopes, no `provision-token` step needed. Meant for a single self-hoster
who wants one secret, not per-user accounts. Blank (default) leaves the per-user token flow above
unchanged.

## Not included

This fork ships the bare stack + the `bot` build target only — it does not carry upstream Vexa's
hot-reload dev overlay (`docker-compose.dev.yml`), CI-cache overlay, or its compose-level
integration test suite (`tests/stack_test.py` and friends), all of which are agent/dashboard-aware
and release-governance-oriented. Port them from [Vexa](https://github.com/Vexa-ai/vexa)'s
`deploy/compose` if you need them.

# Vexa Lite (meetings-only)

The whole meeting-bot control plane in **one container**. The simplest way to self-host —
`make lite` from the repo root provisions PostgreSQL + MinIO and runs everything else in a single
image.

## Why

Everything except the datastores runs in one container — gateway, admin-api, meeting-api,
runtime, redis, and the X11/audio stack. No Docker socket, no per-service containers. The runtime
uses the **process backend**: meeting bots run as **child processes** inside the container, not
socket-spawned containers.

- One app container instead of five
- Full meeting-bot API (join → capture → transcribe → transcript + recording) — no agent/copilot
  domain, no web UI
- No GPU required — transcription runs via an external API (or your own GPU service)

## Quick start

From the repo root:

```bash
make lite
```

Provisions a PostgreSQL + MinIO sidecar, builds the lite image, starts everything on the host
network, and probes the front door. Set `TRANSCRIPTION_SERVICE_URL` / `TRANSCRIPTION_SERVICE_TOKEN`
in the repo-root `.env` for transcripts (get a token at `vexa.ai/account`, or self-host
[`deploy/transcription`](../transcription/) on a GPU).

Grab your API key once it's up:

```bash
docker logs vexa-lite | grep VEXA_API_KEY
```

### Transcripts with no token and no GPU — `LOCAL_STT=1`

```bash
make -C deploy/lite up LOCAL_STT=1
```

Runs a bundled **faster-whisper CPU server on the tiny model** (`vexa-lite-whisper`) on the same
network and **auto-wires `TRANSCRIPTION_SERVICE_URL`** to it — real transcripts out of the box,
slower than a GPU but zero setup. Verify it end-to-end (synthesize speech → transcribe):

```bash
make -C deploy/lite stt-smoke        # ✓ local STT transcribes (model=whisper-1 → words)
```

Override the model or image for more accuracy: `WHISPER_MODEL=Systran/faster-whisper-small.en`, or
a GPU image via `WHISPER_IMAGE=...`. (The client sends `model=whisper-1`, the OpenAI id;
faster-whisper-server accepts it and serves `WHISPER_MODEL`.)

After it finishes:

- **API:** `http://YOUR_IP:8056` (the gateway — auth, routing) · docs at `/docs`

To stop: `make down` (data volumes are kept; `docker volume rm vexa-lite-pgdata
vexa-lite-miniodata` to wipe).

## What's inside

Supervised by `supervisord`:

| Service | Port | Role |
|---|---|---|
| gateway | **8056** | the one front door — auth, scopes, routing, `/ws` fan-out |
| admin-api | 8001 | users + API keys + `/internal/validate` |
| meeting-api | 8080 | bots, transcripts, recordings (→ MinIO) |
| runtime | 8090 | spawns the bot as a **child process** (process backend) |
| redis | 6379 | bus + scheduler (internal) |
| Xvfb · fluxbox · PulseAudio | :99 | display + audio for the headful bot browser |

External (the `make lite` sidecars): **PostgreSQL** (metadata) and **MinIO** (recordings).

### Architecture

```
+--------------------------------------------------------------+
|                    Vexa Lite container                       |
|                                                              |
|  gateway  admin-api  meeting-api  runtime                    |
|   :8056     :8001      :8080       :8090                      |
|                                                              |
|  redis   Xvfb  fluxbox  PulseAudio                           |
|   :6379   :99                                                |
|                                                              |
|  bot processes (Playwright)                                  |
|     ← runtime spawns as child processes (process backend)    |
+--------------------------------------------------------------+
        |                    |                    |
        v                    v                    v
   Transcription        PostgreSQL             MinIO
     (external)         (sidecar)             (sidecar)
```

## Configuration

The repo-root `.env` (see [`.env.example`](../../.env.example)):

| Variable | Default | Description |
|---|---|---|
| `TRANSCRIPTION_SERVICE_URL` / `_TOKEN` | — | STT endpoint + key for the bot's transcript pipeline. Unset → bots capture, no transcript. |
| `ADMIN_TOKEN` | `changeme` | admin API token (the stack's shared admin secret) |
| `IMAGE_TAG` | `latest` | the image tag to pull (a local `vexa-lite:dev` build wins) |

`make` variables (not `.env`) for the bundled local STT: `LOCAL_STT=1` (off by default),
`WHISPER_MODEL` (`Systran/faster-whisper-tiny.en`), `WHISPER_IMAGE`, `HOST_STT_PORT` (`8083`). When
`LOCAL_STT=1`, the bundled server overrides `TRANSCRIPTION_SERVICE_URL` for you.

## Debugging

```bash
docker logs -f vexa-lite                          # container logs
docker exec vexa-lite supervisorctl status        # all supervised services
docker exec vexa-lite supervisorctl restart meeting-api
docker exec vexa-lite ps aux | grep dist/index.js # running bot processes
```

## Known limitations

| Issue | Note |
|---|---|
| Shared X11 display | bots share one Xvfb (`:99`) — best for one browser session at a time |
| Ephemeral redis | internal redis is in-container; mount `/var/lib/redis` for persistence |
| No browser debug view | this build drops the noVNC/x11vnc viewer for a pure API surface; debug via `docker logs` |

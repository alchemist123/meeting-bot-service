# deploy — running the meeting-bot control plane

This meetings-only fork ships a single deploy target: **[`deploy/lite`](lite/)**, the all-in-one
single-container image. It runs admin-api, runtime, meeting-api, and gateway as supervised
processes over an internal redis + a shared Xvfb/PulseAudio stack; the runtime uses the
**process backend** (`RUNTIME_BACKEND=process`), so meeting bots run as child processes — no
Docker socket required. PostgreSQL + MinIO are external sidecars `make lite` provisions for you.

```bash
make lite      # from the repo root — provisions Postgres + MinIO, builds, runs, verifies
```

See [`deploy/lite/README.md`](lite/README.md) for the full configuration reference (transcription,
recordings, the bundled CPU STT option).

## Transcription

Vexa's transcript pipeline always calls out to an external OpenAI-audio-compatible
`/v1/audio/transcriptions` endpoint (`TRANSCRIPTION_SERVICE_URL` / `_TOKEN`) — it is never bundled
into the app container, since STT is GPU-shaped and every self-host would otherwise be forced onto
an NVIDIA GPU. Three ways to get transcripts:

1. A hosted token (`vexa.ai/account`).
2. `make -C deploy/lite up LOCAL_STT=1` — a bundled CPU faster-whisper container, zero setup, real
   transcripts (slower than GPU).
3. Self-host the GPU STT worker in [`deploy/transcription`](transcription/) — the same code Vexa
   itself deploys, fully air-gapped.

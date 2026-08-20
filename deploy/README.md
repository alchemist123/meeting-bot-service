# deploy — running the meeting-bot control plane

Two deploy targets, same service code, different bot isolation model:

| | [`deploy/lite`](lite/) | [`deploy/compose`](compose/) |
|---|---|---|
| Shape | one container, everything supervised | one container per service |
| Bot isolation | child **process** (`RUNTIME_BACKEND=process`) | its own **container** (Docker socket) |
| Docker socket | not needed | required |
| Setup | `make lite` | `cd deploy/compose && make bot && make dev` |
| Best for | quick eval, small teams, resource-constrained hosts | production-shaped isolation, per-bot resource limits |

Both run the exact same admin-api / runtime / meeting-api / gateway code and the exact same bot;
the only difference is how the runtime spawns the bot.

```bash
make lite      # from the repo root — single container, provisions Postgres + MinIO, builds, runs
```

See [`deploy/lite/README.md`](lite/README.md) and [`deploy/compose/README.md`](compose/README.md)
for the full configuration reference (transcription, recordings, the bundled CPU STT option).

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

<div align="center">

# Vexa Lite (meetings-only)

**Open-source, self-hosted meeting bot & transcription API.**

A bot joins your Google Meet, Microsoft Teams, Zoom, and Jitsi calls and streams
speaker-attributed transcripts in real time through an API *you* host. Self-hosted, Apache-2.0,
air-gap-ready.

This is a **meetings-only fork of [Vexa](https://github.com/Vexa-ai/vexa)** — the same capture
code and stack (runtime, gateway, identity, meeting-api, bot), stripped of Vexa's agent/copilot
domain and every web UI. If you only want a bot that joins calls and gives you a transcript over
an API, this is that, and nothing else.

</div>

---

## Quickstart

Two deploy shapes, same code — pick one:

- **`make lite`** — single container, meeting bots run as **child processes**. Fastest to stand
  up, no Docker socket needed. See [`deploy/lite`](deploy/lite/).
- **`make compose`** — per-service containers, each meeting bot spawned in its **own container**
  over the Docker socket — closer to a production shape, full per-bot isolation. See
  [`deploy/compose`](deploy/compose/).

Linux (Ubuntu 24.04) is the production target; a Mac with Docker Desktop works fine for local
evaluation. **Prerequisites** — `make`, Docker engine ≥ v26, and (for transcripts) either a free
token at [vexa.ai/account](https://vexa.ai/account) or the bundled local CPU whisper (see below).
Without transcription, bots still join and record — they just produce no text.

### Lite (single container)

```bash
git clone <this-repo> vexa-lite && cd vexa-lite
cp .env.example .env     # then set TRANSCRIPTION_SERVICE_URL/_TOKEN if you have a token
make lite                # provisions Postgres + MinIO, builds, runs, verifies
docker logs vexa-lite | grep VEXA_API_KEY    # grab your API key
```

No token, no GPU — `make -C deploy/lite up LOCAL_STT=1` runs a bundled faster-whisper CPU server
and auto-wires transcription: real transcripts, zero setup, slower than a GPU. See
[`deploy/lite/README.md`](deploy/lite/README.md).

### Compose (bot-per-container)

```bash
cd deploy/compose
cp .env.example .env     # then set TRANSCRIPTION_SERVICE_URL/_TOKEN if you have a token
make bot                 # build the meeting-bot image (one-time, or after bot changes)
make dev                 # build the 4 core services from this checkout + bring the stack up
```

See [`deploy/compose/README.md`](deploy/compose/README.md).

### Drive it over the API

```bash
export API_KEY=vxa_...
export API_BASE=http://localhost:8056

# send a bot into a live call
curl -X POST "$API_BASE/bots" \
  -H "X-API-Key: $API_KEY" -H "Content-Type: application/json" \
  -d '{"platform":"google_meet","native_meeting_id":"abc-defg-hij","bot_name":"Vexa"}'

# read the transcript as it streams
curl -H "X-API-Key: $API_KEY" "$API_BASE/transcripts/google_meet/abc-defg-hij"

# stop the bot
curl -X DELETE -H "X-API-Key: $API_KEY" "$API_BASE/bots/google_meet/abc-defg-hij"
```

`platform` is `google_meet` · `teams` · `zoom` · `jitsi`; `native_meeting_id` is the code from the
join URL.

---

## API reference

Base URL: `http://localhost:8056`, authenticated with `X-API-Key`.

| Method | Endpoint | Description |
|---|---|---|
| `POST` | `/bots` | Send a bot into a meeting (`platform`, `native_meeting_id`, `bot_name`, `language`, `task`) |
| `GET` | `/bots` · `/bots/status` | List running bots |
| `PUT` | `/bots/{platform}/{native_meeting_id}/config` | Change language/task mid-call |
| `POST` | `/bots/{platform}/{native_meeting_id}/speak` | TTS into the call |
| `DELETE` | `/bots/{platform}/{native_meeting_id}` | Stop / remove the bot |
| `GET` | `/transcripts/{platform}/{native_meeting_id}` | Fetch the real-time transcript (poll while live, or subscribe over `/ws`) |
| `GET` | `/meetings` · `/meetings/{id}` | List / fetch meetings |
| `PATCH` / `DELETE` | `/meetings/{id}` | Update / delete a meeting row |
| `GET` | `/recordings` · `/recordings/{id}` | List recordings; fetch one (→ MinIO-backed media) |
| `PUT` / `GET` | `/user/webhook` | Configure outbound webhooks (`meeting.*`, `bot.failed`, …) |
| `PUT` / `GET` | `/user/calendar` , `/user/calendar/sync` | Connect a calendar (ICS) so scheduled meetings auto-join |
| `PUT` / `GET` | `/user/transcription` | Per-user transcription config |
| `GET` | `/auth/me` | Caller identity from the API key |
| `WS` | `/ws` | Subscribe to live transcript / bot-status / chat frames for a meeting |

Full request/response shapes: `core/meetings/services/meeting-api/README.md` and the OpenAPI docs
at `/docs` on a running gateway.

---

## What's inside

The same four services, either bundled in one container ([`deploy/lite`](deploy/lite/)) or as
separate containers ([`deploy/compose`](deploy/compose/)):

| Service | Role |
|---|---|
| **gateway** | the one front door — API-key auth, scopes, routing, `/ws` fan-out |
| **admin-api** | identity — users, API keys, `/internal/validate` |
| **meeting-api** | bot spawn, lifecycle FSM, transcript collector, recordings, webhooks, calendar sync |
| **runtime** | the kernel — spawns the meeting bot (child process in lite, its own container in compose) |

The bot (TypeScript, Playwright) joins the call, captures audio, and streams it to an external
STT endpoint; `meeting-api` assembles the speaker-attributed transcript and exposes it over the
gateway.

## Repository layout

```
core/
  runtime/    kernel — spawn/execute workloads (process backend here)
  gateway/    the edge — auth · routing · WS fan-out
  identity/   admin-api — users/tokens/API keys
  meetings/   capture domain — meeting-api, the bot, and every capture module
                (gmeet/teams/zoom/jitsi, transcribe-whisper, recording, …)
deploy/
  lite/           single-container all-in-one deploy — bots as child processes
  compose/        per-service containers — each bot spawned in its own container
  transcription/  optional self-hosted GPU/CPU STT worker
```

This is derived from [Vexa](https://github.com/Vexa-ai/vexa)'s open-core monorepo, keeping
`core/runtime`, `core/gateway`, `core/identity`, and `core/meetings` verbatim, and dropping
`core/agent` (the chat/routines/sandboxed-coding-agent domain) and every client UI (terminal,
dashboard). Vexa's own `/api/*` agent-proxy route in the gateway is unmodified but unreachable
here — there's no agent-api to forward to.

## License

Apache-2.0 — see [LICENSE](LICENSE). Same license as upstream Vexa.

# deploy/lite/bin — lite container helper scripts

In-image scripts for the single-container [lite](../README.md) deployment. Copied to
`/usr/local/bin` (or invoked by supervisord) inside `vexa-lite:dev`.

| Script | Role |
|---|---|
| `vexa-bot-launch` | meeting-bot launcher the runtime execs per meeting via the **process backend** (`BOT_COMMAND`). Runs the bot worker against the container's shared Xvfb/PulseAudio. |
| `setup-pulseaudio-sinks.sh` | one-shot: builds the `tts_sink → virtual_mic` PulseAudio graph the bot's capture/speak path expects. |
| `provision-key.sh` | background (from the entrypoint): mints a self-host API key once admin-api is up and prints it to container stdout (there's no UI in this build to hand it to). No-op if `VEXA_API_KEY` is supplied. |

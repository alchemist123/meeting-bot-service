#!/bin/bash
# =============================================================================
# Bot Service Lite — self-host API key provisioner
# =============================================================================
# Runs in the background from the entrypoint. Once admin-api is up, mints (idempotently) a scoped
# API token for a self-host user and writes it to /run/bot-service/key.env, then prints it to container
# stdout. There is no UI in this build — `docker logs` (or reading /run/bot-service/key.env inside the
# container) is the only way to retrieve it.
#
# No-op when VEXA_API_KEY was supplied by the operator (their key wins).
set -u

if [ -n "${VEXA_API_KEY:-}" ]; then
    echo "[provision-key] VEXA_API_KEY provided by operator; skipping self-host mint"
    exit 0
fi

ADMIN="${ADMIN_API_TOKEN:-changeme}"
echo "[provision-key] waiting for admin-api..."
for _ in $(seq 1 60); do
    curl -sf -o /dev/null http://localhost:8001/health 2>/dev/null && break
    sleep 2
done

TOKS=$(ADMIN="$ADMIN" python3 - <<'PY'
import os, sys, json, urllib.request, urllib.error
admin = os.environ["ADMIN"]; B = "http://localhost:8001"
H = {"X-Admin-API-Key": admin, "Content-Type": "application/json"}
def call(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(B + path, data=data, method=method, headers=H)
    try:
        with urllib.request.urlopen(req, timeout=8) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()
    except Exception:
        return 0, ""
s, b = call("GET", "/admin/users/email/self-host@vexa.ai")
if s == 200:
    uid = json.loads(b)["id"]
else:
    s, b = call("POST", "/admin/users", {"email": "self-host@vexa.ai", "name": "self host"})
    uid = json.loads(b)["id"]
# dashboard key (bot,tx)
s, b = call("POST", f"/admin/users/{uid}/tokens?scopes=bot,tx")
d = json.loads(b)
sys.stdout.write("VEXA_API_KEY=" + (d.get("token") or d.get("api_token") or "") + "\n")
# bot api key (bot,tx)
s, b = call("POST", f"/admin/users/{uid}/tokens?scopes=bot,tx")
d = json.loads(b)
sys.stdout.write("VEXA_BOT_API_KEY=" + (d.get("token") or d.get("api_token") or "") + "\n")
PY
)

if [ -n "$TOKS" ]; then
    mkdir -p /run/bot-service
    printf '%s\n' "$TOKS" > /run/bot-service/key.env
    echo "=============================================="
    echo "  Bot Service Lite — self-host API key provisioned"
    echo "=============================================="
    printf '%s\n' "$TOKS"
    echo "=============================================="
else
    echo "[provision-key] WARN: could not mint keys — check admin-api logs"
fi

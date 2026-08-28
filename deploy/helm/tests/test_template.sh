#!/usr/bin/env bash
# Render the bot-service chart (no cluster required) and assert the carved control plane is present:
# 4 service Deployments + redis Deployment, postgres + minio StatefulSets, minio-init Job, runtime
# SA/Role/RoleBinding (k8s backend), redis PVC. This is the gate:helm static proof for this fork
# (no agent-api/terminal/dashboard — meetings-only, see repo README).
set -euo pipefail

HELM_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHART="$HELM_DIR/charts/bot-service"

if ! command -v helm >/dev/null 2>&1; then
  echo "SKIP: helm not installed"; exit 0
fi

RENDER="$(helm template bot-service "$CHART" -n bot-service -f "$CHART/values-test.yaml")"

fail=0
need() {  # need <count> <grep-pattern> <label>
  local want="$1" pat="$2" label="$3" got
  got="$(printf '%s\n' "$RENDER" | grep -cE "$pat" || true)"
  if [ "$got" -ge "$want" ]; then echo "  OK: $label ($got)"; else echo "  FAIL: $label — want >=$want got $got"; fail=1; fi
}

echo "=== gate:helm — template render assertions ==="
# 4 long-running services (gateway, admin-api, meeting-api, runtime) + redis = 5 Deployments
need 5 '^kind: Deployment'    "Deployments"
need 2 '^kind: StatefulSet'   "StatefulSets (postgres+minio)"
need 7 '^kind: Service$'      "Services (gateway, admin-api, meeting-api, runtime, redis, postgres, minio)"
need 1 '^kind: ServiceAccount' "runtime ServiceAccount"
need 1 '^kind: Role$'         "runtime Role"
need 1 '^kind: RoleBinding'   "runtime RoleBinding"
need 1 '^kind: Job'           "minio-init Job"
need 1 '^kind: PersistentVolumeClaim' "PVCs (redis-data)"
need 1 'RUNTIME_BACKEND'      "runtime backend env"
need 1 'serviceAccountName: bot-service-runtime' "runtime SA bound"
# Unlike upstream Vexa, this fork's meeting-api does not reference its own URL (matches
# deploy/compose/docker-compose.yml's meeting-api env block) — only the gateway routes to it.
need 1 'name: MEETING_API_URL' "MEETING_API_URL set on gateway"
# meeting-api MUST get ADMIN_API_URL or calendar sync no-ops and auto-join spawns uncapped. It
# rides the gateway env too; assert >=2 (gateway + meeting-api).
need 2 'name: ADMIN_API_URL'   "ADMIN_API_URL set on gateway AND meeting-api"
# The runtime (backend=k8s) MUST carry its own scheduling constraints as env, or every SPAWNED bot
# Pod (a bare `kubectl run` Pod, not a Deployment child) strands Pending on an all-tainted pool and
# the meeting silently fails. Durable seam-guard so a refactor can't drop it again.
need 1 'name: RUNTIME_K8S_TOLERATIONS'   "runtime carries spawn-Pod tolerations env"
need 1 'name: RUNTIME_K8S_NODE_SELECTOR' "runtime carries spawn-Pod nodeSelector env"

# No agent/terminal/dashboard/pgbouncer surface in this fork — assert the chart never renders it.
for absent in agent-api terminal dashboard pgbouncer; do
  if grep -q "app.kubernetes.io/component: $absent" <<< "$RENDER"; then
    echo "  FAIL: $absent rendered — this fork has no agent/copilot domain or web UI"; fail=1
  else
    echo "  OK: $absent absent (meetings-only fork)"
  fi
done

# #770-equivalent: pod topology spread. Empty default (values-test sets nothing) must render
# NOTHING — the field is optional, so a no-spread chart is byte-identical to a chart without it.
if grep -qE 'topologySpreadConstraints:' <<< "$RENDER"; then
  echo "  FAIL: topologySpreadConstraints rendered with empty default (should render nothing)"; fail=1
else
  echo "  OK: no topologySpreadConstraints when unset (empty default renders nothing)"
fi
# A global constraint must land on EVERY component Deployment with THAT component's own selector
# injected. 4 Deployments carry the field (gateway, admin-api, meeting-api, runtime) — redis opts
# out (Recreate strategy, single PVC, no rolling spread concern).
RENDER_TSC="$(helm template bot-service "$CHART" -n bot-service -f "$CHART/values-test.yaml" \
  --set-json 'global.topologySpreadConstraints=[{"maxSkew":1,"topologyKey":"kubernetes.io/hostname","whenUnsatisfiable":"ScheduleAnyway"}]')"
tsc_count="$(grep -cE '^      topologySpreadConstraints:' <<< "$RENDER_TSC" || true)"
if [ "$tsc_count" -ge 4 ]; then
  echo "  OK: global topologySpreadConstraints on all 4 component Deployments ($tsc_count)"
else
  echo "  FAIL: global topologySpreadConstraints — want >=4 Deployments got $tsc_count"; fail=1
fi
for comp in gateway meeting-api runtime; do
  if grep -A6 'topologySpreadConstraints:' <<< "$RENDER_TSC" | grep -qE "app.kubernetes.io/component: ${comp}\$"; then
    echo "  OK: topology spread injects ${comp}'s own selector"
  else
    echo "  FAIL: topology spread missing injected selector for ${comp}"; fail=1
  fi
done
# Per-component override wins over the global default.
RENDER_TSC_OV="$(helm template bot-service "$CHART" -n bot-service -f "$CHART/values-test.yaml" \
  --set-json 'global.topologySpreadConstraints=[{"maxSkew":1,"topologyKey":"kubernetes.io/hostname","whenUnsatisfiable":"ScheduleAnyway"}]' \
  --set-json 'gateway.topologySpreadConstraints=[{"maxSkew":2,"topologyKey":"topology.kubernetes.io/zone","whenUnsatisfiable":"DoNotSchedule"}]')"
gw_block="$(awk '/deployment-gateway.yaml/{f=1} f&&/topologySpreadConstraints:/{p=1} p{print} /^---/{if(p)exit}' <<< "$RENDER_TSC_OV")"
if grep -q 'topology.kubernetes.io/zone' <<< "$gw_block" && grep -q 'maxSkew: 2' <<< "$gw_block"; then
  echo "  OK: per-component topologySpreadConstraints override wins on gateway"
else
  echo "  FAIL: gateway per-component topologySpreadConstraints override did not win"; fail=1
fi

# Redis + runtime? No — only redis opts out of the shared zero-downtime RollingUpdate (single PVC,
# Recreate). The 4 API/kernel Deployments keep RollingUpdate.
roll_count="$(grep -cE '^    type: RollingUpdate' <<< "$RENDER" || true)"
if [ "$roll_count" -eq 4 ]; then
  echo "  OK: 4 non-PVC Deployments keep RollingUpdate (redis excepted)"
else
  echo "  FAIL: expected 4 RollingUpdate Deployments, got $roll_count"; fail=1
fi

[ "$fail" -eq 0 ] && { echo "gate:helm PASS"; exit 0; } || { echo "gate:helm FAIL"; exit 1; }

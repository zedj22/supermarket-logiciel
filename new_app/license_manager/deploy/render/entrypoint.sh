#!/usr/bin/env bash
# Process supervisor for the combined Render container (Phase 8.5).
#
#   Next.js dashboard  → 0.0.0.0:$PORT  (public)
#   FastAPI / uvicorn  → 127.0.0.1:8000 (loopback only)
#
# Guarantees:
#   * configuration is validated (fail-closed) BEFORE either process starts, so
#     a missing staging key file, signing seed or AES key crashes the deploy
#     instead of producing an instance that answers 503 on every issuance;
#   * uvicorn must answer /healthz before the dashboard is started, so the
#     public port accepts traffic only once the API is genuinely serving;
#   * if EITHER process exits for any reason, the container exits non-zero —
#     Render then replaces it rather than leaving a half-working instance;
#   * SIGTERM/SIGINT (Render's stop/redeploy signal) is forwarded to both
#     processes, which are then reaped: no orphan and no port left bound.
#
# bash is used for `wait -n` (POSIX sh has no "wait for the first of these").
set -uo pipefail

API_HOST="127.0.0.1"
API_PORT="8000"
PUBLIC_PORT="${PORT:-8080}"

api_pid=""
web_pid=""
stopping=0

log() {
    printf '%s entrypoint: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

shutdown() {
    # Ignore a second signal while the first is handled.
    trap - INT TERM
    stopping=1
    log "received a stop signal; shutting both processes down"
    if [[ -n "$web_pid" ]]; then kill -TERM "$web_pid" 2>/dev/null || true; fi
    if [[ -n "$api_pid" ]]; then kill -TERM "$api_pid" 2>/dev/null || true; fi
    wait 2>/dev/null || true
    log "shutdown complete"
    exit 0
}
trap shutdown INT TERM

# --------------------------------------------------------------------------- #
# 1. Fail-closed configuration check (no secret value is ever printed).
# --------------------------------------------------------------------------- #
log "validating configuration"
if ! python /app/license_manager/scripts/render_startup_check.py; then
    log "configuration validation failed; refusing to start"
    exit 1
fi

# --------------------------------------------------------------------------- #
# 2. FastAPI on loopback.
# --------------------------------------------------------------------------- #
cd /app/license_manager || exit 1
uvicorn service.api:app \
    --host "$API_HOST" \
    --port "$API_PORT" \
    --no-server-header \
    --timeout-graceful-shutdown 10 &
api_pid=$!

# --------------------------------------------------------------------------- #
# 3. Wait until the API answers /healthz (up to ~30 s).
# --------------------------------------------------------------------------- #
ready=0
for _ in $(seq 1 60); do
    if ! kill -0 "$api_pid" 2>/dev/null; then
        log "the API exited during startup"
        exit 1
    fi
    if python - "$API_HOST" "$API_PORT" <<'PY'
import json
import sys
import urllib.request

host, port = sys.argv[1], sys.argv[2]
try:
    with urllib.request.urlopen(f"http://{host}:{port}/healthz", timeout=2) as response:
        payload = json.load(response)
        status = response.status
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if status == 200 and payload.get("status") == "ok" else 1)
PY
    then
        ready=1
        break
    fi
    sleep 0.5
done

if [[ "$ready" != "1" ]]; then
    log "the API did not become ready within 30 seconds"
    kill -TERM "$api_pid" 2>/dev/null || true
    wait "$api_pid" 2>/dev/null || true
    exit 1
fi

# --------------------------------------------------------------------------- #
# 4. Dashboard on the public port.
# --------------------------------------------------------------------------- #
cd /app/dashboard || exit 1
PORT="$PUBLIC_PORT" HOSTNAME="0.0.0.0" node server.js &
web_pid=$!

log "dashboard on 0.0.0.0:$PUBLIC_PORT, API on $API_HOST:$API_PORT"

# --------------------------------------------------------------------------- #
# 5. Supervise: the first process to exit takes the container down.
# --------------------------------------------------------------------------- #
wait -n "$api_pid" "$web_pid"
status=$?

if [[ "$stopping" == "1" ]]; then
    exit 0
fi

log "a supervised process exited (status $status); stopping the container"
kill -TERM "$web_pid" "$api_pid" 2>/dev/null || true
wait 2>/dev/null || true

# Always non-zero: a healthy container does not lose a process.
if [[ "$status" -eq 0 ]]; then
    exit 1
fi
exit "$status"

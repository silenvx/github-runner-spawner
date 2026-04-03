#!/bin/bash
set -euo pipefail

: "${REPO_URL:?REPO_URL is required}"
: "${RUNNER_TOKEN:?RUNNER_TOKEN is required}"
: "${RUNNER_NAME:=ephemeral-runner-$$}"
: "${RUNNER_LABELS:=self-hosted,linux,arm64,ephemeral}"

MAX_REGISTER_ATTEMPTS=5
REGISTER_RETRY_BASE_DELAY=10

log() {
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $*"
}

cd /home/runner

# Fix ownership of volume mount points (may be root-owned on first creation)
for dir in /home/runner/.npm /home/runner/pw-browsers; do
    if [ -d "$dir" ] && [ "$(stat -c '%u' "$dir" 2>/dev/null)" != "$(id -u)" ]; then
        if ! sudo chown -R runner:runner "$dir"; then
            log "WARNING: Failed to fix ownership of $dir"
        fi
    fi
done

cleanup() {
    log "Cleanup triggered (EXIT trap)"
    if [ -f ".runner" ] && [ -f ".credentials" ]; then
        log "Config files exist, removing runner from server..."
        if ./config.sh remove --unattended --token "${RUNNER_TOKEN}" 2>/dev/null; then
            log "Runner removed from server"
        else
            log "WARNING: Failed to remove runner from server (token may be expired)"
        fi
    else
        log "Config files already removed (ephemeral cleanup or registration failure), skipping server removal"
    fi
}
trap cleanup EXIT INT TERM

log "Starting runner registration: name=${RUNNER_NAME} url=${REPO_URL}"

for attempt in $(seq 1 "$MAX_REGISTER_ATTEMPTS"); do
    log "Registration attempt ${attempt}/${MAX_REGISTER_ATTEMPTS}"
    if ./config.sh \
        --url "${REPO_URL}" \
        --token "${RUNNER_TOKEN}" \
        --name "${RUNNER_NAME}" \
        --labels "${RUNNER_LABELS}" \
        --work "_work" \
        --unattended \
        --replace \
        --ephemeral; then
        log "Registration succeeded"
        break
    fi

    if [ "$attempt" -eq "$MAX_REGISTER_ATTEMPTS" ]; then
        log "ERROR: Registration failed after ${MAX_REGISTER_ATTEMPTS} attempts, giving up"
        exit 1
    fi

    delay=$(( REGISTER_RETRY_BASE_DELAY * attempt ))
    log "Registration failed, retrying in ${delay}s..."
    sleep "$delay"
done

log "Starting runner listener"
set +e
./run.sh
exit_code=$?
set -e
log "Runner listener exited with code ${exit_code}"
exit "${exit_code}"

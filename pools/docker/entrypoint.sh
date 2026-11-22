#!/bin/bash
set -euo pipefail

log() {
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $*"
}

cd /home/runner

# Fix ownership of volume mount points (may be root-owned on first creation)
# Checks files inside too — the parent may be runner-owned while internal files remain root-owned
for dir in /home/runner/.npm /home/runner/pw-browsers /home/runner/.local/state/run_hook_tests; do
    if [ -d "$dir" ] && [ -n "$(sudo find "$dir" ! -user runner -print -quit 2>/dev/null)" ]; then
        if ! sudo chown -R runner:runner "$dir"; then
            log "WARNING: Failed to fix ownership of $dir"
        fi
    fi
done

# Purge npm cache to prevent EACCES hangs from root-owned artifacts
# (workflows use NPM_CONFIG_CACHE for workspace-local cache, so this has no performance impact)
if [ -d /home/runner/.npm/_cacache ]; then
    if sudo rm -rf /home/runner/.npm/_cacache; then
        log "Purged ~/.npm/_cacache"
    else
        log "WARNING: Failed to purge ~/.npm/_cacache"
    fi
fi

# The JIT config is a credential: stdin keeps it out of `docker inspect` and process arguments.
# The runner masks ACTIONS_RUNNER_INPUT_JITCONFIG in its logs and removes it from the job environment.
jitconfig=""
IFS= read -r jitconfig || true
if [ -z "$jitconfig" ]; then
    log "ERROR: no JIT config on stdin"
    exit 1
fi
export ACTIONS_RUNNER_INPUT_JITCONFIG="$jitconfig"
unset jitconfig

log "Starting runner"
exec ./run.sh

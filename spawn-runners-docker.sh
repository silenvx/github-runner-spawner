#!/bin/bash

# Docker Ephemeral GitHub Actions Runner Spawner
# Usage: ./spawn-runners-docker.sh <repo> <count>
#
# Each runner executes exactly one job then is destroyed and respawned.
# Multiple runners can handle concurrent jobs.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE_NAME="gh-runner"
LABEL="self-hosted,linux,arm64,ephemeral"

# Parse repository argument
parse_repo() {
    local input="$1"
    input="${input%/}"
    input="${input%.git}"

    if [[ "$input" =~ ^https?://github\.com/([^/]+)/([^/]+) ]]; then
        echo "${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    else
        echo "$input" | cut -d'/' -f1,2
    fi
}

usage() {
    echo "Usage: $0 <repo> <count>"
    echo ""
    echo "  repo   - owner/repo or https://github.com/owner/repo"
    echo "  count  - Number of runners to spawn (run concurrently)"
    echo ""
    echo "Example:"
    echo "  $0 owner/repo 3"
    echo ""
    echo "Press Ctrl+C to stop and cleanup all containers."
    exit 1
}

if [ $# -lt 2 ]; then
    usage
fi

REPO=$(parse_repo "$1")
COUNT="$2"

if [[ ! "$REPO" =~ ^[^/]+/[^/]+$ ]]; then
    echo "Error: Invalid repository format. Use owner/repo"
    exit 1
fi

if ! [[ "$COUNT" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: count must be a positive integer"
    exit 1
fi

REPO_NAME=$(echo "$REPO" | cut -d'/' -f2)
REPO_URL="https://github.com/$REPO"

# Check dependencies
if ! command -v docker &> /dev/null; then
    echo "Error: docker is not installed"
    exit 1
fi

if ! command -v gh &> /dev/null; then
    echo "Error: gh CLI is not installed"
    exit 1
fi

if ! gh auth status &> /dev/null; then
    echo "Error: gh CLI is not authenticated. Run: gh auth login"
    exit 1
fi

# Generate short prefix for container naming
PREFIX=$(head -c 4 /dev/urandom | xxd -p | cut -c1-8)

echo "=== Docker Ephemeral Runner Spawner ==="
echo "Repository: $REPO"
echo "Count:      $COUNT"
echo "Prefix:     $PREFIX"
echo "Image:      $IMAGE_NAME"
echo ""

# Fetch latest runner version
RUNNER_VERSION=$(gh api /repos/actions/runner/releases/latest --jq '.tag_name' 2>/dev/null | sed 's/^v//')
if [ -z "$RUNNER_VERSION" ]; then
    echo "Error: Failed to fetch latest runner version"
    exit 1
fi
echo "Runner version: v$RUNNER_VERSION"

CURRENT_RUNNER_VERSION="$RUNNER_VERSION"

LOCK_DIR="/tmp/${IMAGE_NAME}-build.lock"

# Build image if not already built for this version
build_image() {
    local tag="${IMAGE_NAME}:${CURRENT_RUNNER_VERSION}"
    if docker image inspect "$tag" &>/dev/null; then
        echo "Image $tag already exists, skipping build."
        return
    fi

    # Acquire lock (mkdir is atomic)
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        echo "Another build in progress, waiting..."
        sleep 5
    done
    trap 'rmdir "$LOCK_DIR" 2>/dev/null; cleanup' SIGINT SIGTERM

    # Re-check after acquiring lock
    if docker image inspect "$tag" &>/dev/null; then
        echo "Image $tag already built by another process, skipping."
    else
        echo "Building runner image (v$CURRENT_RUNNER_VERSION)..."
        docker build --build-arg RUNNER_VERSION="$CURRENT_RUNNER_VERSION" -t "$tag" "$SCRIPT_DIR/docker/"
    fi

    rmdir "$LOCK_DIR"
    trap cleanup SIGINT SIGTERM
}

build_image
echo ""

# Get a fresh registration token
get_token() {
    gh api --method POST "/repos/$REPO/actions/runners/registration-token" --jq '.token' 2>/dev/null
}

# Container name for runner N
container_name() {
    echo "${PREFIX}-${REPO_NAME}-runner-$1"
}

# Start a single runner container
start_runner() {
    local n="$1"
    local name
    name=$(container_name "$n")

    local token
    token=$(get_token)
    if [ -z "$token" ]; then
        echo "[$name] Error: Failed to get registration token"
        return 1
    fi

    # Remove leftover container with same name
    docker rm -f "$name" 2>/dev/null || true

    docker run -d \
        --name "$name" \
        -e REPO_URL="$REPO_URL" \
        -e RUNNER_TOKEN="$token" \
        -e RUNNER_NAME="$name" \
        -e RUNNER_LABELS="$LABEL" \
        "${IMAGE_NAME}:${CURRENT_RUNNER_VERSION}" > /dev/null

    echo "[$name] Started"
}

# Cleanup all containers
cleanup() {
    echo ""
    echo "=== Cleaning up ==="
    for i in $(seq 1 "$COUNT"); do
        local name
        name=$(container_name "$i")
        echo "Stopping $name..."
        docker stop "$name" 2>/dev/null || true
        docker rm -f "$name" 2>/dev/null || true
    done
    # Kill background processes
    kill $(jobs -p) 2>/dev/null || true
    echo "Cleanup complete."
    exit 0
}

trap cleanup SIGINT SIGTERM

# Start all runners
echo "Starting $COUNT runner(s)..."
for i in $(seq 1 "$COUNT"); do
    start_runner "$i"
done
echo ""

# Stream logs from all containers
for i in $(seq 1 "$COUNT"); do
    name=$(container_name "$i")
    docker logs -f "$name" 2>/dev/null | sed "s|^|[$name] |" &
done

echo "=== Watching runners (Ctrl+C to stop) ==="
echo ""

# Check for runner version updates and rebuild if needed
VERSION_CHECK_INTERVAL=300
LAST_VERSION_CHECK=$(date +%s)

check_version_update() {
    local now
    now=$(date +%s)
    local elapsed=$((now - LAST_VERSION_CHECK))
    if [ "$elapsed" -lt "$VERSION_CHECK_INTERVAL" ]; then
        return 1
    fi
    LAST_VERSION_CHECK=$now

    local latest
    latest=$(gh api /repos/actions/runner/releases/latest --jq '.tag_name' 2>/dev/null | sed 's/^v//')
    if [ -z "$latest" ]; then
        return 1
    fi
    if [ "$latest" = "$CURRENT_RUNNER_VERSION" ]; then
        return 1
    fi

    echo ""
    echo "=== Runner version updated: v$CURRENT_RUNNER_VERSION -> v$latest ==="
    CURRENT_RUNNER_VERSION="$latest"
    build_image
    echo ""
    return 0
}

# Monitor loop: respawn containers that exit (job completed)
while true; do
    sleep 5

    # Rebuild image if version changed; running containers finish naturally
    # and will be respawned with the new image below
    check_version_update

    for i in $(seq 1 "$COUNT"); do
        name=$(container_name "$i")
        if ! docker ps -q -f "name=^${name}$" 2>/dev/null | grep -q .; then
            # Container exited — respawn with fresh token
            echo ""
            echo "[$name] Job finished. Respawning..."
            start_runner "$i"
            docker logs -f "$name" 2>/dev/null | sed "s|^|[$name] |" &
        fi
    done
done

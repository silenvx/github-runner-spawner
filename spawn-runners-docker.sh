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

# Build image if needed
echo "Building runner image..."
docker build -t "$IMAGE_NAME" "$SCRIPT_DIR/docker/"
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
        "$IMAGE_NAME" > /dev/null

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

# Monitor loop: respawn containers that exit (job completed)
while true; do
    sleep 5
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

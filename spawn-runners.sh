#!/bin/bash

# GitHub Actions Self-hosted Runner Spawner
# Usage: ./spawn-runners.sh <repo> <count>

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$SCRIPT_DIR/.runners"
CACHE_DIR="$BASE_DIR/.cache"

# Detect platform
detect_platform() {
    local os arch
    case "$(uname -s)" in
        Darwin) os="osx" ;;
        Linux)  os="linux" ;;
        *)      echo "Error: Unsupported OS: $(uname -s)"; exit 1 ;;
    esac

    case "$(uname -m)" in
        x86_64)  arch="x64" ;;
        arm64|aarch64) arch="arm64" ;;
        *)       echo "Error: Unsupported architecture: $(uname -m)"; exit 1 ;;
    esac

    echo "${os}-${arch}"
}

# Get latest runner version and download URL
get_runner_info() {
    local platform="$1"
    local os="${platform%-*}"
    local arch="${platform#*-}"

    local release_info
    release_info=$(gh api /repos/actions/runner/releases/latest)

    local version
    version=$(echo "$release_info" | jq -r '.tag_name' | sed 's/^v//')

    local download_url
    download_url=$(echo "$release_info" | jq -r ".assets[] | select(.name | contains(\"${os}-${arch}\")) | .browser_download_url" | head -1)

    echo "$version|$download_url"
}

# Parse repository argument (extract owner/repo only)
parse_repo() {
    local input="$1"
    input="${input%/}"
    input="${input%.git}"

    if [[ "$input" =~ ^https?://github\.com/([^/]+)/([^/]+) ]]; then
        echo "${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    else
        # For owner/repo format, take first two components
        echo "$input" | cut -d'/' -f1,2
    fi
}

# Show usage
usage() {
    echo "Usage: $0 <repo> <count>"
    echo ""
    echo "  repo   - owner/repo or https://github.com/owner/repo"
    echo "  count  - Number of runners to spawn"
    echo ""
    echo "Example:"
    echo "  $0 owner/repo 5"
    echo ""
    echo "Press Ctrl+C to stop and cleanup."
    exit 1
}

# Validate arguments
if [ $# -lt 2 ]; then
    usage
fi

REPO=$(parse_repo "$1")
COUNT="$2"

# Validate repo format
if [[ ! "$REPO" =~ ^[^/]+/[^/]+$ ]]; then
    echo "Error: Invalid repository format. Use owner/repo"
    exit 1
fi

# Validate count
if ! [[ "$COUNT" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: count must be a positive integer (1 or more)"
    exit 1
fi

REPO_NAME=$(echo "$REPO" | cut -d'/' -f2)
RUNNERS_DIR="$BASE_DIR/$REPO"
URL="https://github.com/$REPO"
PLATFORM=$(detect_platform)

# Generate or load machine-specific prefix
PREFIX_FILE="$BASE_DIR/.prefix"
if [ -n "$RUNNER_PREFIX" ]; then
    PREFIX="$RUNNER_PREFIX"
elif [ -f "$PREFIX_FILE" ]; then
    PREFIX=$(cat "$PREFIX_FILE")
else
    mkdir -p "$BASE_DIR"
    PREFIX=$(head -c 4 /dev/urandom | xxd -p)
    echo "$PREFIX" > "$PREFIX_FILE"
fi

echo "=== GitHub Runner Spawner ==="
echo "Repository: $REPO"
echo "Platform:   $PLATFORM"
echo "Count:      $COUNT"
echo "Prefix:     $PREFIX"
echo "Directory:  $RUNNERS_DIR"
echo ""

# Check dependencies
for cmd in gh jq curl tar; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: $cmd is not installed"
        exit 1
    fi
done

if ! gh auth status &> /dev/null; then
    echo "Error: gh CLI is not authenticated. Run: gh auth login"
    exit 1
fi

# Get registration token
echo "Fetching registration token..."
TOKEN=$(gh api --method POST "/repos/$REPO/actions/runners/registration-token" --jq '.token' 2>/dev/null)

if [ -z "$TOKEN" ]; then
    echo "Error: Failed to get token. Check repository admin access."
    exit 1
fi

# Stop all existing runners for this repo
echo "Stopping existing runners..."
pkill -f "$RUNNERS_DIR/.*/bin/Runner.Listener" 2>/dev/null || true
sleep 1

# Get runner version
echo "Fetching latest runner version..."
RUNNER_INFO=$(get_runner_info "$PLATFORM")
RUNNER_VERSION=$(echo "$RUNNER_INFO" | cut -d'|' -f1)
DOWNLOAD_URL=$(echo "$RUNNER_INFO" | cut -d'|' -f2)
TARBALL="actions-runner-${PLATFORM}-${RUNNER_VERSION}.tar.gz"
echo "Version: $RUNNER_VERSION"
echo ""

# Download runner package (with cache, using temp file)
mkdir -p "$CACHE_DIR"
CACHE_FILE="$CACHE_DIR/$TARBALL"

if [ ! -f "$CACHE_FILE" ]; then
    echo "Downloading runner package..."
    TEMP_FILE="$CACHE_FILE.tmp"
    if curl -L -o "$TEMP_FILE" "$DOWNLOAD_URL"; then
        mv "$TEMP_FILE" "$CACHE_FILE"
    else
        rm -f "$TEMP_FILE"
        echo "Error: Download failed"
        exit 1
    fi
else
    echo "Using cached package"
fi
echo ""

# Create repo directory
mkdir -p "$RUNNERS_DIR"

# Remove extra runner directories (beyond COUNT)
for dir in "$RUNNERS_DIR"/runner-*; do
    if [ -d "$dir" ]; then
        NUM=$(basename "$dir" | sed 's/runner-//')
        if [ "$NUM" -gt "$COUNT" ] 2>/dev/null; then
            echo "Removing runner-$NUM..."
            if [ -f "$dir/.runner" ]; then
                (cd "$dir" && ./config.sh remove --token "$TOKEN" 2>/dev/null) || true
            fi
            rm -rf "$dir"
        fi
    fi
done

# Setup runners
for i in $(seq 1 "$COUNT"); do
    RUNNER_DIR="$RUNNERS_DIR/runner-$i"
    echo "=== Setting up runner-$i ==="

    # Clean existing
    if [ -d "$RUNNER_DIR" ]; then
        if [ -f "$RUNNER_DIR/.runner" ]; then
            (cd "$RUNNER_DIR" && ./config.sh remove --token "$TOKEN" 2>/dev/null) || true
        fi
        rm -rf "$RUNNER_DIR"
    fi

    mkdir -p "$RUNNER_DIR"
    tar xzf "$CACHE_FILE" -C "$RUNNER_DIR"

    cd "$RUNNER_DIR"
    ./config.sh --url "$URL" --token "$TOKEN" --name "${PREFIX}-${REPO_NAME}-runner-$i" --unattended --replace

    nohup ./run.sh > runner.log 2>&1 &
    echo "Started (PID: $!)"
    echo ""
done

echo "=== Done ==="
echo "Spawned $COUNT runner(s) for $REPO"
echo ""
echo "Watching logs... (Ctrl+C to stop and cleanup)"
echo ""

# Cleanup function
cleanup() {
    echo ""
    echo ""
    echo "=== Cleaning up ==="

    # Stop runners
    echo "Stopping runners..."
    pkill -f "$RUNNERS_DIR/.*/bin/Runner.Listener" 2>/dev/null || true
    sleep 1

    # Get new token for removal
    echo "Fetching token for removal..."
    REMOVE_TOKEN=$(gh api --method POST "/repos/$REPO/actions/runners/registration-token" --jq '.token' 2>/dev/null)

    # Remove from GitHub and delete directories
    for dir in "$RUNNERS_DIR"/runner-*; do
        if [ -d "$dir" ]; then
            NAME=$(basename "$dir")
            echo "Removing $NAME..."
            if [ -f "$dir/.runner" ] && [ -n "$REMOVE_TOKEN" ]; then
                (cd "$dir" && ./config.sh remove --token "$REMOVE_TOKEN" 2>/dev/null) || true
            fi
            rm -rf "$dir"
        fi
    done

    # Remove repo directory if empty
    rmdir "$RUNNERS_DIR" 2>/dev/null || true
    rmdir "$(dirname "$RUNNERS_DIR")" 2>/dev/null || true

    echo "Cleanup complete."
    exit 0
}

trap cleanup SIGINT SIGTERM

# Tail all runner logs with clean prefix
for dir in "$RUNNERS_DIR"/runner-*; do
    num=$(basename "$dir" | sed 's/runner-//')
    runner_name="${PREFIX}-${REPO_NAME}-runner-${num}"
    tail -f "$dir/runner.log" 2>/dev/null | sed "s|^|[$runner_name] |" &
done
wait

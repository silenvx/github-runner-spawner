#!/bin/bash

# GitHub Actions Offline Runner Cleanup
# Removes offline runners from GitHub and optionally cleans up cache volumes
# Usage: ./cleanup-runners.sh [--volumes] <repo>

set -e

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

CLEANUP_VOLUMES=false

# Parse flags
while [[ "$1" == --* ]]; do
    case "$1" in
        --volumes) CLEANUP_VOLUMES=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ $# -lt 1 ]; then
    echo "Usage: $0 [--volumes] <repo>"
    echo ""
    echo "  repo      - owner/repo or https://github.com/owner/repo"
    echo "  --volumes - Also remove cache volumes (npm, Playwright)"
    echo ""
    echo "Example:"
    echo "  $0 owner/repo"
    echo "  $0 --volumes owner/repo"
    exit 1
fi

REPO=$(parse_repo "$1")

# Validate repo format
if [[ ! "$REPO" =~ ^[^/]+/[^/]+$ ]]; then
    echo "Error: Invalid repository format. Use owner/repo"
    exit 1
fi

REPO_SLUG=$(echo "$REPO" | tr '/' '-')

echo "=== Cleanup Offline Runners ==="
echo "Repository: $REPO"
echo ""

# Check gh auth
if ! gh auth status &> /dev/null; then
    echo "Error: gh CLI is not authenticated. Run: gh auth login"
    exit 1
fi

# Get offline runners (include busy status)
if ! OFFLINE_RUNNERS=$(gh api --paginate "/repos/$REPO/actions/runners?per_page=100" \
    --jq '.runners[] | select(.status == "offline") | "\(.id)|\(.name)|\(.busy)"'); then
    echo "Error: Failed to fetch runners for $REPO." >&2
    exit 1
fi

if [ -z "$OFFLINE_RUNNERS" ]; then
    echo "No offline runners found."
else
    # Separate idle and busy runners
    IDLE_RUNNERS=""
    BUSY_RUNNERS=""
    while IFS='|' read -r id name busy; do
        if [ "$busy" = "true" ]; then
            BUSY_RUNNERS="${BUSY_RUNNERS}${id}|${name}"$'\n'
        else
            IDLE_RUNNERS="${IDLE_RUNNERS}${id}|${name}"$'\n'
        fi
    done <<< "$OFFLINE_RUNNERS"
    IDLE_RUNNERS="${IDLE_RUNNERS%$'\n'}"
    BUSY_RUNNERS="${BUSY_RUNNERS%$'\n'}"

    # Handle idle runners
    if [ -n "$IDLE_RUNNERS" ]; then
        echo "Found offline runners:"
        while IFS='|' read -r id name; do
            echo "  - $name (ID: $id)"
        done <<< "$IDLE_RUNNERS"
        echo ""

        read -p "Remove these runners from GitHub? [y/N] " -n 1 -r
        echo ""

        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo ""
            echo "Removing..."
            while IFS='|' read -r id name; do
                echo "  Removing $name..."
                gh api --method DELETE "/repos/$REPO/actions/runners/$id" 2>/dev/null \
                    || echo "    Failed to remove $name"
            done <<< "$IDLE_RUNNERS"
            echo ""
        else
            echo "Skipped runner removal."
            echo ""
        fi
    fi

    # Handle busy runners (offline but marked as running a job = likely hung)
    if [ -n "$BUSY_RUNNERS" ]; then
        echo "Found offline runners stuck in busy state (likely hung):"
        while IFS='|' read -r id name; do
            echo "  - $name (ID: $id)"
        done <<< "$BUSY_RUNNERS"
        echo ""
        echo "These runners are offline but GitHub thinks they are running a job."
        echo "Their associated workflow runs must be cancelled before removal."
        echo ""

        while IFS= read -r -t 0 -n 1 _ 2>/dev/null; do :; done
        read -p "Cancel associated runs and remove these runners? [y/N] " -n 1 -r
        echo ""

        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo ""

            # Build runner ID set for lookup
            BUSY_IDS=""
            while IFS='|' read -r id name; do
                BUSY_IDS="${BUSY_IDS} ${id} "
            done <<< "$BUSY_RUNNERS"

            # Find and cancel workflow runs on these runners
            echo "Cancelling associated workflow runs..."
            IN_PROGRESS_RUNS=$(gh api --paginate "/repos/$REPO/actions/runs?status=in_progress&per_page=100" \
                --jq '.workflow_runs[].id' 2>/dev/null)

            if [ -n "$IN_PROGRESS_RUNS" ]; then
                while read -r run_id; do
                    # Check if any job in this run is assigned to a busy runner
                    MATCHED_RUNNER=$(gh api --paginate "/repos/$REPO/actions/runs/$run_id/jobs?filter=latest&per_page=100" \
                        --jq "[.jobs[] | select(.status == \"in_progress\" and .runner_id != null) | .runner_id] | .[]" 2>/dev/null)

                    for runner_id in $MATCHED_RUNNER; do
                        if [[ "$BUSY_IDS" == *" ${runner_id} "* ]]; then
                            echo "  Cancelling run $run_id..."
                            gh api --method POST \
                                "/repos/$REPO/actions/runs/$run_id/cancel" 2>/dev/null \
                                || echo "    Failed to cancel run $run_id"
                            break
                        fi
                    done
                done <<< "$IN_PROGRESS_RUNS"
            fi

            # Wait for cancellation to propagate
            echo "  Waiting for cancellations to propagate..."
            sleep 3

            # Now remove the runners
            echo "Removing runners..."
            while IFS='|' read -r id name; do
                echo "  Removing $name..."
                gh api --method DELETE "/repos/$REPO/actions/runners/$id" 2>/dev/null \
                    || echo "    Failed to remove $name (run may still be cancelling, retry later)"
            done <<< "$BUSY_RUNNERS"
            echo ""
        else
            echo "Skipped busy runner removal."
            echo ""
        fi
    fi
fi

# Volume cleanup
if [ "$CLEANUP_VOLUMES" = true ]; then
    if ! command -v docker &> /dev/null; then
        echo "Error: docker is not installed (required for --volumes)"
        exit 1
    fi

    echo "=== Cleanup Cache Volumes ==="
    echo ""

    NPM_VOL="gh-runner-${REPO_SLUG}-npm-cache"
    PW_VOL="gh-runner-${REPO_SLUG}-playwright"

    found_volumes=()
    for vol in "$NPM_VOL" "$PW_VOL"; do
        if docker volume inspect "$vol" &>/dev/null; then
            size=$(docker system df -v 2>/dev/null | grep "^$vol " | awk '{print $3 $4}')
            found_volumes+=("$vol")
            echo "  $vol (${size:-size unknown})"
        fi
    done

    if [ ${#found_volumes[@]} -eq 0 ]; then
        echo "No cache volumes found for $REPO."
    else
        echo ""
        while IFS= read -r -t 0 -n 1 _ 2>/dev/null; do :; done
        read -p "Remove these volumes? [y/N] " -n 1 -r
        echo ""

        if [[ $REPLY =~ ^[Yy]$ ]]; then
            for vol in "${found_volumes[@]}"; do
                echo "  Removing $vol..."
                docker volume rm "$vol" 2>/dev/null || echo "    Failed (volume may be in use)"
            done
        else
            echo "Skipped volume removal."
        fi
    fi
    echo ""
fi

echo "Done."

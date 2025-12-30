#!/bin/bash

# GitHub Actions Self-hosted Runner Status Checker
# Usage: ./status-runners.sh [repo]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$SCRIPT_DIR/.runners"

echo "=== GitHub Runner Status ==="
echo ""

if [ ! -d "$BASE_DIR" ]; then
    echo "No runners directory found."
    exit 0
fi

# Parse optional repo argument
FILTER_REPO=""
if [ -n "$1" ]; then
    FILTER_REPO=$(echo "$1" | sed 's|https://github.com/||' | sed 's|/$||')
fi

# Function to show runners for a repo
show_repo_status() {
    local repo_dir="$1"
    local repo="$2"

    # Check if any runners exist
    if ! ls "$repo_dir"/runner-* &>/dev/null; then
        return
    fi

    # Count runners
    local count=$(ls -d "$repo_dir"/runner-* 2>/dev/null | wc -l | tr -d ' ')

    # Get runner status from GitHub API
    GITHUB_DATA=$(gh api "/repos/$repo/actions/runners" 2>/dev/null)

    # Count online runners
    local online=$(echo "$GITHUB_DATA" | jq '[.runners[] | select(.status == "online")] | length' 2>/dev/null || echo "?")

    echo "Repository: $repo ($online/$count online)"
    echo ""

    printf "  %-30s %-10s %-6s %-8s %s\n" "NAME" "STATUS" "BUSY" "PID" "LABELS"
    printf "  %-30s %-10s %-6s %-8s %s\n" "----" "------" "----" "---" "------"

    for dir in "$repo_dir"/runner-*; do
        if [ -d "$dir" ] && [ -f "$dir/.runner" ]; then
            NAME=$(grep -o '"agentName": *"[^"]*"' "$dir/.runner" | sed 's/.*: *"\([^"]*\)"/\1/')

            # Get PID
            PID=$(pgrep -f "$dir/bin/Runner.Listener" 2>/dev/null || echo "-")

            # Get GitHub status
            STATUS="?"
            BUSY="?"
            LABELS="-"
            if [ -n "$GITHUB_DATA" ]; then
                RUNNER_INFO=$(echo "$GITHUB_DATA" | jq -r ".runners[] | select(.name == \"$NAME\")")
                if [ -n "$RUNNER_INFO" ]; then
                    STATUS=$(echo "$RUNNER_INFO" | jq -r '.status')
                    BUSY_VAL=$(echo "$RUNNER_INFO" | jq -r '.busy')
                    if [ "$BUSY_VAL" = "true" ]; then
                        BUSY="yes"
                    else
                        BUSY="no"
                    fi
                    LABELS=$(echo "$RUNNER_INFO" | jq -r '[.labels[].name] | join(", ")')
                fi
            fi

            printf "  %-30s %-10s %-6s %-8s %s\n" "$NAME" "$STATUS" "$BUSY" "$PID" "$LABELS"
        fi
    done

    echo ""
}

# Find all repos (owner/repo structure)
found=false
for owner_dir in "$BASE_DIR"/*/; do
    owner_dir="${owner_dir%/}"
    owner=$(basename "$owner_dir")

    # Skip .cache
    if [ "$owner" = ".cache" ]; then
        continue
    fi

    for repo_dir in "$owner_dir"/*/; do
        repo_dir="${repo_dir%/}"
        repo_name=$(basename "$repo_dir")
        repo="$owner/$repo_name"

        # Filter by repo if specified
        if [ -n "$FILTER_REPO" ] && [ "$repo" != "$FILTER_REPO" ]; then
            continue
        fi

        if [ -d "$repo_dir" ]; then
            show_repo_status "$repo_dir" "$repo"
            found=true
        fi
    done
done

if [ "$found" = false ]; then
    if [ -n "$FILTER_REPO" ]; then
        echo "No runners found for specified repository."
    else
        echo "No runners found."
    fi
fi

echo "Commands:"
echo "  ./spawn-runners.sh <repo> <count>  - Spawn runners (Ctrl+C to stop)"
echo "  ./cleanup-runners.sh <repo>        - Remove offline runners"

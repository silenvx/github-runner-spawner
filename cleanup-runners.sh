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

# Get offline runners
OFFLINE_RUNNERS=$(gh api "/repos/$REPO/actions/runners" --jq '.runners[] | select(.status == "offline") | "\(.id)|\(.name)"' 2>/dev/null)

if [ -z "$OFFLINE_RUNNERS" ]; then
    echo "No offline runners found."
else
    echo "Found offline runners:"
    echo "$OFFLINE_RUNNERS" | while IFS='|' read -r id name; do
        echo "  - $name (ID: $id)"
    done
    echo ""

    # Confirm
    read -p "Remove these runners from GitHub? [y/N] " -n 1 -r
    echo ""

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo ""
        echo "Removing..."

        echo "$OFFLINE_RUNNERS" | while IFS='|' read -r id name; do
            echo "  Removing $name..."
            gh api --method DELETE "/repos/$REPO/actions/runners/$id" 2>/dev/null || echo "    Failed to remove $name"
        done
        echo ""
    else
        echo "Skipped runner removal."
        echo ""
    fi
fi

# Volume cleanup
if [ "$CLEANUP_VOLUMES" = true ]; then
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

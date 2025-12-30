#!/bin/bash

# GitHub Actions Offline Runner Cleanup
# Removes offline runners from GitHub
# Usage: ./cleanup-runners.sh <repo>

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

if [ $# -lt 1 ]; then
    echo "Usage: $0 <repo>"
    echo ""
    echo "  repo - owner/repo or https://github.com/owner/repo"
    echo ""
    echo "Example:"
    echo "  $0 owner/repo"
    exit 1
fi

REPO=$(parse_repo "$1")

# Validate repo format
if [[ ! "$REPO" =~ ^[^/]+/[^/]+$ ]]; then
    echo "Error: Invalid repository format. Use owner/repo"
    exit 1
fi

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
    exit 0
fi

echo "Found offline runners:"
echo "$OFFLINE_RUNNERS" | while IFS='|' read -r id name; do
    echo "  - $name (ID: $id)"
done
echo ""

# Confirm
read -p "Remove these runners from GitHub? [y/N] " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

echo ""
echo "Removing..."

echo "$OFFLINE_RUNNERS" | while IFS='|' read -r id name; do
    echo "  Removing $name..."
    gh api --method DELETE "/repos/$REPO/actions/runners/$id" 2>/dev/null || echo "    Failed to remove $name"
done

echo ""
echo "Done."

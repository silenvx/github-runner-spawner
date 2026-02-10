#!/bin/bash
set -euo pipefail

: "${REPO_URL:?REPO_URL is required}"
: "${RUNNER_TOKEN:?RUNNER_TOKEN is required}"
: "${RUNNER_NAME:=ephemeral-runner-$$}"
: "${RUNNER_LABELS:=self-hosted,linux,arm64,ephemeral}"

cd /home/runner

cleanup() {
    ./config.sh remove --unattended --token "${RUNNER_TOKEN}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

./config.sh \
    --url "${REPO_URL}" \
    --token "${RUNNER_TOKEN}" \
    --name "${RUNNER_NAME}" \
    --labels "${RUNNER_LABELS}" \
    --work "_work" \
    --unattended \
    --replace \
    --ephemeral

./run.sh

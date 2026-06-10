#!/bin/bash
set -e

RUNNER_NAME=${GH_RUNNER_NAME:-"gitops-runner-$(hostname)"}
RUNNER_LABELS=${GH_RUNNER_LABELS:-"clean,podman,quadlet"}
GH_API_VER="2022-11-28"

# Validate required environment variables
if [ -z "${GH_URL}" ] || [ -z "${GH_PAT}" ]; then
  echo "Error: GH_URL and GH_PAT environment variables must be set."
  exit 1
fi
GH_URL="${GH_URL%/}"

# Extract Organization or (Owner & Repo) from URL
if [[ "$GH_URL" == *"/orgs/"* ]] || [[ "$GH_URL" == *"/organizations/"* ]]; then
  ORG_NAME=$(echo "$GH_URL" | awk -F'/' '{print $NF}')
  API_URL="https://api.github.com/orgs/${ORG_NAME}/actions/runners"
else
  OWNER_REPO=$(echo "$GH_URL" | sed -E 's|https://github.com/||')
  API_URL="https://api.github.com/repos/${OWNER_REPO}/actions/runners"
fi

# Force-remove any dead registrations under this name via GitHub API first
# This prevents "Runner name already exists" errors after a hard host crash
echo "Checking for stale runner registrations"
RUNNER_ID=$(curl -s -X GET -H "Authorization: Bearer ${GH_PAT}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: ${GH_API_VER}" \
  "${API_URL}" | jq --arg name "$RUNNER_NAME" '.runners[] | select(.name==$name) | .id')

if ! [ -z "$RUNNER_ID" ]; then
  echo "Found stale runner ID ${RUNNER_ID}, deleting from GitHub"
  curl curl -s -X DELETE -H "Authorization: Bearer ${GH_PAT}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: ${GH_API_VER}" \
    "${API_URL}/${RUNNER_ID}"
fi

echo "Fetching fresh runner registration token using PAT"
GH_TOKEN=$(curl -s -X POST -H "Authorization: Bearer ${GH_PAT}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: ${GH_API_VER}" \
  "${API_URL}/registration-token" | jq -r '.token')

if [ -z "${GH_TOKEN}" ] || [ "${GH_TOKEN}" = "null" ]; then
  echo "Error: Failed to obtain a registration token. Check your PAT permissions and expiration."
  exit 1
fi

# Standard Runner Registration
echo "Configuring GitHub Actions Runner"
./config.sh --url "${GH_URL}" --token "${GH_TOKEN}" --name "${RUNNER_NAME}" --labels "${RUNNER_LABELS}" --unattended --replace

cleanup() {
  echo "Removing runner registration from GitHub"
  # Fetch a new short-lived token to perform the unregistration safely during shutdown
  LOCAL_TOKEN=$(curl -s -X POST -H "Authorization: Bearer ${GH_PAT}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: ${GH_API_VER}" \
    "${API_URL}/registration-token" | jq -r '.token')
  ./config.sh remove --token "${LOCAL_TOKEN}"
}
trap 'cleanup; exit 130' INT QUIT TERM

echo "Starting GitHub Actions Runner"
./run.sh &
PID=$!
wait $PID

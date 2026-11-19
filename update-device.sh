#!/usr/bin/env bash
# Push the rendered app to one Tidbyt (day), or remove it from that Tidbyt (night).
# Expects MODE, TIDBYT_API_TOKEN and TIDBYT_DEVICE_ID in the environment.
set -euo pipefail

INSTALLATION_ID=palisadessnow
PIXLET=${PIXLET:-./pixlet}

if [ -z "${TIDBYT_API_TOKEN:-}" ] || [ -z "${TIDBYT_DEVICE_ID:-}" ]; then
  echo "No credentials for this Tidbyt, skipping."
  exit 0
fi

# Strip stray spaces/newlines picked up when pasting secrets
TOKEN=$(printf '%s' "$TIDBYT_API_TOKEN" | tr -d '[:space:]')
DEVICE=$(printf '%s' "$TIDBYT_DEVICE_ID" | tr -d '[:space:]')

if [ "$MODE" = "night" ]; then
  echo "Quiet hours: removing the app from this Tidbyt."
  "$PIXLET" delete --api-token "$TOKEN" "$DEVICE" "$INSTALLATION_ID" \
    || echo "Nothing to remove (already off for the night)."
else
  echo "Pushing the app to this Tidbyt."
  "$PIXLET" push --api-token "$TOKEN" --installation-id "$INSTALLATION_ID" --background "$DEVICE" snow.webp
fi

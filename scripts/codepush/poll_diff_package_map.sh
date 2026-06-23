#!/bin/bash
#
# Polls the Release Management Public API until a CodePush package has a
# non-empty diff_package_map — i.e. the server has finished generating bundle
# diffs for that package against earlier releases. Used by the bundle-diff E2E
# test to gate the diff-serving phase on diff availability.
#
# diff_package_map lives on the *newer* package (it maps each older predecessor
# package's hash to the diff that upgrades a client from that predecessor to
# this package). So this is polled against update B's UUID after B is uploaded,
# not against update A.
#
# Usage:
#   poll_diff_package_map.sh <package_uuid> <deployment_id>
#
# Required environment:
#   CONNECTED_APP_ID     - connected app the deployment belongs to
#   AUTHORIZATION_TOKEN  - Release Management API token (falls back to BITRISE_PAT)
#
# Optional environment:
#   RM_API_HOST           - API host (default https://api.bitrise.io)
#   POLL_TIMEOUT_SECONDS  - total time to wait (default 60)
#   POLL_INTERVAL_SECONDS - delay between attempts (default 5)
#
# Exit codes:
#   0 - diff_package_map is non-null and non-empty
#   1 - timed out, bad arguments, or request failure

set -u

PACKAGE_UUID="${1:-${PACKAGE_UUID:-}}"
DEPLOYMENT_ID="${2:-${DEPLOYMENT_ID:-}}"
AUTHORIZATION_TOKEN="${AUTHORIZATION_TOKEN:-${BITRISE_PAT:-}}"
RM_API_HOST="${RM_API_HOST:-https://api.bitrise.io}"
POLL_TIMEOUT_SECONDS="${POLL_TIMEOUT_SECONDS:-60}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-5}"

if [ -z "$PACKAGE_UUID" ] || [ -z "$DEPLOYMENT_ID" ]; then
  echo "ERROR: usage: poll_diff_package_map.sh <package_uuid> <deployment_id>" >&2
  exit 1
fi

if [ -z "${CONNECTED_APP_ID:-}" ]; then
  echo "ERROR: CONNECTED_APP_ID must be set in the environment" >&2
  exit 1
fi

if [ -z "$AUTHORIZATION_TOKEN" ]; then
  echo "ERROR: AUTHORIZATION_TOKEN (or BITRISE_PAT) must be set in the environment" >&2
  exit 1
fi

if ! command -v jq > /dev/null 2>&1; then
  echo "ERROR: jq is required but not installed" >&2
  exit 1
fi

# Package-detail endpoint of the Release Management Public API, matching the
# path shape used by upload_code_push_package.sh.
URL="$RM_API_HOST/release-management/v1/connected-apps/$CONNECTED_APP_ID/code-push/deployments/$DEPLOYMENT_ID/packages/$PACKAGE_UUID"

echo "Polling for a non-empty diff_package_map on package $PACKAGE_UUID"
echo "  endpoint: $URL"
echo "  timeout:  ${POLL_TIMEOUT_SECONDS}s, interval: ${POLL_INTERVAL_SECONDS}s"

elapsed=0
body=""
while [ "$elapsed" -lt "$POLL_TIMEOUT_SECONDS" ]; do
  response=$(curl -s -w "\n%{http_code}" -H "Authorization: $AUTHORIZATION_TOKEN" "$URL")
  http_code=$(echo "$response" | tail -1)
  body=$(echo "$response" | sed '$d')

  if [ "$http_code" = "200" ]; then
    # Accept either snake_case or camelCase field naming from the API.
    map=$(echo "$body" | jq -c '.diff_package_map // .diffPackageMap // empty' 2>/dev/null || true)
    if [ -n "$map" ] && [ "$map" != "null" ] && [ "$map" != "{}" ]; then
      echo "OK: diff_package_map is populated after ${elapsed}s: $map"
      exit 0
    fi
    echo "Attempt @${elapsed}s: diff_package_map not ready yet (value: ${map:-<absent>}); retrying in ${POLL_INTERVAL_SECONDS}s..."
  else
    echo "Attempt @${elapsed}s: API returned HTTP $http_code; retrying in ${POLL_INTERVAL_SECONDS}s..."
  fi

  sleep "$POLL_INTERVAL_SECONDS"
  elapsed=$((elapsed + POLL_INTERVAL_SECONDS))
done

echo "ERROR: diff_package_map for package $PACKAGE_UUID did not become non-empty within ${POLL_TIMEOUT_SECONDS}s." >&2
echo "This usually means bundle-diff generation did not run (diffing gate disabled for the workspace, package signed, or no eligible predecessor at the same app version)." >&2
echo "Last response body:" >&2
echo "$body" >&2
exit 1

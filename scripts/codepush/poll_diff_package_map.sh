#!/bin/bash
#
# Probes the public CodePush update_check endpoint as if it were a client that
# already has a given update installed, and succeeds once the server answers
# with a *diff* download URL (download_url containing "diff-") instead of the
# full package. This is the proof that bundle diffing produced and is serving a
# diff for that client.
#
# Why not poll the package-detail API: the Release Management public packages
# API does not expose diff_package_map, so there is no field to observe there.
# The update_check endpoint is the same public acquisition endpoint the
# @code-push-next SDK hits on device, so probing it with the predecessor's
# package hash faithfully reproduces what the real client receives.
#
# Endpoint (from code-push acquisition-sdk):
#   {serverUrl}/v0.1/public/codepush/update_check
#     ?deployment_key=<key>&app_version=<ver>&package_hash=<hash>
#     &is_companion=false&client_unique_id=<id>
# It is authenticated by the opaque deployment_key only (no bearer token).
#
# Usage:
#   poll_diff_package_map.sh <package_hash> <app_version>
#
# Inputs (positional or environment):
#   $1 / CODEPUSH_PACKAGE_HASH  - package hash of the currently-installed update
#                                 (update A); the value the client reports on its
#                                 update check and the key the server diffs against.
#                                 IMPORTANT: this MUST be update A's CodePush
#                                 MANIFEST hash -- i.e. the update_info.package_hash
#                                 returned by the update_check endpoint, which is
#                                 exactly what the SDK reports on its own checks and
#                                 what diff_package_map is keyed by. Do NOT pass the
#                                 package detail REST API's `hash` field: that is the
#                                 zip-file SHA256 (a different algorithm) and never
#                                 equals a diff_package_map key, so the probe would
#                                 always be served the full package instead of a diff.
#   $2 / CODEPUSH_APP_VERSION   - binary app version both updates target
#
# Required environment:
#   CODEPUSH_DEPLOYMENT_KEY     - opaque deployment key (the SDK's deployment_key).
#                                 Falls back to CODE_PUSH_DEPLOYMENT_KEY_IOS_STAGE.
#
# Optional environment:
#   CODEPUSH_SERVER_URL         - CodePush server base URL. Defaults to
#                                 https://$BITRISE_WORKSPACE_ID.codepush.bitrise.io
#   CODEPUSH_CLIENT_UNIQUE_ID   - client_unique_id query value (default diff-e2e-probe)
#   POLL_TIMEOUT_SECONDS        - total time to wait (default 60)
#   POLL_INTERVAL_SECONDS       - delay between attempts (default 5)
#
# Exit codes:
#   0 - server returned a diff download URL (download_url contains "diff-")
#   1 - timed out, bad arguments, or request failure

set -u

PACKAGE_HASH="${1:-${CODEPUSH_PACKAGE_HASH:-}}"
APP_VERSION="${2:-${CODEPUSH_APP_VERSION:-}}"
DEPLOYMENT_KEY="${CODEPUSH_DEPLOYMENT_KEY:-${CODE_PUSH_DEPLOYMENT_KEY_IOS_STAGE:-}}"
CLIENT_UNIQUE_ID="${CODEPUSH_CLIENT_UNIQUE_ID:-diff-e2e-probe}"
POLL_TIMEOUT_SECONDS="${POLL_TIMEOUT_SECONDS:-60}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-5}"

SERVER_URL="${CODEPUSH_SERVER_URL:-}"
if [ -z "$SERVER_URL" ] && [ -n "${BITRISE_WORKSPACE_ID:-}" ]; then
  SERVER_URL="https://${BITRISE_WORKSPACE_ID}.codepush.bitrise.io"
fi
# Strip any trailing slash so the path joins cleanly.
SERVER_URL="${SERVER_URL%/}"

if [ -z "$PACKAGE_HASH" ] || [ -z "$APP_VERSION" ]; then
  echo "ERROR: usage: poll_diff_package_map.sh <package_hash> <app_version>" >&2
  exit 1
fi

if [ -z "$DEPLOYMENT_KEY" ]; then
  echo "ERROR: CODEPUSH_DEPLOYMENT_KEY (or CODE_PUSH_DEPLOYMENT_KEY_IOS_STAGE) must be set" >&2
  exit 1
fi

if [ -z "$SERVER_URL" ]; then
  echo "ERROR: CODEPUSH_SERVER_URL must be set, or BITRISE_WORKSPACE_ID must be available to derive it" >&2
  exit 1
fi

if ! command -v jq > /dev/null 2>&1; then
  echo "ERROR: jq is required but not installed" >&2
  exit 1
fi

# URL-encode a string for safe use in a query value.
urlencode() {
  jq -rn --arg v "$1" '$v|@uri'
}

QUERY="deployment_key=$(urlencode "$DEPLOYMENT_KEY")"
QUERY="$QUERY&app_version=$(urlencode "$APP_VERSION")"
QUERY="$QUERY&package_hash=$(urlencode "$PACKAGE_HASH")"
QUERY="$QUERY&is_companion=false"
QUERY="$QUERY&client_unique_id=$(urlencode "$CLIENT_UNIQUE_ID")"

URL="$SERVER_URL/v0.1/public/codepush/update_check?$QUERY"

echo "Probing update_check for a diff download URL"
echo "  server:       $SERVER_URL"
echo "  app_version:  $APP_VERSION"
echo "  package_hash: $PACKAGE_HASH"
echo "  timeout:      ${POLL_TIMEOUT_SECONDS}s, interval: ${POLL_INTERVAL_SECONDS}s"

elapsed=0
body=""
download_url=""
while [ "$elapsed" -lt "$POLL_TIMEOUT_SECONDS" ]; do
  response=$(curl -s -w "\n%{http_code}" "$URL")
  http_code=$(echo "$response" | tail -1)
  body=$(echo "$response" | sed '$d')

  if [ "$http_code" = "200" ]; then
    # download_url may appear as download_url (snake) or downloadURL (camel).
    download_url=$(echo "$body" | jq -r '.update_info.download_url // .update_info.downloadURL // empty' 2>/dev/null || true)
    case "$download_url" in
      *diff-*)
        echo "OK: server returned a diff download URL after ${elapsed}s:"
        echo "  $download_url"
        exit 0
        ;;
    esac
    echo "Attempt @${elapsed}s: not a diff yet (download_url: ${download_url:-<none>}); retrying in ${POLL_INTERVAL_SECONDS}s..."
  else
    echo "Attempt @${elapsed}s: update_check returned HTTP $http_code; retrying in ${POLL_INTERVAL_SECONDS}s..."
  fi

  sleep "$POLL_INTERVAL_SECONDS"
  elapsed=$((elapsed + POLL_INTERVAL_SECONDS))
done

echo "ERROR: update_check did not return a diff download URL within ${POLL_TIMEOUT_SECONDS}s." >&2
echo "Last download_url: ${download_url:-<none>}" >&2
echo "This usually means bundle-diff generation did not run (diffing gate disabled for the workspace, package signed, or no eligible predecessor at the same app version) or the diff blob has not replicated to the routed backend yet." >&2
echo "Last response body:" >&2
echo "$body" >&2
exit 1

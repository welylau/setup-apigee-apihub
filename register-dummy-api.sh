#!/usr/bin/env bash
# Register a dummy test API (API + version + OpenAPI spec) in API hub.
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-YOUR_PROJECT_ID}"
REGION="${REGION:-asia-east1}"
API_ID="taiwan-weather-api"
VERSION_ID="v1-0-0"  # must be 4-500 chars
SPEC_ID="openapi-v1"
SPEC_FILE="$(dirname "$0")/samples/taiwan-weather-openapi.yaml"
BASE="https://apihub.googleapis.com/v1/projects/${PROJECT_ID}/locations/${REGION}"
TOKEN="$(gcloud auth print-access-token 2>/dev/null)"

post() { # path json
  curl -sS -X POST -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
    -d "$2" "${BASE}/$1"
  echo
}

echo "==> Create API"
post "apis?apiId=${API_ID}" '{
  "displayName": "Taiwan Weather API (Dummy)",
  "description": "Testing dummy API: current weather and forecasts for cities in Taiwan. Demo only.",
  "owner": {"displayName": "API Hub Demo Admin", "email": "api-owner@example.com"},
  "documentation": {"externalUri": "https://example.com/docs/taiwan-weather"},
  "apiStyle": {"enumValues": {"values": [{"id": "rest", "displayName": "REST"}]}}
}'

echo "==> Create version"
post "apis/${API_ID}/versions?versionId=${VERSION_ID}" '{
  "displayName": "v1",
  "description": "Initial dummy version"
}'

echo "==> Upload OpenAPI spec"
CONTENT_B64="$(base64 < "${SPEC_FILE}" | tr -d '\n')"
post "apis/${API_ID}/versions/${VERSION_ID}/specs?specId=${SPEC_ID}" "{
  \"displayName\": \"taiwan-weather-openapi.yaml\",
  \"specType\": {\"enumValues\": {\"values\": [{\"id\": \"openapi\", \"displayName\": \"OpenAPI Spec\"}]}},
  \"contents\": {\"mimeType\": \"application/yaml\", \"contents\": \"${CONTENT_B64}\"}
}"

echo "==> Operations parsed from spec"
curl -sS -H "Authorization: Bearer ${TOKEN}" \
  "${BASE}/apis/${API_ID}/versions/${VERSION_ID}/operations" | grep -E '"path"|"method"' || true

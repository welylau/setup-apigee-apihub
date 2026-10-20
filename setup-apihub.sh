#!/usr/bin/env bash
# Provision a standalone Apigee API hub instance (no Apigee gateway runtime).
#
# Reference: https://cloud.google.com/apigee/docs/apihub/provision-cli
#
# Choices baked in (override via env vars):
#   - Region:      asia-east1 (Taiwan)
#   - Encryption:  GMEK (Google-managed key)
#   - Semantic Search disabled -> no Vertex AI data leaves asia-east1
#
# Note: API hub provisioning auto-creates an Apigee *organization* (control plane
# entitlement only) if one does not exist. No Apigee runtime instance,
# environments, or networking are created by this script.

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-YOUR_PROJECT_ID}"
REGION="${REGION:-asia-east1}"
INSTANCE_ID="${INSTANCE_ID:-apihub-taiwan}"
HOST_ID="${HOST_ID:-${PROJECT_ID}}"
API="https://apihub.googleapis.com/v1"

log() { printf '\n==> %s\n' "$*"; }

TOKEN="$(gcloud auth print-access-token)"
PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"
SA="service-${PROJECT_NUMBER}@gcp-sa-apihub.iam.gserviceaccount.com"

api() { # method path [json-body]
  local method="$1" path="$2" body="${3:-}"
  if [[ -n "${body}" ]]; then
    curl -sS -X "${method}" -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" -H "X-Google-GFE-Can-Retry: yes" \
      -d "${body}" "${API}/${path}"
  else
    curl -sS -X "${method}" -H "Authorization: Bearer ${TOKEN}" "${API}/${path}"
  fi
}

log "Step 1: Enable API hub API (also auto-enables apigee.googleapis.com)"
gcloud services enable apihub.googleapis.com --project="${PROJECT_ID}"

log "Step 2: Create API hub service identity"
gcloud beta services identity create --service=apihub.googleapis.com --project="${PROJECT_ID}"

log "Step 3: Grant roles to ${SA}"
for role in roles/apihub.admin roles/apihub.runtimeProjectServiceAgent; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA}" --role="${role}" --condition=None --quiet >/dev/null
  echo "  granted ${role}"
done

log "Step 4: (GMEK) No KMS key configuration required"

log "Step 5a: Register host project"
if api GET "projects/${PROJECT_ID}/locations/${REGION}/hostProjectRegistrations/${HOST_ID}" | grep -q '"gcpProject"'; then
  echo "  host project already registered"
else
  api POST "projects/${PROJECT_ID}/locations/${REGION}/hostProjectRegistrations?host_project_registration_id=${HOST_ID}" \
    "{\"gcpProject\": \"projects/${PROJECT_ID}\"}"
  echo
fi

log "Step 5b: Create API hub instance ${INSTANCE_ID} in ${REGION}"
EXISTING="$(api GET "projects/${PROJECT_ID}/locations/${REGION}/apiHubInstances/${INSTANCE_ID}")"
if echo "${EXISTING}" | grep -q '"state"'; then
  echo "  instance already exists"
else
  OP_JSON="$(api POST "projects/${PROJECT_ID}/locations/${REGION}/apiHubInstances?api_hub_instance_id=${INSTANCE_ID}" \
    '{"config": {"encryptionType": "GMEK", "disableSearch": true}}')"
  echo "${OP_JSON}"
  OP_NAME="$(echo "${OP_JSON}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("name",""))')"
  if [[ -z "${OP_NAME}" ]]; then
    echo "ERROR: instance creation request failed" >&2
    exit 1
  fi
  log "Waiting for operation ${OP_NAME}"
  for _ in $(seq 1 180); do  # up to ~60 min; first-time provisioning can exceed 20 min
    TOKEN="$(gcloud auth print-access-token)"
    DONE="$(api GET "${OP_NAME}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("error" if "error" in d else d.get("done", False))')"
    [[ "${DONE}" == "True" ]] && break
    if [[ "${DONE}" == "error" ]]; then api GET "${OP_NAME}"; exit 1; fi
    echo "  still provisioning..."; sleep 20
  done
fi

log "Verify"
api GET "projects/${PROJECT_ID}/locations/${REGION}/apiHubInstances/${INSTANCE_ID}"
echo
echo "Console: https://console.cloud.google.com/apigee/api-hub/apis?project=${PROJECT_ID}"

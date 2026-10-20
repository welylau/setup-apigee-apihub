#!/usr/bin/env bash
# Provision a standalone Apigee API hub instance (no Apigee gateway runtime).
#
# Reference: https://cloud.google.com/apigee/docs/apihub/provision-cli
#
# Inputs (env var, or prompted interactively if not set):
#   PROJECT_ID   Existing Google Cloud project with billing enabled (see README prerequisites)
#   REGION       API hub region, e.g. asia-east1. Validated against the API hub locations API.
#   INSTANCE_ID  API hub instance ID, 4-40 chars: letters, digits, '-' or '_'
#
# Choices baked in:
#   - Encryption:  GMEK (Google-managed key)
#   - Semantic Search disabled -> no Vertex AI search data is stored outside REGION
#
# Note: API hub provisioning auto-creates an Apigee *organization* (control plane
# entitlement only) if one does not exist. No Apigee runtime instance,
# environments, or networking are created by this script.

set -euo pipefail

API="https://apihub.googleapis.com/v1"

log()  { printf '\n==> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }

ask() { # VAR_NAME "prompt"
  local var="$1" prompt="$2"
  if [[ -z "${!var:-}" ]]; then
    [[ -t 0 ]] || die "${var} is not set (export ${var}=... or run interactively)"
    read -r -p "${prompt}: " "${var?}"
  fi
  [[ -n "${!var:-}" ]] || die "${var} must not be empty"
}

log "Prerequisite checks"
for bin in gcloud curl python3; do
  command -v "${bin}" >/dev/null || die "'${bin}' is not installed"
done
ACCOUNT="$(gcloud config get-value account 2>/dev/null || true)"
[[ -n "${ACCOUNT}" ]] || die "gcloud is not logged in. Run: gcloud auth login"
echo "  gcloud account: ${ACCOUNT}"

ask PROJECT_ID  "GCP project ID (must already exist)"
ask REGION      "API hub region (e.g. asia-east1, us-central1, europe-west1)"
ask INSTANCE_ID "API hub instance ID (4-40 chars, letters/digits/-/_)"
HOST_ID="${HOST_ID:-${PROJECT_ID}}"

[[ "${INSTANCE_ID}" =~ ^[A-Za-z0-9_-]{4,40}$ ]] \
  || die "INSTANCE_ID '${INSTANCE_ID}' is invalid: use 4-40 chars of letters, digits, '-' or '_'"

PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)' 2>/dev/null || true)"
[[ -n "${PROJECT_NUMBER}" ]] \
  || die "Project '${PROJECT_ID}' not found or no access. Create it first (see README prerequisites)."
echo "  project: ${PROJECT_ID} (${PROJECT_NUMBER})"

BILLING="$(gcloud billing projects describe "${PROJECT_ID}" --format='value(billingEnabled)' 2>/dev/null || true)"
case "${BILLING}" in
  True)  echo "  billing: enabled" ;;
  False) die "Billing is not enabled on '${PROJECT_ID}'. Link a billing account first (see README)." ;;
  *)     warn "Could not verify billing (missing billing permission?). Continuing." ;;
esac

TOKEN="$(gcloud auth print-access-token)"
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

log "Validate region '${REGION}'"
SUPPORTED="$(api GET "projects/${PROJECT_ID}/locations?pageSize=500" \
  | python3 -c 'import json,sys; print(" ".join(sorted(l["locationId"] for l in json.load(sys.stdin).get("locations",[]))))')"
[[ -n "${SUPPORTED}" ]] || die "Could not list API hub locations"
if [[ " ${SUPPORTED} " != *" ${REGION} "* ]]; then
  echo "Supported API hub regions:"; echo "${SUPPORTED}" | tr ' ' '\n' | sed 's/^/  /'
  die "Region '${REGION}' is not supported by API hub"
fi
echo "  ${REGION} is supported"

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

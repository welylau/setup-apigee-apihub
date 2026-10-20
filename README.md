# Set up Apigee API hub (standalone, no gateway runtime)

Scripts to provision **Apigee API hub on its own**, without an Apigee API gateway
runtime, in a single Google Cloud project. A second script registers a dummy API so
you can see API hub working end to end.

You choose the project, region and instance name when you run the script. Nothing is
hard-coded.

> [!NOTE]
> This is a demo sample, not an official Google product. Review the scripts before
> running them in your own environment.

## What gets created

| Resource | Details |
|---|---|
| API hub API | `apihub.googleapis.com` turned on. This also turns on `apigee.googleapis.com` automatically. |
| API hub service agent | `service-PROJECT_NUMBER@gcp-sa-apihub.iam.gserviceaccount.com`, granted `roles/apihub.admin` and `roles/apihub.runtimeProjectServiceAgent` |
| Host project registration | Your project, registered as the API hub host project in your chosen region |
| API hub instance | Your chosen instance ID, with Google-managed encryption keys (GMEK) and Semantic Search turned off |
| Apigee organization | Created automatically by API hub if none exists. It's the management layer only. |

**Not created:** Apigee runtime instances, environments, environment groups, or
networking (VPC peering / PSC). There is no API gateway.

```mermaid
flowchart LR
  U["You (gcloud + curl)"] --> H["API hub API<br/>apihub.googleapis.com"]
  H --> R["Host project registration<br/>REGION"]
  H --> I["API hub instance<br/>GMEK, search off"]
  H -. auto-creates .-> O["Apigee organization<br/>(no runtime)"]
  D["register-dummy-api.sh"] --> A["API: taiwan-weather-api<br/>version v1-0-0 + OpenAPI spec"]
  A --> I
```

## Prerequisites

### 1. Tools

- [Google Cloud CLI](https://cloud.google.com/sdk/docs/install) (`gcloud`), plus the `beta` component
- `curl` and `python3`
- A login: `gcloud auth login`

### 2. A Google Cloud project with billing enabled

API hub is installed **into an existing project**; the script doesn't create one.
We recommend a **new, blank project just for API hub**, because:

- each project can host only one API hub instance;
- API hub sets up an Apigee organization in the project. If the project already has
  one, API hub uses that organization instead, and the result is no longer
  "API hub only".

If you don't have a project yet, create one and link a billing account:

```bash
export PROJECT_ID=my-apihub-project        # must be globally unique

# Add --organization=ORG_ID or --folder=FOLDER_ID if your account requires a parent
gcloud projects create "${PROJECT_ID}"

gcloud billing accounts list               # pick an OPEN billing account
gcloud billing projects link "${PROJECT_ID}" --billing-account=XXXXXX-XXXXXX-XXXXXX
```

API hub itself is free. Billing is still required on the project.

### 3. IAM roles

If you created the project yourself, you are its Owner, which covers everything below.
Otherwise you need these roles on the project:

- `roles/apihub.provisioningAdmin`
- `roles/serviceusage.serviceUsageAdmin`
- `roles/resourcemanager.projectIamAdmin`

### 4. Region and organization policy

- Pick a region that [API hub supports](https://cloud.google.com/apigee/docs/apihub/locations).
  The script checks your choice against the API and prints the supported list if it's wrong.
- If your organization uses the **Resource Location Restriction** policy
  (`gcp.resourceLocations`), it must allow your chosen region. To check:

  ```bash
  gcloud resource-manager org-policies describe gcp.resourceLocations \
    --project="${PROJECT_ID}" --effective
  ```

  API hub uses Cloud Scheduler internally. In a few regions where Cloud Scheduler isn't
  available, API hub creates it in a nearby fallback region instead (for example,
  `europe-west4` falls back to `europe-west1`). If the location policy blocks that
  fallback region, provisioning fails. See the fallback table on the
  [API hub locations](https://cloud.google.com/apigee/docs/apihub/locations) page.
- If API hub was deprovisioned in this project recently, wait 7 days before
  provisioning it again.

## Design choices

- **Semantic Search off (`disableSearch: true`).** Semantic Search (Vertex AI) can
  only store its data in the `us` or `eu` multi-region. Turning it off keeps all API
  hub data in your chosen region.
- **GMEK encryption.** No Cloud KMS key to manage. See the
  [CLI provisioning guide](https://cloud.google.com/apigee/docs/apihub/provision-cli)
  if you need CMEK instead.

## Usage

### 1. Provision API hub

Run it interactively and answer the prompts:

```bash
./setup-apihub.sh
# GCP project ID (must already exist): my-apihub-project
# API hub region (e.g. asia-east1, us-central1, europe-west1): asia-east1
# API hub instance ID (4-40 chars, letters/digits/-/_): my-apihub
```

Or set the values first, for example in CI:

```bash
PROJECT_ID=my-apihub-project REGION=asia-east1 INSTANCE_ID=my-apihub ./setup-apihub.sh
```

Before changing anything, the script checks:

- the tools are installed and you're logged in;
- the project exists and has billing enabled;
- the instance ID is valid.

After turning on the API, it also checks that API hub supports the region.

The script is safe to re-run: it skips the host registration and instance if they
already exist. The first time can take **20 to 30 minutes**, because API hub also
creates the Apigee organization. The script waits up to about 60 minutes.

When it finishes, the instance shows `"state": "ACTIVE"`:

```json
{
  "name": "projects/my-apihub-project/locations/asia-east1/apiHubInstances/my-apihub",
  "state": "ACTIVE",
  "config": { "disableSearch": true, "encryptionType": "GMEK" }
}
```

### 2. Register a dummy API

```bash
./register-dummy-api.sh        # prompts for PROJECT_ID and REGION if they aren't set
```

This creates:

- the API `taiwan-weather-api` (REST style, with an owner and a docs link)
- version `v1-0-0`
- the spec `openapi-v1`, uploaded from
  [`samples/taiwan-weather-openapi.yaml`](samples/taiwan-weather-openapi.yaml)

API hub reads the spec and finds three operations: `GET /cities`,
`GET /cities/{cityId}/current`, and `GET /cities/{cityId}/forecast`.

### 3. View it in the console

`https://console.cloud.google.com/apigee/api-hub/apis?project=PROJECT_ID`

## Repository layout

```
.
├── setup-apihub.sh                    # Provision standalone API hub
├── register-dummy-api.sh              # Register a dummy API + version + spec
└── samples/
    └── taiwan-weather-openapi.yaml    # Dummy OpenAPI 3.0 spec
```

## Clean up

To delete the dummy API:

```bash
curl -X DELETE -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://apihub.googleapis.com/v1/projects/${PROJECT_ID}/locations/${REGION}/apis/taiwan-weather-api?force=true"
```

To remove API hub completely, deprovision it from the console. This also moves the
auto-created Apigee organization into a 7-day soft-delete period. If you used a
dedicated project, you can delete the whole project instead.

## References

- [Provision API hub (console)](https://cloud.google.com/apigee/docs/apihub/provision)
- [Provision API hub from the command line](https://cloud.google.com/apigee/docs/apihub/provision-cli)
- [API hub locations](https://cloud.google.com/apigee/docs/apihub/locations)
- [API hub REST reference](https://cloud.google.com/apigee/docs/reference/apis/apihub/rest)

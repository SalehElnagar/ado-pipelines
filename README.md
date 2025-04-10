# Azure DevOps YAML Templates Demo (Docker + Multi-App)

This repo demonstrates Azure DevOps YAML templates across two Dockerized Node.js apps:

- `apps/api-service` – Express API with health/greet/sum endpoints + Jest tests
- `apps/worker-service` – Simple worker that uppercases jobs + Jest tests

Pipeline narrative:
1) Monolithic baseline: `azure-pipelines/inline/build.inline.yml`
2) Templated steps/jobs/stages: under `azure-pipelines/templates/`
3) Full pipeline templates with `extends`: `azure-pipelines/pipelines/apps-ci.yml` and `apps-pr.yml`
4) Entry pipelines (multi-app orchestration):
   - `azure-pipelines/build.yml` (CI, triggers on `main`)
   - `azure-pipelines/pr.yml` (PR validation)

5) Per-service entry pipelines (one pipeline per app, using shared templates):
   - `apps/api-service/pipelines/ci.yml` and `apps/api-service/pipelines/pr.yml`
   - `apps/worker-service/pipelines/ci.yml` and `apps/worker-service/pipelines/pr.yml`
   These are the files to point Azure DevOps at when creating pipelines per service. They `extends` the single-app templates in `azure-pipelines/pipelines/` (`app-ci-template.yml`, `app-pr-template.yml`) which in turn reuse the shared step/job/stage templates under `azure-pipelines/templates/`.

## Local dev
```bash
# Build/test images locally
scripts/local-dev.sh build
scripts/local-dev.sh test
# Run api-service locally
scripts/local-dev.sh run-api
# Run worker locally
scripts/local-dev.sh run-worker
```

## Azure DevOps setup (one-command bootstrap)
Run `scripts/setup-ado-pipelines.sh` to create everything (GitHub service connection, ACR service principal + service connection, variable group, and the CI/PR pipelines). Minimal required environment variables:
```bash
export AZDO_ORG_URL="https://dev.azure.com/<org>"
export AZDO_PROJECT="<project>"
export AZDO_PAT="<azdo_pat>"
export GITHUB_PAT="<github_pat>"
export AZ_SUBSCRIPTION_ID="<azure_subscription_id>"
export ACR_NAME="<existing_acr_name>"
# Optional overrides
export GITHUB_SC_NAME="github-sc-ado-demo"   # GitHub service connection name
export ACR_SC_NAME="acr-sc-ado-demo"         # ACR service connection name
export ACR_SP_NAME="ado-acr-sp"              # ACR service principal name
export PIPE_NAME_CI="ado-templates-ci"
export PIPE_NAME_PR="ado-templates-pr"

az login                 # make sure az CLI is authenticated first
./scripts/setup-ado-pipelines.sh
```
What the script does:
- Ensures the GitHub service connection exists (or creates it) and authorizes it for all pipelines.
- Creates or reuses the ACR service connection (type `dockerregistry`) scoped to your ACR, with registry metadata populated, and forces “Grant access permission to all pipelines.” By default it uses automatic creation; if the name already exists, it reuses it.
- Creates/updates variable group `acr-config` (authorized for all pipelines) with `CONTAINER_REGISTRY=<acr>.azurecr.io` and `CONTAINER_REGISTRY_SC=<acr_sc_name>`.
- Recreates the CI/PR pipelines pointing at `azure-pipelines/build.yml` and `azure-pipelines/pr.yml`, sets pipeline variables `CONTAINER_REGISTRY`/`CONTAINER_REGISTRY_SC`, then triggers a CI run.
- Also (re)creates per-app pipelines under folders `api-service/` and `worker-service/` pointing at `apps/<app>/pipelines/{ci,pr}.yml`. These inherit the shared templates and variable group.

Tuning:
- To skip tests when manually queueing, set the `runTests` parameter to `false` at queue time (all entry pipelines expose it).
- You can override names/creation behavior with env vars (e.g., `RECREATE_PIPELINES=true`, `RECREATE_ACR_SC=true`, `ACR_SC_CREATION_MODE=manual` if you want to force SP/key mode).
- To add more apps, set `APPS="app-one,app-two"` (and optionally `APPS_FOLDER_PREFIX` for nested folders); the script will create per-app CI/PR pipelines under those folders.
- If an ACR SC already exists and you want to keep it, leave `RECREATE_ACR_SC` unset/false; to force recreation with fresh credentials, set `RECREATE_ACR_SC=true`.

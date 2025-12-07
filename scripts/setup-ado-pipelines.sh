#!/usr/bin/env bash
set -euo pipefail

: "${AZDO_ORG_URL:?AZDO_ORG_URL is required}"
: "${AZDO_PROJECT:?AZDO_PROJECT is required}"
: "${AZDO_PAT:?AZDO_PAT is required}"
: "${GITHUB_PAT:?GITHUB_PAT is required}"
: "${AZ_SUBSCRIPTION_ID:?AZ_SUBSCRIPTION_ID is required}"
: "${ACR_NAME:?ACR_NAME is required}"

export AZURE_DEVOPS_EXT_PAT="$AZDO_PAT"
export AZURE_DEVOPS_EXT_GITHUB_PAT="$GITHUB_PAT"

GITHUB_SC_NAME="${GITHUB_SC_NAME:-${SC_NAME:-github-sc-ado-demo}}"
ACR_SC_NAME="${ACR_SC_NAME:-container-reg-sc}"
ACR_SP_NAME="${ACR_SP_NAME:-ado-acr-sp}"
ACR_SP_ROLE="${ACR_SP_ROLE:-acrpush}"
RECREATE_ACR_SC="${RECREATE_ACR_SC:-false}"
RECREATE_GITHUB_SC="${RECREATE_GITHUB_SC:-false}"
RECREATE_PIPELINES="${RECREATE_PIPELINES:-false}"
ACR_SC_CREATION_MODE="${ACR_SC_CREATION_MODE:-automatic}"
ACR_VG_NAME="${ACR_VG_NAME:-acr-config}"
RECREATE_VG="${RECREATE_VG:-false}"
APPS="${APPS:-api-service,worker-service}"
APPS_FOLDER_PREFIX="${APPS_FOLDER_PREFIX:-}"
PIPE_NAME_CI="${PIPE_NAME_CI:-ado-templates-ci}"
PIPE_NAME_PR="${PIPE_NAME_PR:-ado-templates-pr}"
LOG_FILE="${LOG_FILE:-./pipeline-create.log}"

cd "$(dirname "$0")/.."

az devops configure --defaults organization="$AZDO_ORG_URL" project="$AZDO_PROJECT"
az account set --subscription "$AZ_SUBSCRIPTION_ID"
AZ_SUBSCRIPTION_NAME="${AZ_SUBSCRIPTION_NAME:-$(az account show --subscription "$AZ_SUBSCRIPTION_ID" --query name -o tsv)}"
PROJECT_ID="${PROJECT_ID:-$(az devops project show --project "$AZDO_PROJECT" --query id -o tsv)}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

lookup_sc() {
  local name=$1
  az devops service-endpoint list --query "[?name=='${name}']" -o json || echo "[]"
}

ensure_github_service_connection() {
  local sc_json sc_id tmpfile
  sc_json=$(lookup_sc "$GITHUB_SC_NAME")
  sc_id=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read() or '[]'); print(d[0]['id'] if d else '')" <<<"$sc_json")
  if [ -n "$sc_id" ] && [ "$RECREATE_GITHUB_SC" = "true" ]; then
    echo "Deleting existing GitHub service connection $GITHUB_SC_NAME (id: $sc_id) to recreate with provided PAT..." >&2
    az devops service-endpoint delete --id "$sc_id" --yes >/dev/null || true
    sc_id=""
  fi
  if [ -z "$sc_id" ]; then
    tmpfile=$(mktemp)
    GITHUB_SC_NAME="$GITHUB_SC_NAME" GITHUB_PAT="$GITHUB_PAT" \
    python3 - <<'PY' >"$tmpfile"
import json, os, sys
data = {
    "name": os.environ["GITHUB_SC_NAME"],
    "type": "github",
    "url": "https://github.com",
    "authorization": {
        "scheme": "PersonalAccessToken",
        "parameters": {"accessToken": os.environ["GITHUB_PAT"]},
    },
    "data": {"authorizationType": "PersonalAccessToken"},
}
json.dump(data, sys.stdout)
PY
    sc_json=$(az devops service-endpoint create \
      --service-endpoint-configuration "$tmpfile" \
      --project "$AZDO_PROJECT" \
      -o json 2>sc-github-create.err)
    rm -f "$tmpfile"
    if [ $? -ne 0 ] || [ -z "$sc_json" ]; then
      if grep -qi "already exists" sc-github-create.err; then
        echo "GitHub service connection $GITHUB_SC_NAME already exists; reusing it." >&2
        rm -f sc-github-create.err
        sc_json=$(lookup_sc "$GITHUB_SC_NAME")
      else
        cat sc-github-create.err >&2 || true
        rm -f sc-github-create.err
        fail "Failed to create GitHub service connection $GITHUB_SC_NAME. Ensure your GITHUB_PAT has repo + admin:repo_hook and pick a unique GITHUB_SC_NAME if you lack permissions to existing connections."
      fi
    fi
    rm -f sc-github-create.err
    sc_id=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read() or '{}'); print(d.get('id',''))" <<<"$sc_json")
    if [ -z "$sc_id" ]; then
      fail "Could not parse GitHub service connection id for $GITHUB_SC_NAME"
    fi
    echo "Created GitHub service connection $GITHUB_SC_NAME with id $sc_id" >&2
  else
    echo "GitHub service connection $GITHUB_SC_NAME already exists (id: $sc_id)" >&2
  fi
  if [ -n "$sc_id" ]; then
    az devops service-endpoint update \
      --id "$sc_id" \
      --enable-for-all true \
      --organization "$AZDO_ORG_URL" \
      --project "$AZDO_PROJECT" \
      >/dev/null
  fi
  echo "$sc_id"
}

ensure_acr_sp() {
  local acr_scope acr_sp_json app_id client_secret tenant_id
  acr_scope=$(az acr show --name "$ACR_NAME" --query "id" -o tsv)
  echo "Ensuring ACR service principal $ACR_SP_NAME with scope $acr_scope ..." >&2
  acr_sp_json=$(az ad sp create-for-rbac \
    --name "$ACR_SP_NAME" \
    --role "$ACR_SP_ROLE" \
    --scopes "$acr_scope" \
    -o json)
  app_id=$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('appId',''))" <<<"$acr_sp_json")
  client_secret=$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('password',''))" <<<"$acr_sp_json")
  tenant_id=$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('tenant',''))" <<<"$acr_sp_json")
  if [ -z "$app_id" ] || [ -z "$client_secret" ] || [ -z "$tenant_id" ]; then
    echo "Failed to retrieve service principal credentials for $ACR_SP_NAME; try deleting the SP or regenerating credentials." >&2
    exit 1
  fi
  echo "Service principal appId: $app_id (tenant: $tenant_id)" >&2
  echo "$app_id|$client_secret|$tenant_id"
}

ensure_acr_service_connection() {
  local app_id=${1:-""}
  local client_secret=${2:-""}
  local tenant_id=${3:-""}
  local acr_login_server acr_id sc_json sc_id tmpfile
  acr_login_server=$(az acr show --name "$ACR_NAME" --query "loginServer" -o tsv)
  acr_id=$(az acr show --name "$ACR_NAME" --query "id" -o tsv)

  sc_json=$(lookup_sc "$ACR_SC_NAME")
  sc_id=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read() or '[]'); print(d[0]['id'] if d else '')" <<<"$sc_json")
  if [ -n "$sc_id" ] && [ "$RECREATE_ACR_SC" != "true" ]; then
    local existing_login_server has_secret
    existing_login_server=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read() or '[]'); print(d[0].get('data',{}).get('acrLoginServer',''))" <<<"$sc_json")
    if [ -z "$existing_login_server" ]; then
      existing_login_server="$acr_login_server"
    fi
    has_secret=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read() or '[]'); print(d[0].get('authorization',{}).get('parameters',{}).get('serviceprincipalkey',''))" <<<"$sc_json")
    if [ -z "$has_secret" ] && [ "$ACR_SC_CREATION_MODE" != "automatic" ]; then
      echo "ACR service connection $ACR_SC_NAME exists but is missing credentials; recreating..." >&2
      az devops service-endpoint delete --id "$sc_id" --yes >/dev/null || true
      sc_id=""
    else
      echo "Reusing ACR service connection $ACR_SC_NAME (id: $sc_id)" >&2
      az devops service-endpoint update \
        --id "$sc_id" \
        --enable-for-all true \
        --organization "$AZDO_ORG_URL" \
        --project "$AZDO_PROJECT" \
        >/dev/null || true
      echo "$existing_login_server|$sc_id"
      return
    fi
  fi

  if [ -n "$sc_id" ] && [ "$RECREATE_ACR_SC" = "true" ]; then
    echo "ACR service connection $ACR_SC_NAME already exists (id: $sc_id); deleting to recreate with fresh credentials..." >&2
    az devops service-endpoint delete --id "$sc_id" --yes >/dev/null || true
    sc_id=""
  fi

  if [ "$ACR_SC_CREATION_MODE" = "automatic" ]; then
    local token
    token=$(az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv)
    tmpfile=$(mktemp)
    cat >"$tmpfile" <<JSON
{
  "name": "$ACR_SC_NAME",
  "type": "dockerregistry",
  "url": "https://$acr_login_server",
  "authorization": {
    "scheme": "ServicePrincipal",
    "parameters": {
      "loginServer": "$acr_login_server",
      "role": "8311e382-0749-4cb8-b61a-304f252e45ec",
      "scope": "$acr_id",
      "tenantId": "$(az account show --query tenantId -o tsv)",
      "workloadIdentityFederationIssuerType": "EntraID"
    }
  },
  "data": {
    "registryId": "$acr_id",
    "registryName": "$ACR_NAME",
    "acrLoginServer": "$acr_login_server",
    "registrytype": "ACR",
    "subscriptionId": "$AZ_SUBSCRIPTION_ID",
    "subscriptionName": "$AZ_SUBSCRIPTION_NAME",
    "creationMode": "Automatic"
  },
  "serviceEndpointProjectReferences": [
    {
      "description": "",
      "name": "$ACR_SC_NAME",
      "projectReference": {
        "id": "$PROJECT_ID",
        "name": "$AZDO_PROJECT"
      }
    }
  ],
  "owner": "library",
  "isShared": false,
  "isOutdated": false
}
JSON

    sc_json=$(curl -sS -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
      -X POST "https://dev.azure.com/$(echo "$AZDO_ORG_URL" | sed 's#https://dev.azure.com/##')/_apis/serviceendpoint/endpoints?api-version=7.1-preview.4" \
      --data @"$tmpfile")
    rm -f "$tmpfile"
  else
    if [ -z "$app_id" ] || [ -z "$client_secret" ] || [ -z "$tenant_id" ]; then
      local creds
      creds=$(ensure_acr_sp)
      app_id=$(cut -d'|' -f1 <<<"$creds")
      client_secret=$(cut -d'|' -f2 <<<"$creds")
      tenant_id=$(cut -d'|' -f3 <<<"$creds")
    fi

    tmpfile=$(mktemp)
    APP_ID="$app_id" CLIENT_SECRET="$client_secret" TENANT_ID="$tenant_id" \
    ACR_LOGIN_SERVER="$acr_login_server" ACR_SC_NAME="$ACR_SC_NAME" \
    AZ_SUBSCRIPTION_ID="$AZ_SUBSCRIPTION_ID" AZ_SUBSCRIPTION_NAME="$AZ_SUBSCRIPTION_NAME" \
    ACR_ID="$acr_id" ACR_NAME="$ACR_NAME" \
    python3 - <<'PY' >"$tmpfile"
import json, os, sys
data = {
    "name": os.environ["ACR_SC_NAME"],
    "type": "dockerregistry",
    "url": f"https://{os.environ['ACR_LOGIN_SERVER']}",
    "authorization": {
        "scheme": "ServicePrincipal",
        "parameters": {
            "tenantid": os.environ["TENANT_ID"],
            "serviceprincipalid": os.environ["APP_ID"],
            "serviceprincipalkey": os.environ["CLIENT_SECRET"],
        },
    },
    "data": {
        "subscriptionId": os.environ["AZ_SUBSCRIPTION_ID"],
        "subscriptionName": os.environ["AZ_SUBSCRIPTION_NAME"],
        "registrytype": "ACR",
        "registryName": os.environ["ACR_NAME"],
        "acrLoginServer": os.environ["ACR_LOGIN_SERVER"],
        "azureContainerRegistry": "true",
        "resourceId": os.environ["ACR_ID"],
    },
}
json.dump(data, sys.stdout)
PY

    if ! sc_json=$(az devops service-endpoint create \
      --service-endpoint-configuration "$tmpfile" \
      --project "$AZDO_PROJECT" \
      -o json 2>sc-create.err); then
      if grep -qi "already exists" sc-create.err; then
        echo "ACR service connection $ACR_SC_NAME already exists; reusing it."
        rm -f "$tmpfile" sc-create.err
        echo "$acr_login_server|"
        return
      fi
      rm -f "$tmpfile" sc-create.err
      fail "Failed to create ACR service connection $ACR_SC_NAME. If the name exists and you lack rights, set ACR_SC_NAME to a unique value."
    fi
    rm -f sc-create.err
    rm -f "$tmpfile"
  fi

  sc_id=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read() or '{}'); print(d.get('id',''))" <<<"$sc_json")
  if [ -z "$sc_id" ]; then
    sc_id=$(az devops service-endpoint list --query "[?name=='${ACR_SC_NAME}'].id" -o tsv | head -n1 || true)
  fi
  echo "Created ACR service connection $ACR_SC_NAME with id $sc_id" >&2

  if [ -n "$sc_id" ]; then
    # Always ensure "grant access to all pipelines" is on, even for automatic creation
    az devops service-endpoint update \
      --id "$sc_id" \
      --enable-for-all true \
      --organization "$AZDO_ORG_URL" \
      --project "$AZDO_PROJECT" \
      >/dev/null
  fi

  echo "$acr_login_server|$sc_id"
}

ensure_variable_group() {
  local vg_json vg_id
  vg_json=$(az pipelines variable-group list --query "[?name=='${ACR_VG_NAME}']" -o json || echo "[]")
  vg_id=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read() or '[]'); print(d[0]['id'] if d else '')" <<<"$vg_json")
  if [ -n "$vg_id" ] && [ "$RECREATE_VG" = "true" ]; then
    az pipelines variable-group delete --id "$vg_id" --yes >/dev/null || true
    vg_id=""
  fi
  if [ -n "$vg_id" ]; then
    az pipelines variable-group variable update --group-id "$vg_id" --name CONTAINER_REGISTRY --value "$ACR_LOGIN_SERVER" >/dev/null || true
    az pipelines variable-group variable update --group-id "$vg_id" --name CONTAINER_REGISTRY_SC --value "$ACR_SC_NAME" >/dev/null || true
    az pipelines variable-group variable create --group-id "$vg_id" --name CONTAINER_REGISTRY --value "$ACR_LOGIN_SERVER" >/dev/null || true
    az pipelines variable-group variable create --group-id "$vg_id" --name CONTAINER_REGISTRY_SC --value "$ACR_SC_NAME" >/dev/null || true
    echo "$vg_id"
    return
  fi
  vg_id=$(az pipelines variable-group create --name "$ACR_VG_NAME" --authorize true --project "$AZDO_PROJECT" --output tsv --query id)
  az pipelines variable-group variable create --group-id "$vg_id" --name CONTAINER_REGISTRY --value "$ACR_LOGIN_SERVER" >/dev/null
  az pipelines variable-group variable create --group-id "$vg_id" --name CONTAINER_REGISTRY_SC --value "$ACR_SC_NAME" >/dev/null
  echo "$vg_id"
}

recreate_pipeline() {
  local name=$1
  local yml_path=$2
  local sc_id=$3
  local folder_path=${4:-""}
  local existing_json existing_id
  existing_json=$(az pipelines list --query "[?name=='${name}']" -o json || echo "[]")
  existing_id=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read() or '[]'); print(d[0]['id'] if d else '')" <<<"$existing_json")
  if [ -n "$existing_id" ] && [ "$RECREATE_PIPELINES" = "true" ]; then
    echo "Pipeline ${name} already exists (id: ${existing_id}); deleting to recreate cleanly..." >&2
    az pipelines delete --id "$existing_id" --yes >/dev/null
    existing_id=""
  fi
  if [ -n "$existing_id" ] && [ "$RECREATE_PIPELINES" != "true" ]; then
    echo "$existing_id"
    return
  fi
  if [ -z "$sc_id" ]; then
    fail "No service connection id available for ${name}; ensure GITHUB_SC_NAME is accessible or set RECREATE_GITHUB_SC=true to create a new one."
  fi
  local pipeline_json
  if [ -n "$folder_path" ]; then
    pipeline_json=$(az pipelines create \
      --name "$name" \
      --repository https://github.com/SalehElnagar/ado-pipelines \
      --branch main \
      --yml-path "$yml_path" \
      --repository-type github \
      --service-connection "$sc_id" \
      --folder-path "$folder_path" \
      --skip-first-run true \
      -o json 2>pipeline-create.log)
  else
    pipeline_json=$(az pipelines create \
      --name "$name" \
      --repository https://github.com/SalehElnagar/ado-pipelines \
      --branch main \
      --yml-path "$yml_path" \
      --repository-type github \
      --service-connection "$sc_id" \
      --skip-first-run true \
      -o json 2>pipeline-create.log)
  fi
  if [ $? -ne 0 ] || [ -z "$pipeline_json" ]; then
    echo "Pipeline creation failed for ${name}. Error output:" >&2
    cat pipeline-create.log >&2 || true
    fail "az pipelines create failed for ${name}"
  fi
  local new_id
  new_id=$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" <<<"$pipeline_json")
  if [ -z "$new_id" ]; then
    fail "Could not parse pipeline id for ${name}"
  fi
  echo "$new_id"
}

set_pipeline_variable() {
  local pipeline_id=$1
  local var_name=$2
  local var_value=$3
  local secret=${4:-false}
  if ! az pipelines variable update --pipeline-id "$pipeline_id" --name "$var_name" --value "$var_value" --secret "$secret" >/dev/null 2>/dev/null; then
    az pipelines variable create --pipeline-id "$pipeline_id" --name "$var_name" --value "$var_value" --secret "$secret" >/dev/null
  fi
}

GITHUB_SC_ID=$(ensure_github_service_connection)

APP_ID=""
CLIENT_SECRET=""
TENANT_ID=""
if [ "$RECREATE_ACR_SC" = "true" ]; then
  SP_DETAILS=$(ensure_acr_sp)
  APP_ID=$(cut -d'|' -f1 <<<"$SP_DETAILS")
  CLIENT_SECRET=$(cut -d'|' -f2 <<<"$SP_DETAILS")
  TENANT_ID=$(cut -d'|' -f3 <<<"$SP_DETAILS")
fi

ACR_DETAILS=$(ensure_acr_service_connection "$APP_ID" "$CLIENT_SECRET" "$TENANT_ID")
ACR_LOGIN_SERVER=$(cut -d'|' -f1 <<<"$ACR_DETAILS")
ACR_SC_ID=$(cut -d'|' -f2 <<<"$ACR_DETAILS")
VG_ID=$(ensure_variable_group)

CI_ID=$(recreate_pipeline "$PIPE_NAME_CI" azure-pipelines/build.yml "$GITHUB_SC_ID")
PR_ID=$(recreate_pipeline "$PIPE_NAME_PR" azure-pipelines/pr.yml "$GITHUB_SC_ID")

IFS=',' read -ra APPS_ARR <<<"$APPS"
APP_CI_IDS=()
APP_PR_IDS=()
for raw_app in "${APPS_ARR[@]}"; do
  app=$(echo "$raw_app" | xargs)
  [ -z "$app" ] && continue
  folder="$app"
  if [ -n "$APPS_FOLDER_PREFIX" ]; then
    folder="${APPS_FOLDER_PREFIX%/}/$app"
  fi
  app_ci_yml="apps/${app}/pipelines/ci.yml"
  app_pr_yml="apps/${app}/pipelines/pr.yml"
  if [ -f "$app_ci_yml" ]; then
    APP_CI_IDS+=("$(recreate_pipeline "${app}-ci" "$app_ci_yml" "$GITHUB_SC_ID" "$folder")")
  else
    echo "Warning: missing $app_ci_yml; skipping" >&2
  fi
  if [ -f "$app_pr_yml" ]; then
    APP_PR_IDS+=("$(recreate_pipeline "${app}-pr" "$app_pr_yml" "$GITHUB_SC_ID" "$folder")")
  else
    echo "Warning: missing $app_pr_yml; skipping" >&2
  fi
done

ALL_PIPELINE_IDS=("$CI_ID" "$PR_ID" "${APP_CI_IDS[@]}" "${APP_PR_IDS[@]}")
for pid in "${ALL_PIPELINE_IDS[@]}"; do
  [ -n "$pid" ] || continue
  set_pipeline_variable "$pid" "CONTAINER_REGISTRY" "$ACR_LOGIN_SERVER"
  set_pipeline_variable "$pid" "CONTAINER_REGISTRY_SC" "$ACR_SC_NAME"
done

echo "Triggering CI pipeline run..."
az pipelines run --id "$CI_ID" --branch main >/dev/null
echo "Done. Pipelines: $PIPE_NAME_CI (id: $CI_ID), $PIPE_NAME_PR (id: $PR_ID)."
echo "Container registry: $ACR_LOGIN_SERVER (service connection: $ACR_SC_NAME, id: $ACR_SC_ID)"

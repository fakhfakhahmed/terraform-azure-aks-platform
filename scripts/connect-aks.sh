#!/usr/bin/env bash
#
# connect-aks.sh
#
# SYNOPSIS
#   Points kubectl at the AKS cluster for one environment and verifies the
#   connection. Bash port of connect-aks.ps1.
#
# DESCRIPTION
#   Fetches the cluster name and resource group from the environment's
#   Terraform outputs (aks_cluster_name, resource_group_name), downloads
#   credentials, converts the kubeconfig for Entra ID auth, and then proves
#   the connection actually works.
#
#   WHY kubelogin IS NOT OPTIONAL HERE
#   -----------------------------------------------------------------------
#   These clusters are Entra ID (Azure AD) integrated with Azure RBAC for
#   Kubernetes authorization, and local accounts are disabled - there is no
#   cluster-admin kubeconfig with a static certificate to fall back on.
#   `az aks get-credentials` writes a kubeconfig whose user block uses an
#   exec credential plugin named "kubelogin". If that binary is not on PATH,
#   every single kubectl command fails with something like:
#
#       Unable to connect to the server: getting credentials: exec: executable kubelogin not found
#
#   `kubelogin convert-kubeconfig -l azurecli` rewrites the kubeconfig to
#   reuse the token already cached by the Azure CLI, which is the right mode
#   for an interactive operator. Other useful modes: -l devicecode
#   (headless/SSH), -l workloadidentity (in-cluster CI), -l spn (service
#   principal, discouraged).
#
#   AUTHORIZATION vs AUTHENTICATION
#   Getting a kubeconfig proves nothing about your permissions. With Azure
#   RBAC enabled, your Entra identity needs an Azure role such as "Azure
#   Kubernetes Service RBAC Reader" or "... Cluster Admin" scoped to the
#   cluster. A successful login followed by "forbidden" on
#   `kubectl get nodes` means the role assignment is missing, not that the
#   connection is broken. The script distinguishes these two cases for you.
#
#   PRIVATE CLUSTERS
#   prod runs with a private API server. From outside the VNet, DNS for the
#   API server FQDN resolves to a private IP you cannot reach, so kubectl
#   hangs and then fails with "dial tcp ... i/o timeout" or "no such host".
#   The script detects this and prints the four legitimate ways in.
#
# USAGE
#   ./scripts/connect-aks.sh <dev|staging|prod> [options]
#
#   --cluster-name NAME       Override the cluster name instead of reading
#                             it from Terraform outputs. Useful when the
#                             environment is not initialised locally or you
#                             are helping someone else debug.
#   --resource-group GROUP   Override the resource group. Must be supplied
#                             together with --cluster-name.
#   --admin                   Use `az aks get-credentials --admin`. This only
#                             works when local accounts are ENABLED, which
#                             they are not on these clusters - it is here so
#                             the failure message is explicit rather than
#                             mysterious.
#   --skip-verify              Fetch and convert the kubeconfig but skip the
#                             kubectl verification steps.
#
# NOTES
#   Author : Ahmed Fakhfakh
#   Repo   : https://github.com/fakhfakhahmed/terraform-azure-aks-platform
#   This script is read-only with respect to Azure: it changes your local
#   kubeconfig (~/.kube/config) and nothing else. No cost.

set -euo pipefail

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
USE_COLOR=1
[[ -n "${NO_COLOR:-}" ]] && USE_COLOR=0
[[ -t 1 ]] || USE_COLOR=0

C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
C_RED=$'\033[31m'; C_GRAY=$'\033[90m'; C_WHITE=$'\033[37m'
C_RESET=$'\033[0m'

write_colored() { if [[ "$USE_COLOR" -eq 1 ]]; then printf '%s%s%s\n' "$2" "$1" "$C_RESET"; else printf '%s\n' "$1"; fi; }
write_step() { write_colored $'\n==> '"$1" "$C_CYAN"; }
write_ok()   { write_colored "    $1" "$C_GREEN"; }
write_warn() { write_colored "    $1" "$C_YELLOW"; }
write_err()  { write_colored "    $1" "$C_RED"; }
write_info() { write_colored "    $1" "$C_GRAY"; }

# run FILEPATH ARGS... -- ERRORMESSAGE
run() {
  local args=() errmsg="" seen_sep=0
  for a in "$@"; do
    if [[ "$seen_sep" -eq 0 && "$a" == "--" ]]; then seen_sep=1; continue; fi
    if [[ "$seen_sep" -eq 0 ]]; then args+=("$a"); else errmsg+="${errmsg:+$'\n'}$a"; fi
  done
  if "${args[@]}"; then
    return 0
  else
    local code=$?
    write_err "${errmsg:-'${args[*]}' failed with exit code $code.}"
    exit 1
  fi
}

# run_soft FILEPATH ARGS...
# Runs a command, captures combined stdout+stderr and NEVER throws - sets
# globals SOFT_EXIT and SOFT_OUTPUT instead. Used for the verification steps,
# where a failure is information to interpret (private cluster? missing
# RBAC?) rather than a reason to abort. This mirrors Invoke-NativeSoft in the
# ps1 script; bash functions can't easily return a compound value, hence the
# two globals instead of a struct.
SOFT_EXIT=0
SOFT_OUTPUT=""
run_soft() {
  set +e
  SOFT_OUTPUT=$("$@" 2>&1)
  SOFT_EXIT=$?
  set -e
}

get_tf_output_value() { # outputs_json name -> value or ""
  local json="$1" name="$2"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r --arg n "$name" '.[$n].value // empty'
  else
    printf '%s' "$json" | grep -o "\"$name\"[[:space:]]*:[[:space:]]*{[^}]*}" \
      | grep -o '"value"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 | sed -E 's/.*:"//; s/"$//'
  fi
}

show_private_cluster_guidance() { # cluster group
  local cluster="$1" group="$2"
  write_colored "" "$C_YELLOW"
  write_colored "    ----------------------------------------------------------------------" "$C_YELLOW"
  write_colored "    THE API SERVER IS NOT REACHABLE FROM THIS NETWORK" "$C_YELLOW"
  write_colored "    ----------------------------------------------------------------------" "$C_YELLOW"
  write_info 'This cluster has a private API server. Its FQDN resolves to a private IP inside'
  write_info 'the cluster VNet, so kubectl from a laptop on the public internet cannot reach it.'
  write_info 'This is working as designed - it is not a broken kubeconfig.'
  write_colored "" "$C_GRAY"
  write_info 'Four legitimate ways in, roughly in order of convenience:'
  write_colored "" "$C_GRAY"
  write_info '  1. az aks command invoke - runs a command in a managed pod inside the cluster.'
  write_info '     No network access required; needs the "Azure Kubernetes Service Cluster'
  write_info '     User" role plus Microsoft.ContainerService/managedClusters/runcommand/action.'
  write_info ''
  write_info "       az aks command invoke --resource-group $group --name $cluster \\"
  write_info '         --command "kubectl get nodes -o wide"'
  write_info ''
  write_info '  2. A jumpbox/bastion VM inside the cluster VNet (or a peered one). Use Azure'
  write_info '     Bastion rather than exposing SSH/RDP to the internet.'
  write_info ''
  write_info '  3. A VPN gateway or ExpressRoute circuit into the VNet, with the private DNS'
  write_info '     zone (privatelink.<region>.azmk8s.io) linked to the network you dial in from.'
  write_info '     Forgetting the DNS zone link is the usual cause of "no such host" over VPN.'
  write_info ''
  write_info '  4. A Private Endpoint for the cluster in a hub VNet your workstation can route'
  write_info '     to, again with the private DNS zone linked.'
  write_colored "" "$C_GRAY"
  write_info 'Check whether the cluster really is private:'
  write_info "    az aks show -g $group -n $cluster --query apiServerAccessProfile -o json"
  write_colored "    ----------------------------------------------------------------------" "$C_YELLOW"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
usage() {
  echo "Usage: $0 <dev|staging|prod> [--cluster-name NAME --resource-group GROUP] [--admin] [--skip-verify]" >&2
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

ENVIRONMENT="$1"; shift
case "$ENVIRONMENT" in
  dev|staging|prod) ;;
  *) echo "Environment must be one of: dev, staging, prod (got '$ENVIRONMENT')" >&2; usage; exit 1 ;;
esac

CLUSTER_NAME=""
RESOURCE_GROUP=""
ADMIN=0
SKIP_VERIFY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster-name)
      [[ $# -ge 2 ]] || { echo "--cluster-name requires a value" >&2; exit 1; }
      CLUSTER_NAME="$2"; shift 2 ;;
    --resource-group)
      [[ $# -ge 2 ]] || { echo "--resource-group requires a value" >&2; exit 1; }
      RESOURCE_GROUP="$2"; shift 2 ;;
    --admin) ADMIN=1; shift ;;
    --skip-verify) SKIP_VERIFY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -n "$CLUSTER_NAME" && -z "$RESOURCE_GROUP" ]]; then
  echo "--cluster-name requires --resource-group (and vice versa)." >&2
  exit 1
fi
if [[ -n "$RESOURCE_GROUP" && -z "$CLUSTER_NAME" ]]; then
  echo "--resource-group requires --cluster-name (and vice versa)." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_DIR="$REPO_ROOT/envs/$ENVIRONMENT"

write_colored "" "$C_WHITE"
write_colored "  terraform-azure-aks-platform :: connect-aks [$ENVIRONMENT]" "$C_WHITE"
write_colored "  repo root: $REPO_ROOT" "$C_GRAY"

if ! az_path=$(command -v az 2>/dev/null); then
  write_err "az was not found on PATH. Install: winget install Microsoft.AzureCLI"
  exit 1
fi
if ! kubectl_path=$(command -v kubectl 2>/dev/null); then
  write_err "kubectl was not found on PATH. Install: az aks install-cli"
  exit 1
fi

# -- resolve the cluster ------------------------------------------------------------
if [[ -z "$CLUSTER_NAME" ]]; then
  write_step 'Resolving the cluster from Terraform outputs'

  if [[ ! -d "$ENV_DIR" ]]; then
    write_err "Environment directory '$ENV_DIR' does not exist, and no --cluster-name/--resource-group were supplied."
    exit 1
  fi

  if ! terraform_path=$(command -v terraform 2>/dev/null); then
    write_err "terraform was not found on PATH, so the cluster name cannot be resolved. Pass --cluster-name and --resource-group explicitly."
    exit 1
  fi

  ORIGINAL_DIR="$(pwd)"
  cd "$ENV_DIR"
  run_soft "$terraform_path" output -json
  outputs_json="$SOFT_OUTPUT"
  outputs_exit="$SOFT_EXIT"
  cd "$ORIGINAL_DIR"

  if [[ "$outputs_exit" -ne 0 ]]; then
    write_err 'terraform output -json failed.'
    write_info 'Most likely this environment is not initialised on this machine.'
    write_info "Fix:   ./scripts/init-env.sh $ENVIRONMENT"
    write_info 'Or bypass Terraform entirely:'
    write_info "       ./scripts/connect-aks.sh $ENVIRONMENT --cluster-name <name> --resource-group <rg>"
    write_info ''
    write_info "terraform said: $outputs_json"
    exit 1
  fi

  CLUSTER_NAME=$(get_tf_output_value "$outputs_json" aks_cluster_name)
  RESOURCE_GROUP=$(get_tf_output_value "$outputs_json" resource_group_name)

  if [[ -z "$CLUSTER_NAME" || -z "$RESOURCE_GROUP" ]]; then
    write_err "Outputs 'aks_cluster_name' and/or 'resource_group_name' are missing or empty for '$ENVIRONMENT'. Has it been applied yet? (./scripts/apply-env.sh $ENVIRONMENT). Alternatively pass --cluster-name and --resource-group."
    exit 1
  fi
else
  write_step 'Using the cluster supplied on the command line'
fi

write_ok "cluster        : $CLUSTER_NAME"
write_ok "resource group : $RESOURCE_GROUP"

# -- is it private? -------------------------------------------------------------------
# Asking up front sets expectations before kubectl hangs for 30 seconds.
IS_PRIVATE=0
run_soft "$az_path" aks show --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" \
  --query apiServerAccessProfile.enablePrivateCluster --output tsv
if [[ "$SOFT_EXIT" -eq 0 ]]; then
  trimmed=$(printf '%s' "$SOFT_OUTPUT" | tr -d '[:space:]')
  if [[ "${trimmed,,}" == "true" ]]; then
    IS_PRIVATE=1
    write_warn 'This is a PRIVATE cluster - the API server has no public endpoint.'
  else
    write_ok 'public API server endpoint (authorized IP ranges may still apply)'
  fi
else
  write_warn 'Could not query the cluster with az aks show. Continuing anyway.'
  write_info "az said: $SOFT_OUTPUT"
fi

# -- credentials ------------------------------------------------------------------------
write_step 'az aks get-credentials'

CRED_ARGS=(aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" --overwrite-existing)
if [[ "$ADMIN" -eq 1 ]]; then
  write_warn '--admin requested. These clusters set local_account_disabled = true, so admin'
  write_warn 'credentials are expected to be refused. Use Entra ID + Azure RBAC instead.'
  CRED_ARGS+=(--admin)
fi

# --overwrite-existing avoids the "A different object named X already exists
# in your kubeconfig" error that otherwise appears every time a cluster is
# recreated.
run "$az_path" "${CRED_ARGS[@]}" -- "az aks get-credentials failed.

Common causes:
  * Not logged in / wrong subscription -> az login; az account set --subscription <id>
  * Missing the 'Azure Kubernetes Service Cluster User' role on the cluster
  * The cluster does not exist (wrong environment, or not applied yet)
  * --admin on a cluster with local accounts disabled (expected; drop --admin)"
write_ok 'kubeconfig updated'

# -- kubelogin -----------------------------------------------------------------------------
write_step 'kubelogin convert-kubeconfig -l azurecli'

if ! kubelogin_path=$(command -v kubelogin 2>/dev/null); then
  write_err 'kubelogin is NOT installed - and these clusters cannot be used without it.'
  write_info 'The kubeconfig just written uses an exec credential plugin called "kubelogin".'
  write_info 'Until it is on PATH, every kubectl command will fail with:'
  write_info '    exec: executable kubelogin not found'
  write_info ''
  write_info 'Install one of:'
  write_info '    az aks install-cli                                  (installs kubectl + kubelogin)'
  write_info '    winget install Microsoft.Azure.Kubelogin'
  write_info '    brew install Azure/kubelogin/kubelogin'
  write_info ''
  write_info 'Then re-run this script.'
  exit 1
fi

# -l azurecli reuses the token the Azure CLI already holds - no second
# interactive login, and no device-code dance. On a headless host use:
# kubelogin convert-kubeconfig -l devicecode
run "$kubelogin_path" convert-kubeconfig -l azurecli -- \
  'kubelogin convert-kubeconfig failed. Is your az login still valid? Try: az account get-access-token'
write_ok 'kubeconfig converted for Entra ID (azurecli) authentication'

if [[ "$SKIP_VERIFY" -eq 1 ]]; then
  write_step 'Verification skipped (--skip-verify)'
  exit 0
fi

# -- verification ---------------------------------------------------------------------------
write_step 'kubectl config current-context'
run_soft "$kubectl_path" config current-context
if [[ "$SOFT_EXIT" -ne 0 ]]; then
  write_err "kubectl could not read the current context. Is KUBECONFIG pointing somewhere unexpected? (KUBECONFIG=${KUBECONFIG:-})"
  exit 1
fi
write_ok "$(printf '%s' "$SOFT_OUTPUT" | tr -d '\r\n')"

write_step 'kubectl get nodes -o wide'
run_soft "$kubectl_path" get nodes -o wide

if [[ "$SOFT_EXIT" -eq 0 ]]; then
  printf '%s\n' "$SOFT_OUTPUT"
  write_ok 'API server reachable and the request was authorized.'
else
  text="$SOFT_OUTPUT"

  # Distinguish "cannot reach the API server" from "reached it and was refused".
  unreachable=0
  if printf '%s' "$text" | grep -qiE 'i/o timeout|dial tcp|no such host|connection refused|context deadline exceeded|unable to connect to the server'; then
    unreachable=1
  fi
  forbidden=0
  if printf '%s' "$text" | grep -qiE 'forbidden|cannot list resource'; then
    forbidden=1
  fi

  write_err 'kubectl get nodes failed.'
  write_info "$text"

  if [[ "$forbidden" -eq 1 ]]; then
    write_colored "" "$C_YELLOW"
    write_warn 'You reached the API server but Azure RBAC refused the request.'
    write_warn 'Authentication worked; AUTHORIZATION did not. You need an Azure role on the cluster:'
    write_info ''
    write_info '    az role assignment create \'
    write_info '      --assignee "$(az ad signed-in-user show --query id -o tsv)" \'
    write_info '      --role "Azure Kubernetes Service RBAC Cluster Admin" \'
    write_info "      --scope \"\$(az aks show -g $RESOURCE_GROUP -n $CLUSTER_NAME --query id -o tsv)\""
    write_info ''
    write_info 'Role assignments can take a couple of minutes to propagate.'
  elif [[ "$unreachable" -eq 1 ]]; then
    if [[ "$IS_PRIVATE" -eq 1 ]]; then
      show_private_cluster_guidance "$CLUSTER_NAME" "$RESOURCE_GROUP"
    else
      write_colored "" "$C_YELLOW"
      write_warn 'The API server is public but still unreachable. The usual cause is an'
      write_warn 'authorized IP range that does not include your current egress address.'
      write_info ''
      write_info '    Current public IP:  (curl https://ifconfig.me)'
      write_info "    Allowed ranges   :  az aks show -g $RESOURCE_GROUP -n $CLUSTER_NAME --query apiServerAccessProfile.authorizedIpRanges -o json"
      write_info ''
      write_info 'If you are on a VPN or a corporate proxy, your egress IP is not what you think.'
      show_private_cluster_guidance "$CLUSTER_NAME" "$RESOURCE_GROUP"
    fi
  else
    write_warn 'Unrecognised failure. Re-run with: kubectl get nodes -v=6   for verbose transport logs.'
  fi
  exit 1
fi

write_step 'kubectl get pods -A'
run_soft "$kubectl_path" get pods -A
if [[ "$SOFT_EXIT" -eq 0 ]]; then
  printf '%s\n' "$SOFT_OUTPUT"
else
  write_warn 'Could not list pods across all namespaces (an RBAC scope issue, most likely).'
  write_info "$SOFT_OUTPUT"
fi

# -- platform add-on sanity checks --------------------------------------------------------
# These two are what make the platform's security story work:
#   * workload identity webhook  -> projects federated tokens into pods (no secrets)
#   * secrets-store CSI + azure  -> mounts Key Vault secrets as files (no secrets in etcd)
# If either is missing, applications that rely on them fail in confusing ways
# at runtime, so it is worth 2 seconds to confirm now.
write_step 'Platform add-on checks'

check_addon() { # label selector why
  local label="$1" selector="$2" why="$3"
  run_soft "$kubectl_path" get pods -n kube-system -l "$selector" --no-headers
  local found=0
  if [[ "$SOFT_EXIT" -eq 0 && -n "$SOFT_OUTPUT" ]] && ! printf '%s' "$SOFT_OUTPUT" | grep -q 'No resources found'; then
    found=1
  fi

  if [[ "$found" -eq 1 ]]; then
    local total=0 running=0
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      total=$((total + 1))
      printf '%s' "$line" | grep -q 'Running' && running=$((running + 1))
    done <<< "$SOFT_OUTPUT"
    if [[ "$running" -eq "$total" ]]; then
      write_ok "$label: $running/$total pods Running"
    else
      write_warn "$label: only $running/$total pods Running"
      write_info "    kubectl -n kube-system get pods -l $selector"
    fi
  else
    write_warn "$label: not found"
    write_info "    $why"
  fi
}

check_addon 'workload identity webhook' 'app=azure-wi-webhook-controller-manager' \
  'Required for Entra Workload Identity. Enable with oidc_issuer_enabled + workload_identity_enabled on the cluster.'
check_addon 'secrets-store CSI driver' 'app=secrets-store-csi-driver' \
  'Required to mount Key Vault secrets as volumes. Enable the key_vault_secrets_provider add-on.'
check_addon 'secrets-store azure provider' 'app=csi-secrets-store-provider-azure' \
  'The Azure provider for the CSI driver. Ships with the key_vault_secrets_provider add-on.'

write_step 'Connected'
write_ok "kubectl is now pointed at '$CLUSTER_NAME' ($ENVIRONMENT)."
write_info 'Switch back later with:  kubectl config use-context <context>'
write_info "Remove this context when done:  kubectl config delete-context $CLUSTER_NAME"
exit 0

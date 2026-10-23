#!/usr/bin/env bash
#
# bootstrap-backend.sh
#
# SYNOPSIS
#   One-time bootstrap: creates the Terraform remote-state backend and the
#   GitHub OIDC Azure AD application, then prints everything you need to
#   wire the repo up. Bash port of bootstrap-backend.ps1.
#
# DESCRIPTION
#   This is the chicken-and-egg stack. Every environment under envs/ stores
#   its state in an Azure Storage Account - but something has to create that
#   storage account first, and that something cannot itself use a remote
#   backend that does not exist yet. So the bootstrap/ stack runs with LOCAL
#   state.
#
#   What it creates:
#     * a resource group for Terraform state
#     * a storage account + the "tfstate" blob container (versioning on)
#     * an Entra ID (Azure AD) application + federated credential for GitHub
#       Actions OIDC, so CI never needs a client secret
#
#   What this script does on top of `terraform apply`:
#     1. Sanity-checks tooling and your Azure login, and pins
#        ARM_SUBSCRIPTION_ID.
#     2. Runs init + plan in bootstrap/ and shows you the plan.
#     3. Asks for confirmation (skippable with --force) BEFORE creating
#        billable resources.
#     4. Applies, reads `terraform output -json`, and prints:
#          (a) the backend.hcl body for each of envs/dev, envs/staging,
#              envs/prod
#          (b) the `gh variable set` commands for the GitHub Actions workflow
#     5. Optionally writes the three backend.hcl files for you
#        (--write-backend-files).
#
#   IMPORTANT - LOCAL STATE
#   bootstrap/terraform.tfstate lives on this machine only. It is gitignored
#   and it must stay that way: it contains the storage account name and the
#   Entra app object ids. Back it up somewhere safe, or accept that
#   re-running bootstrap on another machine will try to create everything
#   again.
#
# USAGE
#   ./scripts/bootstrap-backend.sh [options]
#
#   --subscription-id ID     Target Azure subscription. Default: whatever
#                            `az account show` reports. Runs `az account set`
#                            first when supplied.
#   --location LOCATION      Azure region for the state RG/storage account.
#                            Default: westeurope.
#   --prefix PREFIX          Short naming prefix (<=6 lowercase alnum chars).
#                            Default: afk (Ahmed Fakhfakh).
#   --write-backend-files    Also write envs/<env>/backend.hcl for dev,
#                            staging, prod. Existing files are backed up to
#                            backend.hcl.bak first.
#   --force                  Skip the interactive confirmation. Billable
#                            resources are still created.
#
# NOTES
#   Author : Ahmed Fakhfakh
#   Repo   : https://github.com/fakhfakhahmed/terraform-azure-aks-platform
#   Run this ONCE per subscription. It is idempotent: a second run should
#   plan zero changes.

set -euo pipefail

# ---------------------------------------------------------------------------
# Bash gotchas worth calling out (see preflight.sh for the longer version):
#   - `set -u`: unset vars are a hard error, so every optional flag is read
#     with ${VAR:-default} and the option parser below only ever reads $1/$2
#     after checking $# first.
#   - Native command failures: unlike PowerShell, bash's `set -e` DOES stop
#     the script when `terraform`/`az` exit non-zero - we don't need a
#     PowerShell-style Invoke-Native wrapper for that part. We still write a
#     small `run` helper below purely to attach a friendly, multi-line error
#     message to the generic "command failed" that `set -e` would otherwise
#     produce with no context.
#   - Arrays: `-var` flags are built into an array (TF_VAR_ARGS=()) and must
#     be expanded as "${TF_VAR_ARGS[@]}" (quoted, with @) everywhere, never
#     bare $TF_VAR_ARGS, or an empty array / a value with spaces will corrupt
#     the terraform command line.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
SUBSCRIPTION_ID=""
LOCATION="westeurope"
PREFIX="afk"
WRITE_BACKEND_FILES=0
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription-id)
      [[ $# -ge 2 ]] || { echo "--subscription-id requires a value" >&2; exit 1; }
      SUBSCRIPTION_ID="$2"; shift 2 ;;
    --location)
      [[ $# -ge 2 ]] || { echo "--location requires a value" >&2; exit 1; }
      LOCATION="$2"; shift 2 ;;
    --prefix)
      [[ $# -ge 2 ]] || { echo "--prefix requires a value" >&2; exit 1; }
      PREFIX="$2"; shift 2 ;;
    --write-backend-files) WRITE_BACKEND_FILES=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help)
      sed -n '2,55p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if ! [[ "$PREFIX" =~ ^[a-z0-9]{2,6}$ ]]; then
  echo "--prefix must be 2-6 lowercase alphanumeric characters (got '$PREFIX')" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
USE_COLOR=1
[[ -n "${NO_COLOR:-}" ]] && USE_COLOR=0
[[ -t 1 ]] || USE_COLOR=0

C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
C_RED=$'\033[31m'; C_GRAY=$'\033[90m'; C_MAGENTA=$'\033[35m'; C_WHITE=$'\033[37m'
C_RESET=$'\033[0m'

write_colored() { if [[ "$USE_COLOR" -eq 1 ]]; then printf '%s%s%s\n' "$2" "$1" "$C_RESET"; else printf '%s\n' "$1"; fi; }
write_step() { write_colored $'\n==> '"$1" "$C_CYAN"; }
write_ok()   { write_colored "    $1" "$C_GREEN"; }
write_warn() { write_colored "    $1" "$C_YELLOW"; }
write_err()  { write_colored "    $1" "$C_RED"; }
write_info() { write_colored "    $1" "$C_GRAY"; }

write_banner() { # color, then one line per remaining arg
  local color="$1"; shift
  local border
  border=$(printf '*%.0s' $(seq 1 78))
  write_colored "" "$color"
  write_colored "$border" "$color"
  for line in "$@"; do
    printf -v padded '%-75s' "$line"
    write_colored "* ${padded}*" "$color"
  done
  write_colored "$border" "$color"
  write_colored "" "$color"
}

# run FILEPATH ARGS... -- ERRORMESSAGE
# Executes a command; on non-zero exit prints ERRORMESSAGE then exits 1.
# (set -e would already stop the script, but with a bare "command failed"
# message - this wrapper gives operators the same actionable hints the ps1
# version prints.)
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

# capture FILEPATH ARGS... -- ERRORMESSAGE
# Like `run` but echoes stdout instead of letting it stream, for capturing
# JSON. Errors print to stderr (via the `run` command itself) ensuring
# nothing non-JSON contaminates $(...) capture.
capture() {
  local args=() errmsg="" seen_sep=0
  for a in "$@"; do
    if [[ "$seen_sep" -eq 0 && "$a" == "--" ]]; then seen_sep=1; continue; fi
    if [[ "$seen_sep" -eq 0 ]]; then args+=("$a"); else errmsg+="${errmsg:+$'\n'}$a"; fi
  done
  local out
  if out=$("${args[@]}" 2>/tmp/bootstrap-backend.$$.err); then
    rm -f "/tmp/bootstrap-backend.$$.err"
    printf '%s' "$out"
  else
    local code=$?
    local stderr_text
    stderr_text=$(cat "/tmp/bootstrap-backend.$$.err" 2>/dev/null || true)
    rm -f "/tmp/bootstrap-backend.$$.err"
    write_err "${errmsg:-'${args[*]}' failed with exit code $code.}"
    [[ -n "$stderr_text" ]] && write_info "$stderr_text"
    exit 1
  fi
}

confirm_or_exit() { # question expected
  local question="$1" expected="${2:-yes}"
  if [[ ! -t 0 ]]; then
    write_err "A confirmation is required but this host is non-interactive. Re-run with --force only if you have already reviewed the plan."
    exit 1
  fi
  write_colored "" "$C_YELLOW"
  write_colored "$question" "$C_YELLOW"
  read -r -p "Type '$expected' to continue: " answer
  if [[ "$answer" != "$expected" ]]; then
    write_err "Aborted - you typed '$answer'. Nothing was applied."
    exit 1
  fi
}

get_tf_output_value() { # outputs_json name -> value or ""
  local json="$1" name="$2"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r --arg n "$name" '.[$n].value // empty'
  else
    # Tolerant fallback: find "<name>": { ... "value": "X" ... }
    printf '%s' "$json" | grep -o "\"$name\"[[:space:]]*:[[:space:]]*{[^}]*}" \
      | grep -o '"value"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 | sed -E 's/.*:"//; s/"$//'
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
BOOTSTRAP_DIR="$REPO_ROOT/bootstrap"
GITHUB_REPO="fakhfakhahmed/terraform-azure-aks-platform"
ENVIRONMENTS=(dev staging prod)
PLAN_FILE="tfplan.bootstrap"

write_colored "" "$C_WHITE"
write_colored "  terraform-azure-aks-platform :: bootstrap-backend" "$C_WHITE"
write_colored "  repo root: $REPO_ROOT" "$C_GRAY"

if [[ ! -d "$BOOTSTRAP_DIR" ]]; then
  write_err "bootstrap/ directory not found at '$BOOTSTRAP_DIR'. Run this from a full clone of $GITHUB_REPO."
  exit 1
fi

write_banner "$C_YELLOW" \
  'COST WARNING - this script CREATES BILLABLE AZURE RESOURCES.' \
  '' \
  'It provisions a resource group, a storage account (GRS/LRS + versioning) and a' \
  'blob container. A state storage account is cheap - typically well under 1 EUR' \
  'per month at this volume - but it is NOT free, and it is not deleted for you.' \
  '' \
  'It also creates an Entra ID application + federated credential for GitHub OIDC.' \
  'That is free, but it is a security principal: treat its lifecycle seriously.' \
  '' \
  'STATE IS LOCAL: bootstrap/terraform.tfstate stays on this machine. Back it up.'

# -- tooling + azure context --------------------------------------------------
write_step 'Checking tooling and Azure context'
if ! terraform_path=$(command -v terraform 2>/dev/null); then
  write_err "Required tool 'terraform' was not found on PATH. Install: winget install HashiCorp.Terraform"
  write_info "Run ./scripts/preflight.sh for the full checklist."
  exit 1
fi
if ! az_path=$(command -v az 2>/dev/null); then
  write_err "Required tool 'az' was not found on PATH. Install: winget install Microsoft.AzureCLI"
  write_info "Run ./scripts/preflight.sh for the full checklist."
  exit 1
fi
write_ok "terraform: $terraform_path"
write_ok "az:        $az_path"

if [[ -n "$SUBSCRIPTION_ID" ]]; then
  write_info "Setting the active az subscription to $SUBSCRIPTION_ID ..."
  run "$az_path" account set --subscription "$SUBSCRIPTION_ID" -- \
    "az account set failed for subscription '$SUBSCRIPTION_ID'. Are you logged in (az login) and does this account have access?"
fi

account_json=$(capture "$az_path" account show --output json -- \
  "az account show failed - you are not logged in. Run: az login  (add --use-device-code on a headless host).")

if command -v jq >/dev/null 2>&1; then
  resolved_subscription_id=$(printf '%s' "$account_json" | jq -r '.id')
  resolved_tenant_id=$(printf '%s' "$account_json" | jq -r '.tenantId')
  resolved_sub_name=$(printf '%s' "$account_json" | jq -r '.name')
else
  extract_json_field() { printf '%s' "$2" | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -n1 | sed -E 's/.*:"//; s/"$//'; }
  resolved_subscription_id=$(extract_json_field id "$account_json")
  resolved_tenant_id=$(extract_json_field tenantId "$account_json")
  resolved_sub_name=$(extract_json_field name "$account_json")
fi

[[ -z "$SUBSCRIPTION_ID" ]] && SUBSCRIPTION_ID="$resolved_subscription_id"

write_ok "subscription: $resolved_sub_name"
write_ok "id:           $resolved_subscription_id"
write_ok "tenant:       $resolved_tenant_id"
write_ok "location:     $LOCATION"
write_ok "prefix:       $PREFIX"

# azurerm ~> 4.0 made subscription_id mandatory on the provider block (it no
# longer silently inherits the az CLI default). Exporting ARM_SUBSCRIPTION_ID
# guarantees provider and CLI agree even if the stack has no such variable.
export ARM_SUBSCRIPTION_ID="$resolved_subscription_id"
write_info 'ARM_SUBSCRIPTION_ID exported for this process (azurerm 4.x requires an explicit subscription).'

# -- build the -var list from what bootstrap/ actually declares ---------------
# Hard-coding -var flags is brittle: if bootstrap/variables.tf does not
# declare a variable, Terraform aborts with "Value for undeclared variable".
# Parse the declarations instead and only pass what exists.
write_step 'Resolving bootstrap input variables'

declared_vars=()
if compgen -G "$BOOTSTRAP_DIR/*.tf" > /dev/null; then
  while IFS= read -r var_name; do
    [[ -n "$var_name" ]] && declared_vars+=("$var_name")
  done < <(grep -hoE '^[[:space:]]*variable[[:space:]]+"[^"]+"' "$BOOTSTRAP_DIR"/*.tf 2>/dev/null \
            | sed -E 's/^[[:space:]]*variable[[:space:]]+"([^"]+)"/\1/')
fi

contains_var() { # name -> 0 if in declared_vars
  local target="$1" v
  for v in "${declared_vars[@]}"; do [[ "$v" == "$target" ]] && return 0; done
  return 1
}

TF_VAR_ARGS=()

for name in subscription_id azure_subscription_id; do
  if contains_var "$name"; then
    TF_VAR_ARGS+=("-var" "${name}=${SUBSCRIPTION_ID}")
    write_ok "-var $name=$SUBSCRIPTION_ID"
    break
  fi
done
for name in location azure_location region; do
  if contains_var "$name"; then
    TF_VAR_ARGS+=("-var" "${name}=${LOCATION}")
    write_ok "-var $name=$LOCATION"
    break
  fi
done
for name in prefix name_prefix naming_prefix; do
  if contains_var "$name"; then
    TF_VAR_ARGS+=("-var" "${name}=${PREFIX}")
    write_ok "-var $name=$PREFIX"
    break
  fi
done

if [[ ${#TF_VAR_ARGS[@]} -eq 0 ]]; then
  write_info 'bootstrap/ declares none of the expected variables - relying on its defaults / terraform.tfvars.'
fi

# -- init + plan ----------------------------------------------------------------
# A trap ensures we always return to the original directory even if a step
# below fails, mirroring the ps1 script's try/finally { Pop-Location }.
ORIGINAL_DIR="$(pwd)"
cleanup() { cd "$ORIGINAL_DIR"; }
trap cleanup EXIT

cd "$BOOTSTRAP_DIR"

write_step 'terraform init (bootstrap uses LOCAL state - no -backend-config here)'
run "$terraform_path" init -input=false -- \
  'terraform init failed in bootstrap/. Check your network/proxy and that the provider mirror is reachable.'

write_step 'terraform validate'
run "$terraform_path" validate -- \
  'terraform validate failed in bootstrap/. Fix the configuration before applying.'

write_step 'terraform plan'
plan_args=(plan -input=false -lock-timeout=5m "-out=$PLAN_FILE")
[[ ${#TF_VAR_ARGS[@]} -gt 0 ]] && plan_args+=("${TF_VAR_ARGS[@]}")
run "$terraform_path" "${plan_args[@]}" -- 'terraform plan failed in bootstrap/.'

if [[ "$FORCE" -eq 0 ]]; then
  confirm_or_exit "Review the plan above. Continuing will CREATE the resources listed, in:
  subscription : $resolved_sub_name ($resolved_subscription_id)
  location     : $LOCATION" "yes"
else
  write_warn '--force supplied: skipping confirmation and applying immediately.'
fi

write_step 'terraform apply'
run "$terraform_path" apply -input=false -lock-timeout=5m "$PLAN_FILE" -- \
  'terraform apply failed in bootstrap/. The stack may be partially created - re-run this script, it is idempotent.'

# A saved plan is single-use; leaving it around invites someone to apply a
# stale plan.
rm -f "$PLAN_FILE"

write_step 'Reading outputs'
outputs_json=$(capture "$terraform_path" output -json -- 'terraform output -json failed in bootstrap/.')

cd "$ORIGINAL_DIR"
trap - EXIT

get_required_output() {
  local v
  v=$(get_tf_output_value "$outputs_json" "$1")
  if [[ -z "$v" ]]; then
    write_err "Bootstrap output '$1' is missing. Expected outputs: state_resource_group_name, state_storage_account_name, state_container_name, github_actions_client_id, tenant_id, subscription_id. Check bootstrap/outputs.tf."
    exit 1
  fi
  printf '%s' "$v"
}

state_rg=$(get_required_output state_resource_group_name)
state_sa=$(get_required_output state_storage_account_name)
state_container=$(get_required_output state_container_name)
client_id=$(get_required_output github_actions_client_id)
tenant_id=$(get_required_output tenant_id)
sub_id=$(get_required_output subscription_id)

write_ok "state resource group : $state_rg"
write_ok "state storage account: $state_sa"
write_ok "state container      : $state_container"
write_ok "github oidc client id: $client_id"

# -- backend.hcl ----------------------------------------------------------------
write_step 'Backend configuration (envs/<env>/backend.hcl)'
write_info 'backend.hcl is gitignored. backend.hcl.example is the committed template.'
write_info 'Each env initialises with:  terraform init -reconfigure -backend-config=backend.hcl'
write_colored "" "$C_GRAY"

new_backend_hcl_content() { # environment_name
  local env_name="$1"
  cat <<EOF
# Generated by scripts/bootstrap-backend.sh on $(date '+%Y-%m-%d %H:%M:%S %z')
# Partial backend configuration for the '$env_name' environment.
# Consumed by: terraform init -reconfigure -backend-config=backend.hcl
# DO NOT COMMIT - this file is gitignored; backend.hcl.example is the committed template.

resource_group_name  = "$state_rg"
storage_account_name = "$state_sa"
container_name       = "$state_container"
key                  = "$env_name/terraform.tfstate"

# Authenticate to the state blob with the caller's Entra ID identity (az login
# locally, the federated OIDC principal in CI) instead of a shared storage
# account access key. Keys are long-lived credentials with full data-plane
# access - avoid them.
use_azuread_auth = true
EOF
}

for env_name in "${ENVIRONMENTS[@]}"; do
  write_colored "----- envs/$env_name/backend.hcl -----" "$C_MAGENTA"
  new_backend_hcl_content "$env_name"
  write_colored "" "$C_GRAY"
done

if [[ "$WRITE_BACKEND_FILES" -eq 1 ]]; then
  write_step 'Writing backend.hcl files'
  for env_name in "${ENVIRONMENTS[@]}"; do
    env_dir="$REPO_ROOT/envs/$env_name"
    target="$env_dir/backend.hcl"
    if [[ -f "$target" ]]; then
      cp -f "$target" "$target.bak"
      write_warn "existing file backed up to $target.bak"
    fi
    mkdir -p "$env_dir"
    # printf (not a heredoc redirect with a trailing newline quirk) writes
    # plain UTF-8, no BOM - Terraform's HCL parser is picky about a leading
    # BOM, which is exactly the bug the ps1 version works around too.
    new_backend_hcl_content "$env_name" > "$target"
    write_ok "wrote $target"
  done
else
  write_info 'Re-run with --write-backend-files to have these written for you.'
fi

# -- GitHub configuration --------------------------------------------------------
write_step 'GitHub Actions configuration'
write_info 'These are repository VARIABLES, not secrets: with OIDC there is no client secret to'
write_info 'protect, and a client id / tenant id / subscription id are not sensitive on their own.'
write_info 'Access is controlled by the federated credential subject + the Azure role assignment.'
write_colored "" "$C_GRAY"
write_colored "----- paste into a shell with the gh CLI authenticated -----" "$C_MAGENTA"

echo "  gh variable set AZURE_CLIENT_ID        --repo $GITHUB_REPO --body \"$client_id\""
echo "  gh variable set AZURE_TENANT_ID        --repo $GITHUB_REPO --body \"$tenant_id\""
echo "  gh variable set AZURE_SUBSCRIPTION_ID  --repo $GITHUB_REPO --body \"$sub_id\""
echo "  gh variable set TFSTATE_RESOURCE_GROUP --repo $GITHUB_REPO --body \"$state_rg\""
echo "  gh variable set TFSTATE_STORAGE_ACCOUNT --repo $GITHUB_REPO --body \"$state_sa\""
echo "  gh variable set TFSTATE_CONTAINER      --repo $GITHUB_REPO --body \"$state_container\""
write_colored "" "$C_GRAY"

# -- closing notes ----------------------------------------------------------------
write_banner "$C_CYAN" \
  'BOOTSTRAP COMPLETE' \
  '' \
  'Next steps:' \
  '  1. ./scripts/init-env.sh dev' \
  '  2. ./scripts/plan-env.sh dev' \
  '  3. ./scripts/apply-env.sh dev        (creates the AKS cluster - costs money)' \
  '' \
  'Reminder: bootstrap/terraform.tfstate is LOCAL and gitignored. Back it up.' \
  'Reminder: tear dev down when you are done - see scripts/README.md.'

exit 0

#!/usr/bin/env bash
#
# init-env.sh
#
# SYNOPSIS
#   Initialises one environment root module against the shared azurerm
#   remote backend. Bash port of init-env.ps1.
#
# DESCRIPTION
#   Every environment lives in its own directory (envs/dev, envs/staging,
#   envs/prod) with its own state key in the shared storage account. There
#   are no Terraform workspaces here on purpose: a workspace is one
#   directory serving many environments, which makes per-environment
#   provider versions, variables and policy impossible to diverge safely.
#   Directory-per-environment is more files and far fewer surprises.
#
#   envs/<env>/backend.tf contains a PARTIAL backend block - no account
#   names, no keys. The concrete values come from envs/<env>/backend.hcl,
#   which is gitignored and is produced either by
#   scripts/bootstrap-backend.sh --write-backend-files or by hand from
#   backend.hcl.example.
#
#   This script:
#     1. validates the environment name,
#     2. fails fast with a copy-pasteable fix if backend.hcl is missing,
#     3. exports ARM_SUBSCRIPTION_ID (azurerm 4.x requires an explicit
#        subscription),
#     4. runs `terraform init -reconfigure -backend-config=backend.hcl`,
#     5. runs `terraform validate` as a free sanity check.
#
#   WHY -reconfigure AND NOT -migrate-state
#   -----------------------------------------------------------------------
#   -migrate-state asks Terraform to COPY state between backends and will
#   happily do so, interactively, when it detects a change. That is exactly
#   what you want once - when you genuinely move a backend - and exactly
#   what you do not want on a routine init, where a stale
#   .terraform/terraform.tfstate cache from a colleague's branch could
#   silently push state into the wrong container.
#
#   -reconfigure says: discard the cached backend settings, use what
#   backend.hcl says now, and do not touch any state. It is the safe,
#   repeatable, idempotent choice for an everyday init, and it is also what
#   the CI workflow runs. If you ever truly need to move state between
#   storage accounts, do it deliberately with -migrate-state (available
#   here behind --migrate-state) and after taking a backup:
#       terraform state pull > state-backup.json
#
# USAGE
#   ./scripts/init-env.sh <dev|staging|prod> [options]
#
#   --upgrade          Pass -upgrade to terraform init: re-resolves
#                       provider/module versions within versions.tf's
#                       constraints and rewrites .terraform.lock.hcl. Review
#                       the lock file diff and commit it.
#   --migrate-state     Use -migrate-state instead of -reconfigure. Only for
#                       a genuine backend move. Prompts.
#   --skip-validate     Skip the post-init `terraform validate`.
#
# NOTES
#   Author : Ahmed Fakhfakh
#   Repo   : https://github.com/fakhfakhahmed/terraform-azure-aks-platform
#   Safe to re-run: init is idempotent and creates nothing billable.

set -euo pipefail

# Gotcha: ENVIRONMENT below is read as the first *positional* argument. With
# `set -u`, touching $1 before confirming $# >= 1 would abort with "unbound
# variable" instead of a friendly usage message - hence the explicit check.

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

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
usage() {
  echo "Usage: $0 <dev|staging|prod> [--upgrade] [--migrate-state] [--skip-validate]" >&2
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

UPGRADE=0
MIGRATE_STATE=0
SKIP_VALIDATE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --upgrade) UPGRADE=1; shift ;;
    --migrate-state) MIGRATE_STATE=1; shift ;;
    --skip-validate) SKIP_VALIDATE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_DIR="$REPO_ROOT/envs/$ENVIRONMENT"

write_colored "" "$C_WHITE"
write_colored "  terraform-azure-aks-platform :: init-env [$ENVIRONMENT]" "$C_WHITE"
write_colored "  repo root: $REPO_ROOT" "$C_GRAY"

if ! terraform_path=$(command -v terraform 2>/dev/null); then
  write_err "terraform was not found on PATH. Install it (winget install HashiCorp.Terraform) and re-run ./scripts/preflight.sh."
  exit 1
fi

if [[ ! -d "$ENV_DIR" ]]; then
  write_err "Environment directory '$ENV_DIR' does not exist. Expected one of envs/dev, envs/staging, envs/prod in a full clone of fakhfakhahmed/terraform-azure-aks-platform."
  exit 1
fi

# -- backend.hcl must exist ----------------------------------------------------
BACKEND_FILE="$ENV_DIR/backend.hcl"
BACKEND_EXAMPLE="$ENV_DIR/backend.hcl.example"

if [[ ! -f "$BACKEND_FILE" ]]; then
  write_err "Missing backend configuration: $BACKEND_FILE"
  write_colored "" "$C_YELLOW"
  write_warn 'backend.hcl holds the remote-state coordinates and is intentionally gitignored,'
  write_warn 'so a fresh clone never has one. Pick one of these:'
  write_colored "" "$C_YELLOW"
  write_info '  1. Generate all three from the bootstrap outputs (recommended):'
  write_info '       ./scripts/bootstrap-backend.sh --write-backend-files'
  write_colored "" "$C_YELLOW"
  if [[ -f "$BACKEND_EXAMPLE" ]]; then
    write_info '  2. Copy the committed template and fill in the values:'
    write_info "       cp '$BACKEND_EXAMPLE' '$BACKEND_FILE'"
    write_info "       \${EDITOR:-nano} '$BACKEND_FILE'"
  else
    write_info '  2. Create it by hand with this shape:'
    write_info '       resource_group_name  = "<state rg>"'
    write_info '       storage_account_name = "<state storage account>"'
    write_info '       container_name       = "tfstate"'
    write_info "       key                  = \"$ENVIRONMENT/terraform.tfstate\""
    write_info '       use_azuread_auth     = true'
  fi
  write_colored "" "$C_YELLOW"
  write_info '  3. If a teammate already bootstrapped, ask them for the storage account name;'
  write_info '     it is not a secret (access is controlled by Entra ID RBAC, not by the name).'
  exit 1
fi

write_ok "backend config: $BACKEND_FILE"

# Cheap validation of the backend file so a typo surfaces here rather than as
# an opaque "Error: Failed to get existing workspaces" three minutes into init.
backend_text=$(cat "$BACKEND_FILE")
for key in resource_group_name storage_account_name container_name key; do
  if ! printf '%s' "$backend_text" | grep -qE "^[[:space:]]*${key}[[:space:]]*="; then
    write_warn "backend.hcl does not define '$key' - terraform init will prompt for it or fail."
  fi
done
expected_key="$ENVIRONMENT/terraform.tfstate"
if ! printf '%s' "$backend_text" | grep -qF "$expected_key"; then
  write_warn "backend.hcl does not contain the expected state key '$expected_key'."
  write_warn "Initialising '$ENVIRONMENT' against another environment's state key would be a very bad day."
  write_warn 'Double-check the file before continuing.'
fi

# -- ARM_SUBSCRIPTION_ID ---------------------------------------------------------
# azurerm ~> 4.0 no longer falls back to the az CLI's default subscription;
# the provider requires subscription_id explicitly or via this variable.
# Setting it here keeps the backend, the provider and the az CLI aligned.
if [[ -z "${ARM_SUBSCRIPTION_ID:-}" ]]; then
  if az_path=$(command -v az 2>/dev/null); then
    if sub_id=$("$az_path" account show --query id --output tsv 2>/dev/null) && [[ -n "$sub_id" ]]; then
      export ARM_SUBSCRIPTION_ID="$sub_id"
      write_info "ARM_SUBSCRIPTION_ID set from the active az login: $ARM_SUBSCRIPTION_ID"
    else
      write_warn 'Could not read the active subscription from az (not logged in?). Run: az login'
    fi
  fi
else
  write_info "ARM_SUBSCRIPTION_ID already set: $ARM_SUBSCRIPTION_ID"
fi

# -- init -------------------------------------------------------------------------
INIT_ARGS=(init -input=false -backend-config=backend.hcl)

if [[ "$MIGRATE_STATE" -eq 1 ]]; then
  write_warn '--migrate-state requested: Terraform will attempt to MOVE state between backends.'
  write_warn 'Take a backup first:  terraform state pull > state-backup.json'
  if [[ -t 0 ]]; then
    read -r -p "Type 'migrate' to continue: " answer
    if [[ "$answer" != "migrate" ]]; then
      write_err 'Aborted. Nothing was changed.'
      exit 1
    fi
  else
    write_err '--migrate-state requires an interactive confirmation and this host is non-interactive.'
    exit 1
  fi
  INIT_ARGS+=(-migrate-state)
else
  # See the header comment above for why this is the default.
  INIT_ARGS+=(-reconfigure)
fi

if [[ "$UPGRADE" -eq 1 ]]; then
  INIT_ARGS+=(-upgrade)
  write_info '--upgrade requested: provider/module versions will be re-resolved and .terraform.lock.hcl rewritten.'
  write_info 'Review the lock file diff and commit it with the change.'
fi

# Trap mirrors the ps1 script's try/finally { Pop-Location }: a mid-run
# failure must never strand the operator inside envs/<env>.
ORIGINAL_DIR="$(pwd)"
cleanup() { cd "$ORIGINAL_DIR"; }
trap cleanup EXIT

cd "$ENV_DIR"

write_step "terraform ${INIT_ARGS[*]}"
run "$terraform_path" "${INIT_ARGS[@]}" -- "terraform init failed for '$ENVIRONMENT'.

Common causes:
  * Not logged in / token expired          -> az login
  * No RBAC on the state storage account   -> you need 'Storage Blob Data Contributor'
                                              on the state storage account (use_azuread_auth
                                              means the account key is NOT used)
  * Wrong storage account or container     -> check $BACKEND_FILE
  * Corporate proxy blocking registry      -> set HTTPS_PROXY / NO_PROXY"

if [[ "$SKIP_VALIDATE" -eq 0 ]]; then
  write_step 'terraform validate'
  run "$terraform_path" validate -- "terraform validate failed for '$ENVIRONMENT'. The backend is initialised but the configuration has errors."
  write_ok 'configuration is syntactically valid'
fi

cd "$ORIGINAL_DIR"
trap - EXIT

write_step 'Done'
write_ok "'$ENVIRONMENT' is initialised against the remote backend."
write_info "Next:  ./scripts/plan-env.sh $ENVIRONMENT"
exit 0

#!/usr/bin/env bash
#
# cost-estimate.sh
#
# SYNOPSIS
#   Runs an Infracost cost breakdown for one environment. Bash twin of
#   cost-estimate.ps1 (both are new - there was no prior PowerShell script to
#   port for this one, so they were designed together, matching the house
#   style of the rest of scripts/).
#
# DESCRIPTION
#   A thin, friendly wrapper around the Infracost CLI. It exists so operators
#   do not have to remember Infracost's flags, and so a missing `infracost`
#   binary produces a clear, actionable message instead of
#   "infracost: command not found" with no context.
#
#   What it does:
#     1. Checks whether `infracost` is on PATH. If not, prints the install
#        link and a short explanation and exits with a distinct, documented
#        exit code (2) rather than erroring the whole pipeline harshly - a CI
#        job can choose to treat "not installed" as a soft warning.
#     2. If found, runs:
#            infracost breakdown --path envs/<env> --format table
#        optionally adding --terraform-plan-flags "-var-file=terraform.tfvars"
#        when that tfvars file exists in the environment.
#     3. Reminds the operator that Infracost needs an INFRACOST_API_KEY (the
#        free tier is enough for this repo) and that the result is an
#        ESTIMATE - cross-check it with docs/cost.md and the Azure Pricing
#        Calculator before trusting it for a budget.
#
#   WHY THIS IS NOT PART OF plan-env.sh
#   -----------------------------------------------------------------------
#   Infracost needs a Terraform plan (or generates one itself via
#   `infracost breakdown --path`), but unlike the conftest policy gate, a
#   cost estimate is advisory, not a pass/fail gate. Keeping it a separate,
#   opt-in script means plan-env.sh stays fast and conftest's exit code
#   remains the only thing that can fail a plan.
#
# USAGE
#   ./scripts/cost-estimate.sh <dev|staging|prod> [options]
#
#   --var-file FILE     Terraform tfvars file (relative to envs/<env>) passed
#                        through to Infracost's own Terraform invocation.
#                        Default: terraform.tfvars (only used if it exists).
#   --format FORMAT      table (default) | json | html | diff. See
#                        https://www.infracost.io/docs/features/cli_commands/#breakdown
#   --out-file FILE      Also write the Infracost output to a file (handy for
#                        attaching a cost estimate to a pull request).
#
# EXIT CODES
#   0 = breakdown produced.
#   1 = infracost ran but failed (bad Terraform, auth error, etc).
#   2 = infracost is NOT installed. This is deliberate and documented: it is
#       a soft signal, not a hard pipeline failure - see the install message
#       printed below, and https://www.infracost.io/docs/#quick-start
#
# NOTES
#   Author : Ahmed Fakhfakh
#   Repo   : https://github.com/fakhfakhahmed/terraform-azure-aks-platform
#   Needs INFRACOST_API_KEY in the environment - get a free one at
#   https://dashboard.infracost.io (no credit card required for the free tier).

set -euo pipefail

# ---------------------------------------------------------------------------
# Output helpers (same pattern as the rest of scripts/*.sh)
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
  echo "Usage: $0 <dev|staging|prod> [--var-file FILE] [--format table|json|html|diff] [--out-file FILE]" >&2
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

VAR_FILE="terraform.tfvars"
FORMAT="table"
OUT_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --var-file)
      [[ $# -ge 2 ]] || { echo "--var-file requires a value" >&2; exit 1; }
      VAR_FILE="$2"; shift 2 ;;
    --format)
      [[ $# -ge 2 ]] || { echo "--format requires a value" >&2; exit 1; }
      FORMAT="$2"; shift 2 ;;
    --out-file)
      [[ $# -ge 2 ]] || { echo "--out-file requires a value" >&2; exit 1; }
      OUT_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

case "$FORMAT" in
  table|json|html|diff) ;;
  *) echo "--format must be one of: table, json, html, diff (got '$FORMAT')" >&2; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_DIR="$REPO_ROOT/envs/$ENVIRONMENT"

write_colored "" "$C_WHITE"
write_colored "  terraform-azure-aks-platform :: cost-estimate [$ENVIRONMENT]" "$C_WHITE"
write_colored "  repo root: $REPO_ROOT" "$C_GRAY"

if [[ ! -d "$ENV_DIR" ]]; then
  write_err "Environment directory '$ENV_DIR' does not exist."
  exit 1
fi

# -- is infracost installed? ---------------------------------------------------------------
# `command -v` is the POSIX-portable way to ask "is this on PATH" without the
# noisy/non-portable `which`, and without erroring under `set -e` (the `||`
# below, or the `if` form, keeps a miss from aborting the script - see the
# `if ! infracost_path=...` pattern used in the other scripts in this dir).
if ! infracost_path=$(command -v infracost 2>/dev/null); then
  write_step 'Infracost is not installed'
  write_warn 'This is informational, not a failure - cost estimation is optional tooling.'
  write_colored "" "$C_GRAY"
  write_info 'Infracost estimates the monthly cost of a Terraform plan before you apply it.'
  write_info 'Install it (free, no credit card required for the usage this repo needs):'
  write_colored "" "$C_GRAY"
  write_info '    brew install infracost'
  write_info '    choco install infracost'
  write_info '    winget install Infracost.Infracost'
  write_info '    https://www.infracost.io/docs/#quick-start'
  write_colored "" "$C_GRAY"
  write_info "Then re-run:  ./scripts/cost-estimate.sh $ENVIRONMENT"
  # Exit code 2 is a deliberate, documented "soft" failure distinct from
  # exit 1 (a real error). A CI job can special-case 2 to post a friendly PR
  # comment instead of going red. Because this is the LAST exit in this
  # branch and `set -e` has not fired (command -v failure was guarded by the
  # `if`), the explicit `exit 2` here is what the caller actually observes.
  exit 2
fi

write_ok "infracost: $infracost_path"

# -- INFRACOST_API_KEY reminder -------------------------------------------------------------
if [[ -z "${INFRACOST_API_KEY:-}" ]]; then
  write_warn 'INFRACOST_API_KEY is not set in this shell.'
  write_info 'Infracost needs a (free) API key to price cloud resources:'
  write_info '    infracost auth login          # opens a browser, free tier, no credit card'
  write_info '    export INFRACOST_API_KEY="ico-xxxxxxxx"   # or set it directly'
  write_info 'Continuing anyway - infracost itself will error out clearly if it truly needs one.'
fi

# -- build the breakdown command -------------------------------------------------------------
# `--path envs/<env>` lets Infracost generate its own plan under the hood, so
# this script needs no saved tfplan and never touches Azure beyond what
# Infracost's HCL parsing does (which is none - Infracost prices the plan, it
# does not call the azurerm provider).
BREAKDOWN_ARGS=(breakdown --path "$ENV_DIR" --format "$FORMAT")

VAR_FILE_PATH="$ENV_DIR/$VAR_FILE"
if [[ -f "$VAR_FILE_PATH" ]]; then
  # Equivalent to:
  #   infracost breakdown --path envs/<env> --terraform-plan-flags "-var-file=terraform.tfvars"
  # Pointing Infracost at the same tfvars file Terraform itself would use
  # keeps the priced quantities (node counts, SKUs) honest instead of
  # falling back to the module's declared defaults.
  BREAKDOWN_ARGS+=(--terraform-plan-flags "-var-file=$VAR_FILE")
  write_ok "using var file: $VAR_FILE_PATH"
else
  write_info "no '$VAR_FILE' found in $ENV_DIR - Infracost will use the module's declared defaults."
fi

if [[ -n "$OUT_FILE" ]]; then
  BREAKDOWN_ARGS+=(--out-file "$OUT_FILE")
  write_info "also writing output to: $OUT_FILE"
fi

write_step "infracost ${BREAKDOWN_ARGS[*]}"
run "$infracost_path" "${BREAKDOWN_ARGS[@]}" -- "infracost breakdown failed for '$ENVIRONMENT'.

Common causes:
  * INFRACOST_API_KEY missing/invalid -> infracost auth login
  * envs/$ENVIRONMENT has no .tf files yet, or a syntax error Infracost's HCL parser rejects
  * Network/proxy blocking pricing.api.infracost.io -> set HTTPS_PROXY / NO_PROXY"

# -- closing reminder -------------------------------------------------------------------------
write_step 'Reminder'
write_warn 'This is an ESTIMATE, not a bill. Infracost prices the resources in the plan at'
write_warn 'published list prices - it does not know about Reserved Instances, Azure Hybrid'
write_warn 'Benefit, negotiated discounts, or real-world autoscaling behaviour.'
write_info 'Cross-check against:'
write_info "    docs/cost.md                           (this repo's own cost notes)"
write_info '    https://azure.microsoft.com/pricing/calculator/   (Azure Pricing Calculator)'

exit 0

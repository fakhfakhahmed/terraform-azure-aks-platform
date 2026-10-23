#!/usr/bin/env bash
#
# apply-env.sh
#
# SYNOPSIS
#   Applies Terraform for one environment, with cost warnings and a
#   break-glass guard around production. Bash port of apply-env.ps1.
#
# DESCRIPTION
#   This is the only script in the repo that creates billable infrastructure
#   in an environment. It is deliberately noisy and deliberately hard to
#   misuse.
#
#   Behaviour:
#     * Runs init if envs/<env>/.terraform is missing.
#     * If a saved plan file exists, it applies THAT - the whole point of a
#       saved plan is that what you reviewed is what gets applied. The plan
#       file is deleted afterwards because a saved plan is single-use and a
#       stale one is a trap.
#     * If no plan file exists it plans first, shows you the result, and
#       asks before applying.
#     * Prints the outputs and a teardown reminder at the end.
#
#   PRODUCTION IS GUARDED
#   -----------------------------------------------------------------------
#   Applying to prod from a laptop is a smell, not a workflow. The
#   sanctioned path is the GitHub Actions pipeline, where a GitHub
#   Environment with required reviewers gates the apply, the OIDC principal
#   is scoped to exactly what it needs, and there is an audit trail that is
#   not "Ahmed says he ran it on Tuesday".
#
#   This script therefore refuses prod unless BOTH hold:
#     1. --force is passed, and
#     2. you type the literal string  apply-prod  at an interactive prompt.
#
#   That is break-glass: the pipeline is down, there is an incident, and
#   someone senior decided a manual apply is the lesser evil. If you find
#   yourself typing apply-prod routinely, the pipeline is what needs fixing.
#
# USAGE
#   ./scripts/apply-env.sh <dev|staging|prod> [options]
#
#   --plan-file FILE    Saved plan to apply, relative to envs/<env>.
#                        Default: tfplan. If missing, the script plans first.
#   --force              Skip the yes/no confirmation for dev and staging.
#                        For prod it is necessary but NOT sufficient - the
#                        typed apply-prod confirmation is always required.
#   --keep-plan-file       Do not delete the plan file after a successful
#                        apply. Off by default on purpose.
#
# NOTES
#   Author : Ahmed Fakhfakh
#   Repo   : https://github.com/fakhfakhahmed/terraform-azure-aks-platform
#   COST: an AKS cluster with its node pools, a Log Analytics workspace, an
#   ACR and a Key Vault is NOT free. Destroy dev when you are done - see the
#   reminder printed at the end of a successful run.

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

write_banner() { # color, then one line per remaining arg
  local color="$1"; shift
  local border
  border=$(printf '*%.0s' $(seq 1 78))
  write_colored "" "$color"
  write_colored "$border" "$color"
  for line in "$@"; do
    # Truncate to 74 chars the way the ps1 .Substring(0, 74) does, so a long
    # line cannot blow out the banner's fixed width.
    local text="${line:0:74}"
    printf -v padded '%-75s' "$text"
    write_colored "* ${padded}*" "$color"
  done
  write_colored "$border" "$color"
  write_colored "" "$color"
}

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

# read_typed_confirmation EXPECTED PROMPT -> 0 (true) if the typed answer
# matches EXPECTED exactly (case-sensitive: bash string comparison with ==
# inside [[ ]] is already case-sensitive, matching the ps1 -ceq operator).
read_typed_confirmation() {
  local expected="$1" prompt="${2:-Type the confirmation string}"
  if [[ ! -t 0 ]]; then
    write_err "An interactive confirmation ('$expected') is required and this host is non-interactive. There is no flag that bypasses it - that is the point."
    exit 1
  fi
  local answer
  read -r -p "$prompt: " answer
  [[ "$answer" == "$expected" ]]
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
usage() {
  echo "Usage: $0 <dev|staging|prod> [--plan-file FILE] [--force] [--keep-plan-file]" >&2
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

PLAN_FILE="tfplan"
FORCE=0
KEEP_PLAN_FILE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan-file)
      [[ $# -ge 2 ]] || { echo "--plan-file requires a value" >&2; exit 1; }
      PLAN_FILE="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --keep-plan-file) KEEP_PLAN_FILE=1; shift ;;
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
write_colored "  terraform-azure-aks-platform :: apply-env [$ENVIRONMENT]" "$C_WHITE"
write_colored "  repo root: $REPO_ROOT" "$C_GRAY"

if ! terraform_path=$(command -v terraform 2>/dev/null); then
  write_err "terraform was not found on PATH. Run ./scripts/preflight.sh for the full checklist."
  exit 1
fi
if [[ ! -d "$ENV_DIR" ]]; then
  write_err "Environment directory '$ENV_DIR' does not exist."
  exit 1
fi
BACKEND_FILE="$ENV_DIR/backend.hcl"
if [[ ! -f "$BACKEND_FILE" ]]; then
  write_err "Missing '$BACKEND_FILE'. Run: ./scripts/init-env.sh $ENVIRONMENT  (it explains how to create it)."
  exit 1
fi

# -- cost warning -------------------------------------------------------------------
ENV_UPPER=$(printf '%s' "$ENVIRONMENT" | tr '[:lower:]' '[:upper:]')
write_banner "$C_YELLOW" \
  "COST WARNING - APPLYING TO '$ENV_UPPER'" \
  '' \
  'This creates and/or modifies real Azure resources that are billed by the hour:' \
  '  * AKS cluster + node pools (VMs, managed disks, public IPs)' \
  '  * Log Analytics workspace (ingestion + retention)' \
  '  * Azure Container Registry, Key Vault, networking' \
  '' \
  'Nothing here is covered by a free tier at a meaningful scale. An idle dev cluster' \
  'left running over a weekend is a real, recurring charge on a real credit card.' \
  '' \
  "Estimate first:  ./scripts/cost-estimate.sh $ENVIRONMENT"

# -- production guard ------------------------------------------------------------------
if [[ "$ENVIRONMENT" == "prod" ]]; then
  write_banner "$C_RED" \
    'PRODUCTION APPLY - BREAK-GLASS ONLY' \
    '' \
    'The sanctioned path to prod is the GitHub Actions workflow, gated by a GitHub' \
    'Environment with required reviewers. That gives you an approval record, a' \
    'scoped OIDC identity and a reproducible log. A laptop gives you none of those.' \
    '' \
    'Use this script only when the pipeline itself is unavailable and someone has' \
    'consciously accepted the risk. Write it up afterwards.'

  if [[ "$FORCE" -eq 0 ]]; then
    write_err 'Refusing to apply to prod without --force.'
    write_info 'Sanctioned path:'
    write_info '    gh workflow run terraform-apply.yml -f environment=prod'
    write_info '    (then approve the deployment in the GitHub Environment)'
    write_info ''
    write_info 'Break-glass path:'
    write_info '    ./scripts/apply-env.sh prod --force     (you will also have to type apply-prod)'
    exit 1
  fi

  write_warn 'Second gate: type the confirmation string EXACTLY (case-sensitive).'
  if ! read_typed_confirmation 'apply-prod' "Type 'apply-prod' to proceed"; then
    write_err 'Confirmation did not match. Nothing was applied.'
    exit 1
  fi
  write_warn 'Break-glass confirmation accepted. Proceeding with the production apply.'
fi

# -- init if cold -----------------------------------------------------------------------
if [[ ! -d "$ENV_DIR/.terraform" ]]; then
  write_step "envs/$ENVIRONMENT/.terraform not found - running init first"
  if ! "$SCRIPT_DIR/init-env.sh" "$ENVIRONMENT" --skip-validate; then
    write_err "init-env.sh failed for '$ENVIRONMENT'."
    exit 1
  fi
fi

if [[ -z "${ARM_SUBSCRIPTION_ID:-}" ]]; then
  if az_path=$(command -v az 2>/dev/null); then
    if sub_id=$("$az_path" account show --query id --output tsv 2>/dev/null) && [[ -n "$sub_id" ]]; then
      export ARM_SUBSCRIPTION_ID="$sub_id"
      write_info "ARM_SUBSCRIPTION_ID: $ARM_SUBSCRIPTION_ID"
    fi
  fi
fi

ORIGINAL_DIR="$(pwd)"
cleanup() { cd "$ORIGINAL_DIR"; }
trap cleanup EXIT

cd "$ENV_DIR"

PLAN_PATH="$ENV_DIR/$PLAN_FILE"
APPLY_ARGS=(apply -input=false -lock-timeout=5m)

if [[ -f "$PLAN_PATH" ]]; then
  # Portable "age of file in minutes/hours": stat's flags differ between GNU
  # and BSD/macOS, so we read the mtime as epoch seconds with a fallback.
  if mtime=$(stat -c %Y "$PLAN_PATH" 2>/dev/null) || mtime=$(stat -f %m "$PLAN_PATH" 2>/dev/null); then
    now=$(date +%s)
    age_seconds=$(( now - mtime ))
  else
    age_seconds=0
  fi
  age_minutes=$(( age_seconds / 60 ))
  age_hours=$(( age_seconds / 3600 ))

  write_step "Using saved plan: $PLAN_FILE  (created $age_minutes minute(s) ago)"
  write_info 'Terraform will refuse this plan if the configuration or state has changed since'
  write_info 'it was produced. That is a feature - re-plan rather than fighting it.'

  if [[ "$age_hours" -gt 1 ]]; then
    write_warn "This plan is $age_hours hour(s) old. Consider re-running plan-env.sh first."
  fi

  # A saved plan already encodes the approval - `terraform apply <planfile>`
  # does not prompt, and -auto-approve is rejected when a plan file is supplied.
  APPLY_ARGS+=("$PLAN_FILE")
else
  write_step "No saved plan at '$PLAN_PATH' - planning now"
  run "$terraform_path" plan -input=false -lock-timeout=5m "-out=$PLAN_FILE" -- \
    "terraform plan failed for '$ENVIRONMENT'."
  APPLY_ARGS+=("$PLAN_FILE")
fi

# -- confirmation (prod already did its own, stricter, gate) --------------------------
if [[ "$ENVIRONMENT" != "prod" ]]; then
  if [[ "$FORCE" -eq 1 ]]; then
    write_warn '--force supplied: applying without a confirmation prompt.'
  else
    if [[ ! -t 0 ]]; then
      write_err "A confirmation is required and this host is non-interactive. Pass --force once you have reviewed the plan."
      exit 1
    fi
    write_colored "" "$C_YELLOW"
    write_colored "About to APPLY the plan above to '$ENVIRONMENT'. This creates billable resources." "$C_YELLOW"
    read -r -p "Type 'yes' to continue: " answer
    if [[ "$answer" != "yes" ]]; then
      write_err "Aborted - you typed '$answer'. Nothing was applied."
      write_info "The plan file is still at $PLAN_PATH if you want to apply it later."
      exit 1
    fi
  fi
fi

# -- apply ------------------------------------------------------------------------------
write_step "terraform ${APPLY_ARGS[*]}"
write_info 'An AKS apply typically takes 8-15 minutes. Do not interrupt it: a Ctrl+C mid-apply'
write_info 'leaves the state lease held and resources half-created.'

run "$terraform_path" "${APPLY_ARGS[@]}" -- "terraform apply FAILED for '$ENVIRONMENT'.

The state may now describe a partially-created environment. Do NOT panic and do NOT
delete resources by hand in the portal - that desynchronises state.

Recovery:
  1. Read the error. Quota and SKU-availability errors are the most common.
  2. Re-run:  ./scripts/plan-env.sh $ENVIRONMENT      (Terraform is idempotent; it will
     plan only what is still missing)
  3. If the state lease is stuck (a previous run was killed):
        terraform force-unlock <LOCK_ID>      # last resort, only when you are certain
                                              # no other apply is running"

write_ok 'Apply completed successfully.'

# The plan has been consumed. Leaving it on disk invites someone to apply a
# stale snapshot later; Terraform would reject it, but the confusion is avoidable.
if [[ "$KEEP_PLAN_FILE" -eq 0 && -f "$PLAN_PATH" ]]; then
  rm -f "$PLAN_PATH"
  write_info "Consumed plan file removed: $PLAN_FILE"
fi

# -- outputs --------------------------------------------------------------------------
write_step 'Outputs'
set +e
outputs_json=$("$terraform_path" output -json 2>/dev/null)
outputs_exit=$?
set -e

if [[ "$outputs_exit" -ne 0 || -z "$outputs_json" ]]; then
  write_warn "Could not read outputs. Run 'terraform output' inside envs/$ENVIRONMENT manually."
elif command -v jq >/dev/null 2>&1; then
  names=()
  while IFS= read -r n; do [[ -n "$n" ]] && names+=("$n"); done < <(printf '%s' "$outputs_json" | jq -r 'keys[]?')
  if [[ ${#names[@]} -eq 0 ]]; then
    write_info 'This environment declares no outputs.'
  else
    width=0
    for n in "${names[@]}"; do [[ ${#n} -gt $width ]] && width=${#n}; done
    for n in "${names[@]}"; do
      is_sensitive=$(printf '%s' "$outputs_json" | jq -r --arg n "$n" '.[$n].sensitive // false')
      printf -v name_padded '%-*s' "$width" "$n"
      if [[ "$is_sensitive" == "true" ]]; then
        # Never echo a sensitive output into a terminal buffer / CI log.
        write_colored "    ${name_padded}  <sensitive - reveal with: terraform output $n>" "$C_YELLOW"
      else
        value=$(printf '%s' "$outputs_json" | jq -r --arg n "$n" '.[$n].value // ""')
        write_colored "    ${name_padded}  ${value}" "$C_GREEN"
      fi
    done
  fi
else
  write_warn 'jq is not installed - skipping the formatted output table.'
  write_info 'Run: terraform -chdir=envs/'"$ENVIRONMENT"' output'
fi

cd "$ORIGINAL_DIR"
trap - EXIT

# -- closing ----------------------------------------------------------------------------
write_step 'Next steps'
write_info "Connect kubectl to the cluster:   ./scripts/connect-aks.sh $ENVIRONMENT"
write_info "Check what it costs:              ./scripts/cost-estimate.sh $ENVIRONMENT"

if [[ "$ENVIRONMENT" == "dev" ]]; then
  write_banner "$C_YELLOW" \
    'TEARDOWN REMINDER - dev is not free' \
    '' \
    'When you are finished for the day, destroy it:' \
    '' \
    '  ./scripts/plan-env.sh dev --destroy --out tfplan.destroy    # review first' \
    '  terraform -chdir=envs/dev destroy                           # then tear down' \
    '' \
    'The remote state backend and the bootstrap stack survive a destroy, so you can' \
    'rebuild dev from scratch in one apply tomorrow.'
else
  write_warn "Remember that '$ENVIRONMENT' keeps billing until it is destroyed."
fi

exit 0

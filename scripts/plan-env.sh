#!/usr/bin/env bash
#
# plan-env.sh
#
# SYNOPSIS
#   Produces a saved Terraform plan for one environment, summarises it, and
#   runs the Rego policy gate. Never applies anything. Bash port of
#   plan-env.ps1.
#
# DESCRIPTION
#   plan-env.sh is the read-mostly workhorse of this repo. It:
#
#     1. Runs init automatically if envs/<env>/.terraform is missing, so a
#        fresh clone needs one command instead of two.
#     2. Runs `terraform plan -input=false -lock-timeout=5m -out=<file>`.
#        The lock timeout matters: the azurerm backend takes a blob lease,
#        and a colleague's CI run holding it for 30 seconds should make you
#        wait, not fail.
#     3. Parses `terraform show -json <plan>` and prints a human summary,
#        calling out DESTROY and REPLACE actions - those are the ones that
#        ruin afternoons.
#     4. If conftest is installed and policy/conftest exists, evaluates the
#        plan JSON against the Rego policies. A policy failure fails the
#        script.
#
#   A plan is a read operation against Azure, so it is safe and free. It
#   does refresh state, which means it needs the same credentials an apply
#   would.
#
#   --detailed AND EXIT CODES
#   -----------------------------------------------------------------------
#   With --detailed the script passes -detailed-exitcode to Terraform, which
#   splits the outcome into three: 0 = no changes, 1 = error, 2 = changes
#   present. Exit code 2 is NOT a failure here - it is the signal a
#   drift-detection pipeline wants. The script propagates it verbatim so a
#   scheduled job can do:
#
#       ./scripts/plan-env.sh prod --detailed
#       if [[ $? -eq 2 ]]; then # open a drift ticket
#
# USAGE
#   ./scripts/plan-env.sh <dev|staging|prod> [options]
#
#   --out FILE          Plan output file name, relative to envs/<env>.
#                        Default: tfplan.
#   --detailed           Pass -detailed-exitcode and propagate exit code 2
#                        when changes are present.
#   --destroy            Produce a DESTROY plan (`terraform plan -destroy`).
#                        Still never applies.
#   --skip-policy         Do not run conftest even when it is installed.
#   --keep-plan-json       Keep the intermediate <out>.json file instead of
#                        deleting it.
#   --no-refresh          Pass -refresh=false. Faster, and the right call
#                        when iterating on a module and nothing drifted.
#
# NOTES
#   Author : Ahmed Fakhfakh
#   Repo   : https://github.com/fakhfakhahmed/terraform-azure-aks-platform
#   Exit 0 = no changes / plan produced. Exit 1 = error or policy failure.
#   Exit 2 = (--detailed only) changes present.

set -euo pipefail

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

# run FILEPATH ARGS... -- ERRORMESSAGE
# Unlike the ps1 Invoke-Native helper, bash's `set -e` already stops the
# script on a non-zero exit; this wrapper only exists to attach the longer,
# actionable error text the ps1 version prints instead of a bare failure.
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

# get_action_kind "a b c" -> echoes create|update|delete|replace|noop
# Terraform encodes a resource change as an array of actions:
#   ["create"]           -> create
#   ["update"]           -> update
#   ["delete"]            -> delete
#   ["delete","create"]   -> replace (and ["create","delete"] for
#                            create_before_destroy)
#   ["no-op"] / ["read"]  -> ignored
get_action_kind() {
  local actions="$1"
  if [[ "$actions" == *delete* && "$actions" == *create* ]]; then echo replace; return; fi
  if [[ "$actions" == *create* ]]; then echo create; return; fi
  if [[ "$actions" == *delete* ]]; then echo delete; return; fi
  if [[ "$actions" == *update* ]]; then echo update; return; fi
  echo noop
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
usage() {
  echo "Usage: $0 <dev|staging|prod> [--out FILE] [--detailed] [--destroy] [--skip-policy] [--keep-plan-json] [--no-refresh]" >&2
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

OUT="tfplan"
DETAILED=0
DESTROY=0
SKIP_POLICY=0
KEEP_PLAN_JSON=0
REFRESH=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)
      [[ $# -ge 2 ]] || { echo "--out requires a value" >&2; exit 1; }
      OUT="$2"; shift 2 ;;
    --detailed) DETAILED=1; shift ;;
    --destroy) DESTROY=1; shift ;;
    --skip-policy) SKIP_POLICY=1; shift ;;
    --keep-plan-json) KEEP_PLAN_JSON=1; shift ;;
    --no-refresh) REFRESH=0; shift ;;
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
POLICY_DIR="$REPO_ROOT/policy/conftest"
PLAN_JSON="${OUT}.json"

write_colored "" "$C_WHITE"
write_colored "  terraform-azure-aks-platform :: plan-env [$ENVIRONMENT]" "$C_WHITE"
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
  write_err "Missing '$BACKEND_FILE'. Run: ./scripts/init-env.sh $ENVIRONMENT  (it explains how to create it), or ./scripts/bootstrap-backend.sh --write-backend-files"
  exit 1
fi

# Auto-init on a cold directory. Delegating to init-env.sh keeps the backend
# handling in exactly one place instead of duplicating the -reconfigure
# logic here.
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
    fi
  fi
fi

EXIT_CODE=0

ORIGINAL_DIR="$(pwd)"
cleanup() { cd "$ORIGINAL_DIR"; }
trap cleanup EXIT

cd "$ENV_DIR"

# -- plan -----------------------------------------------------------------------
PLAN_ARGS=(plan -input=false -lock-timeout=5m "-out=$OUT")
[[ "$DESTROY" -eq 1 ]] && PLAN_ARGS+=(-destroy)
[[ "$REFRESH" -eq 0 ]] && PLAN_ARGS+=(-refresh=false)
[[ "$DETAILED" -eq 1 ]] && PLAN_ARGS+=(-detailed-exitcode)

[[ "$DESTROY" -eq 1 ]] && write_warn 'This is a DESTROY plan. Nothing is destroyed by planning, but read it carefully.'

write_step "terraform ${PLAN_ARGS[*]}"

# -detailed-exitcode makes exit code 2 a legitimate, non-error outcome, so
# this call is NOT run through the `run` wrapper (which treats any non-zero
# exit as fatal) - it is handled by hand so a `2` can be told apart from a
# real failure (anything else non-zero).
set +e
"$terraform_path" "${PLAN_ARGS[@]}"
plan_exit=$?
set -e

if [[ "$DETAILED" -eq 1 ]]; then
  if [[ "$plan_exit" -eq 2 ]]; then
    : # fall through - handled below after validating it's not a real error
  elif [[ "$plan_exit" -ne 0 ]]; then
    write_err "terraform plan failed for '$ENVIRONMENT'.

Common causes:
  * Expired Azure token                 -> az login
  * State blob lease held by CI         -> wait, or inspect with: terraform force-unlock <id> (last resort)
  * Missing required variable           -> check envs/$ENVIRONMENT/terraform.tfvars
  * Insufficient RBAC on the state blob -> you need Storage Blob Data Contributor"
    exit 1
  fi
else
  if [[ "$plan_exit" -ne 0 ]]; then
    write_err "terraform plan failed for '$ENVIRONMENT'.

Common causes:
  * Expired Azure token                 -> az login
  * State blob lease held by CI         -> wait, or inspect with: terraform force-unlock <id> (last resort)
  * Missing required variable           -> check envs/$ENVIRONMENT/terraform.tfvars
  * Insufficient RBAC on the state blob -> you need Storage Blob Data Contributor"
    exit 1
  fi
fi

if [[ "$DETAILED" -eq 1 ]]; then
  if [[ "$plan_exit" -eq 2 ]]; then
    write_warn 'detailed-exitcode = 2 : changes are present (drift, or pending config changes).'
    write_warn 'This is informational, not an error.'
    EXIT_CODE=2
  else
    write_ok 'detailed-exitcode = 0 : infrastructure matches the configuration. No drift.'
  fi
fi

# -- change summary ---------------------------------------------------------------
write_step 'Change summary'

# `terraform show -json <plan>` is the machine-readable form of the plan. We
# write it to disk because conftest (next step) consumes a file, and because
# it is genuinely useful to keep around while debugging (--keep-plan-json).
set +e
"$terraform_path" show -json "$OUT" > "$PLAN_JSON" 2>/dev/null
show_exit=$?
set -e

if [[ "$show_exit" -ne 0 ]]; then
  write_warn "terraform show -json exited $show_exit - skipping the structured summary."
  rm -f "$PLAN_JSON"
elif command -v jq >/dev/null 2>&1; then
  if jq -e '.resource_changes' "$PLAN_JSON" >/dev/null 2>&1; then
    creates=() updates=() deletes=() replaces=()
    while IFS=$'\t' read -r address actions; do
      [[ -z "$address" ]] && continue
      kind=$(get_action_kind "$actions")
      case "$kind" in
        create)  creates+=("$address") ;;
        update)  updates+=("$address") ;;
        delete)  deletes+=("$address") ;;
        replace) replaces+=("$address") ;;
      esac
    done < <(jq -r '.resource_changes[]? | select(.change.actions != null) | [.address, (.change.actions | join(","))] | @tsv' "$PLAN_JSON")

    total=$(( ${#creates[@]} + ${#updates[@]} + ${#deletes[@]} + ${#replaces[@]} ))
    if [[ "$total" -eq 0 ]]; then
      write_ok 'No changes. Infrastructure matches the configuration.'
    else
      write_ok      "  create  : ${#creates[@]}"
      write_colored "      update  : ${#updates[@]}" "$C_YELLOW"
      write_colored "      replace : ${#replaces[@]}" "$C_MAGENTA"
      write_colored "      destroy : ${#deletes[@]}" "$C_RED"

      # Destroys and replaces are the dangerous half of any plan. Enumerate
      # them explicitly so nobody has to scroll back through 400 lines of diff.
      if [[ ${#replaces[@]} -gt 0 ]]; then
        write_colored $'\n      RESOURCES TO BE REPLACED (destroyed and recreated):' "$C_MAGENTA"
        for address in "${replaces[@]}"; do write_colored "        -/+ $address" "$C_MAGENTA"; done
        write_warn 'A replace on a stateful resource (AKS node pool, storage, Key Vault) means downtime or data loss.'
      fi
      if [[ ${#deletes[@]} -gt 0 ]]; then
        write_colored $'\n      RESOURCES TO BE DESTROYED:' "$C_RED"
        for address in "${deletes[@]}"; do write_colored "        -   $address" "$C_RED"; done
      fi
    fi
  fi
else
  write_warn 'jq is not installed - skipping the structured change summary (the plan above still shows everything).'
fi

# -- policy gate ------------------------------------------------------------------
if [[ "$SKIP_POLICY" -eq 1 ]]; then
  write_step 'Policy gate skipped (--skip-policy)'
elif ! conftest_path=$(command -v conftest 2>/dev/null); then
  write_step 'Policy gate'
  write_warn 'conftest is not installed - skipping the Rego policy evaluation.'
  write_info 'Install: winget install OpenPolicyAgent.Conftest  |  brew install conftest'
  write_info 'CI runs this gate regardless, so a local skip only defers the feedback.'
elif [[ ! -d "$POLICY_DIR" ]]; then
  write_step 'Policy gate'
  write_warn "conftest is installed but '$POLICY_DIR' does not exist - nothing to evaluate."
elif [[ ! -f "$PLAN_JSON" ]]; then
  write_step 'Policy gate'
  write_warn 'Plan JSON was not produced - skipping the policy evaluation.'
else
  write_step "conftest test --policy policy/conftest $PLAN_JSON"
  # --all-namespaces so policies are not silently ignored when they declare a
  # package other than `main` (e.g. package terraform.azure.aks).
  run "$conftest_path" test --policy "$POLICY_DIR" --all-namespaces "$PLAN_JSON" -- \
    "Policy violations found in the '$ENVIRONMENT' plan. Fix the configuration (or the policy, with a good reason) before applying."
  write_ok 'All policies passed.'
fi

if [[ "$KEEP_PLAN_JSON" -eq 0 ]]; then
  rm -f "$PLAN_JSON"
elif [[ -f "$PLAN_JSON" ]]; then
  write_info "plan JSON kept at: $ENV_DIR/$PLAN_JSON"
fi

cd "$ORIGINAL_DIR"
trap - EXIT

# -- next steps ---------------------------------------------------------------------
write_step 'Done - NOTHING WAS APPLIED'
write_ok "Saved plan: $ENV_DIR/$OUT"
write_info 'A saved plan is a snapshot. If the configuration or remote state changes, Terraform'
write_info 'will refuse to apply it - re-plan rather than forcing it.'
write_colored "" "$C_GRAY"
write_info "To apply:  ./scripts/apply-env.sh $ENVIRONMENT --plan-file $OUT"

exit "$EXIT_CODE"

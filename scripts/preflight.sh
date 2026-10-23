#!/usr/bin/env bash
#
# preflight.sh
#
# SYNOPSIS
#   Verifies that this workstation is ready to operate the
#   terraform-azure-aks-platform repo. Bash port of preflight.ps1 - read it
#   first if you want the full rationale; this header only summarises it.
#
# DESCRIPTION
#   The first script to run on a new machine (or after "it works on mine").
#   It is strictly read-only: creates nothing, deletes nothing, costs
#   nothing. Safe to run as often as you like.
#
#   It checks four things:
#     1. Repository layout   - bootstrap/, modules/, envs/{dev,staging,prod}.
#     2. Required tooling    - terraform >= 1.9, az >= 2.60, kubectl >= 1.28,
#                               git >= 2.30. A missing/too-old required tool
#                               fails the run (exit 1).
#     3. Optional tooling    - tflint, checkov, conftest, infracost,
#                               terraform-docs, kubelogin. Warnings only.
#                               kubelogin deserves special attention: these
#                               AKS clusters are Entra ID / Azure RBAC with
#                               local accounts disabled, so without kubelogin
#                               every kubectl call fails with an opaque
#                               exec-plugin error.
#     4. Azure context       - `az account show` must succeed. If more than
#                               one subscription is visible you get a warning
#                               plus the `az account set` command to fix it.
#
# USAGE
#   ./scripts/preflight.sh [--skip-azure] [--no-color]
#
#   --skip-azure   Skip the `az account show` / subscription checks. Useful
#                  on an air-gapped machine or a container image build.
#   --no-color     Disable ANSI colour output. Also honoured via NO_COLOR.
#
# EXIT CODES
#   0 = ready (warnings may still be present).
#   1 = a required check failed.
#
# Author : Ahmed Fakhfakh
# Repo   : https://github.com/fakhfakhahmed/terraform-azure-aks-platform

# `set -euo pipefail`:
#   -e          any command that exits non-zero stops the script, EXCEPT when
#               that command is part of an `if`/`while` test, a `&&`/`||`
#               chain, or every stage of a pipeline but the last. We exploit
#               that below with `if ! cmd; then ...` wherever a non-zero exit
#               is informative rather than fatal (e.g. a missing optional
#               tool must not abort preflight).
#   -u          referencing an unset variable (including an unset positional
#               parameter) is a hard error instead of silently expanding to
#               the empty string. All optional values below are read through
#               ${VAR:-default} for exactly this reason.
#   -o pipefail a pipeline's exit status is the first non-zero stage, not
#               just the last. Without it, `cmd_that_fails | head` would look
#               like success because `head` itself exits 0.
set -euo pipefail

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
SKIP_AZURE=0
NO_COLOR_FLAG=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-azure) SKIP_AZURE=1; shift ;;
    --no-color)   NO_COLOR_FLAG=1; shift ;;
    -h|--help)
      echo "Usage: $0 [--skip-azure] [--no-color]"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 [--skip-azure] [--no-color]" >&2
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Presentation helpers
# ---------------------------------------------------------------------------
USE_COLOR=1
[[ "$NO_COLOR_FLAG" -eq 1 ]] && USE_COLOR=0
# NO_COLOR is a de-facto cross-tool convention (https://no-color.org/).
[[ -n "${NO_COLOR:-}" ]] && USE_COLOR=0
# A non-interactive terminal (piped into a log file) should not get escape
# codes splattered through it either.
[[ -t 1 ]] || USE_COLOR=0

C_CYAN=$'\033[36m'
C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'
C_RED=$'\033[31m'
C_GRAY=$'\033[90m'
C_MAGENTA=$'\033[35m'
C_WHITE=$'\033[37m'
C_RESET=$'\033[0m'

write_colored() { # $1=message $2=color
  if [[ "$USE_COLOR" -eq 1 ]]; then
    printf '%s%s%s\n' "$2" "$1" "$C_RESET"
  else
    printf '%s\n' "$1"
  fi
}
write_step() { write_colored $'\n==> '"$1" "$C_CYAN"; }
write_ok()   { write_colored "    $1" "$C_GREEN"; }
write_warn() { write_colored "    $1" "$C_YELLOW"; }
write_err()  { write_colored "    $1" "$C_RED"; }
write_info() { write_colored "    $1" "$C_GRAY"; }

# Glyphs: fall back to ASCII unless the locale is clearly UTF-8. This mirrors
# the ps1 script's console-encoding probe - some CI runners and minimal
# containers set C/POSIX locales where the UTF-8 glyphs render as mojibake.
GLYPH_PASS='+'
GLYPH_FAIL='x'
GLYPH_WARN='!'
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *UTF-8*|*utf8*|*UTF8*)
    GLYPH_PASS=$'\xe2\x9c\x94'   # HEAVY CHECK MARK
    GLYPH_FAIL=$'\xe2\x9c\x98'   # HEAVY BALLOT X
    GLYPH_WARN=$'\xe2\x9a\xa0'   # WARNING SIGN
    ;;
esac

# ---------------------------------------------------------------------------
# Version helpers
# ---------------------------------------------------------------------------

# version_ge A B -> true (exit 0) if dotted-numeric version A >= B.
# Implemented by hand (not `sort -V`) because BSD/macOS sort does not support
# the GNU -V version-sort extension, and this repo targets macOS too.
version_ge() {
  local a="$1" b="$2"
  local IFS=.
  local -a av=($a) bv=($b)
  local max=${#av[@]}
  (( ${#bv[@]} > max )) && max=${#bv[@]}
  local i
  for ((i = 0; i < max; i++)); do
    local ai="${av[i]:-0}" bi="${bv[i]:-0}"
    # Strip anything non-numeric (e.g. a trailing "-rc1") so arithmetic
    # comparison below never chokes on a stray character.
    ai="${ai//[^0-9]/}"; : "${ai:=0}"
    bi="${bi//[^0-9]/}"; : "${bi:=0}"
    # 10# forces base-10 interpretation so a segment like "08" is not
    # mis-parsed as an invalid octal literal by bash arithmetic.
    if (( 10#$ai > 10#$bi )); then return 0; fi
    if (( 10#$ai < 10#$bi )); then return 1; fi
  done
  return 0
}

# extract_semver TEXT -> prints "major.minor.patch" (patch defaults to 0), or
# nothing if no version-looking substring is found.
extract_semver() {
  local text="$1"
  local found
  found=$(printf '%s' "$text" | grep -oE 'v?[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 || true)
  [[ -z "$found" ]] && return 1
  found="${found#v}"
  [[ "$found" != *.*.* ]] && found="${found}.0"
  printf '%s\n' "$found"
}

# ---------------------------------------------------------------------------
# Check result collection
# ---------------------------------------------------------------------------
# Bash has no structs, so each "check" is three parallel arrays indexed by
# position. Cleared between sections with CHECK_NAMES=() etc, mirroring the
# ps1 script's $script:Checks.Clear() between sections.
CHECK_NAMES=()
CHECK_STATUSES=()   # pass | fail | warn
CHECK_DETAILS=()
CHECK_REQS=()
CHECK_HINTS=()

add_check() { # name status detail requirement hint
  CHECK_NAMES+=("$1")
  CHECK_STATUSES+=("$2")
  CHECK_DETAILS+=("$3")
  CHECK_REQS+=("$4")
  CHECK_HINTS+=("${5:-}")
}

show_checks() { # name_width detail_width
  local name_width="${1:-16}" detail_width="${2:-22}"
  local i
  for ((i = 0; i < ${#CHECK_NAMES[@]}; i++)); do
    local glyph="$GLYPH_WARN" color="$C_YELLOW"
    case "${CHECK_STATUSES[i]}" in
      pass) glyph="$GLYPH_PASS"; color="$C_GREEN" ;;
      fail) glyph="$GLYPH_FAIL"; color="$C_RED" ;;
    esac
    printf -v name_padded '%-*s' "$name_width" "${CHECK_NAMES[i]}"
    printf -v detail_padded '%-*s' "$detail_width" "${CHECK_DETAILS[i]}"
    local line="  $glyph  $name_padded $detail_padded ${CHECK_REQS[i]}"
    # Trim trailing whitespace the way the ps1 does with .TrimEnd().
    line="${line%"${line##*[![:space:]]}"}"
    write_colored "$line" "$color"
    if [[ -n "${CHECK_HINTS[i]}" ]]; then
      write_colored "       -> ${CHECK_HINTS[i]}" "$C_GRAY"
    fi
  done
}

count_status() { # status -> echoes count of checks matching
  local status="$1" count=0 i
  for ((i = 0; i < ${#CHECK_STATUSES[@]}; i++)); do
    [[ "${CHECK_STATUSES[i]}" == "$status" ]] && ((count++)) || true
  done
  echo "$count"
}

# ---------------------------------------------------------------------------
# Tool discovery / version probing
# ---------------------------------------------------------------------------

# test_tool NAME REQUIRED(0/1) MINVERSION PROBE_ARGS WHY INSTALL
# PROBE_ARGS is a single string split on spaces (none of our probe args
# contain spaces, so this is safe and keeps the call sites readable).
test_tool() {
  local name="$1" required="$2" minver="$3" probe_args="$4" why="$5" install="$6"

  local kind="optional"
  [[ "$required" -eq 1 ]] && kind="required"
  local requirement="($kind"
  [[ -n "$minver" ]] && requirement+=", >= $minver"
  requirement+=")"

  local path
  if ! path=$(command -v "$name" 2>/dev/null); then
    local status="warn"
    [[ "$required" -eq 1 ]] && status="fail"
    local hint="$install"
    [[ -n "$why" ]] && hint="$why"$'\n'"          $install"
    add_check "$name" "$status" "not found" "$requirement" "$hint"
    return
  fi

  # Merge stderr into stdout: several CLIs (kubelogin, older kubectl) print
  # their version banner to stderr. `|| true` so a non-zero exit from the
  # version probe itself (rare, but e.g. a broken shim) doesn't trip set -e.
  local text
  # shellcheck disable=SC2086
  text=$("$path" $probe_args 2>&1 || true)

  local version
  if ! version=$(extract_semver "$text"); then
    add_check "$name" "warn" "installed (version ?)" "$requirement" \
      "Could not parse a version from '$name $probe_args'. Found at: $path"
    return
  fi

  if [[ -n "$minver" ]] && ! version_ge "$version" "$minver"; then
    local status="warn"
    [[ "$required" -eq 1 ]] && status="fail"
    add_check "$name" "$status" "$version" "$requirement" \
      "Installed version is older than the minimum this repo targets. $install"
    return
  fi

  add_check "$name" "pass" "$version" "$requirement" ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Resolve paths from the script location, never the caller's cwd - operators
# run these from anywhere (C:\, a sibling repo, a scheduled task / cron job).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

write_colored "" "$C_WHITE"
write_colored "  terraform-azure-aks-platform :: preflight" "$C_WHITE"
write_colored "  repo root: $REPO_ROOT" "$C_GRAY"

# -- 1. repository layout ----------------------------------------------------
write_step 'Repository layout'

# Bash has no native array-of-structs; use "path|why" pairs and split on '|'.
required_dirs=(
  "bootstrap|remote-state backend + GitHub OIDC app (local state, run once)"
  "modules|reusable Terraform modules"
  "envs|directory-per-environment root modules"
  "envs/dev|dev root module"
  "envs/staging|staging root module"
  "envs/prod|prod root module"
)

CHECK_NAMES=(); CHECK_STATUSES=(); CHECK_DETAILS=(); CHECK_REQS=(); CHECK_HINTS=()
for entry in "${required_dirs[@]}"; do
  dir_path="${entry%%|*}"
  why="${entry#*|}"
  full="$REPO_ROOT/$dir_path"
  if [[ -d "$full" ]]; then
    add_check "$dir_path" "pass" "present" "($why)" ""
  else
    add_check "$dir_path" "fail" "MISSING" "($why)" \
      "Expected directory '$full'. Are you running preflight.sh from inside a full clone of fakhfakhahmed/terraform-azure-aks-platform?"
  fi
done
show_checks 14 9

layout_failures=$(count_status fail)

# Informational only: backend.hcl is gitignored, so a fresh clone never has one.
missing_backends=()
for env_name in dev staging prod; do
  backend_file="$REPO_ROOT/envs/$env_name/backend.hcl"
  [[ -f "$backend_file" ]] || missing_backends+=("$env_name")
done
if [[ ${#missing_backends[@]} -gt 0 ]]; then
  joined=$(IFS=', '; echo "${missing_backends[*]}")
  write_info "note: backend.hcl missing for: $joined  (expected on a fresh clone - it is gitignored)"
  write_info "      generate them with: ./scripts/bootstrap-backend.sh --write-backend-files"
  write_info "      or copy envs/<env>/backend.hcl.example to envs/<env>/backend.hcl and fill it in."
fi

# -- 2. required tooling ------------------------------------------------------
write_step 'Required tooling'
CHECK_NAMES=(); CHECK_STATUSES=(); CHECK_DETAILS=(); CHECK_REQS=(); CHECK_HINTS=()

test_tool terraform 1 "1.9.0" "version" "" \
  "winget install HashiCorp.Terraform   |   choco install terraform   |   brew install terraform   |   https://developer.hashicorp.com/terraform/install"

test_tool az 1 "2.60.0" "version --output json" "" \
  "winget install Microsoft.AzureCLI   |   brew install azure-cli   |   https://learn.microsoft.com/cli/azure/install-azure-cli"

test_tool kubectl 1 "1.28.0" "version --client -o json" "" \
  "az aks install-cli   |   winget install Kubernetes.kubectl   |   brew install kubectl"

test_tool git 1 "2.30.0" "--version" "" \
  "winget install Git.Git   |   brew install git"

show_checks
required_failures=$(count_status fail)

# Terraform deserves an explicit callout: the repo pins >= 1.9 because it
# uses provider-defined functions and the `removed` block semantics.
for ((i = 0; i < ${#CHECK_NAMES[@]}; i++)); do
  if [[ "${CHECK_NAMES[i]}" == "terraform" && "${CHECK_STATUSES[i]}" != "pass" && "${CHECK_DETAILS[i]}" != "not found" ]]; then
    write_warn "terraform ${CHECK_DETAILS[i]} is below the 1.9 floor this repo pins in versions.tf."
    write_warn "Upgrade before running init - a too-old binary fails at init with a required_version error."
  fi
done

# -- 3. optional tooling -------------------------------------------------------
write_step 'Optional tooling (quality gates and conveniences)'
CHECK_NAMES=(); CHECK_STATUSES=(); CHECK_DETAILS=(); CHECK_REQS=(); CHECK_HINTS=()

test_tool kubelogin 0 "0.1.0" "--version" \
  "REQUIRED IN PRACTICE for these clusters: AKS here is Entra ID integrated with Azure RBAC and local accounts disabled, so the kubeconfig uses an exec credential plugin. Without kubelogin, every kubectl command fails." \
  "az aks install-cli (installs kubelogin too)   |   winget install Microsoft.Azure.Kubelogin   |   brew install Azure/kubelogin/kubelogin"

test_tool tflint 0 "0.50.0" "--version" \
  "Linting: catches invalid Azure VM sizes/regions before a 10-minute apply does." \
  "winget install TFLint.TFLint   |   brew install tflint"

test_tool checkov 0 "3.0.0" "--version" \
  "Static security scanning of the Terraform plan." \
  "pipx install checkov   |   pip install checkov   |   brew install checkov"

test_tool conftest 0 "0.45.0" "--version" \
  "Rego policy gate - plan-env.sh runs it automatically against policy/conftest when present." \
  "winget install OpenPolicyAgent.Conftest   |   brew install conftest"

test_tool infracost 0 "0.10.0" "--version" \
  "Cost estimation - see scripts/cost-estimate.sh. Free tier is sufficient." \
  "winget install Infracost.Infracost   |   choco install infracost   |   brew install infracost"

test_tool terraform-docs 0 "0.17.0" "--version" \
  "Regenerates the module README tables." \
  "winget install Terraform-docs.Terraform-docs   |   brew install terraform-docs"

show_checks

for ((i = 0; i < ${#CHECK_NAMES[@]}; i++)); do
  if [[ "${CHECK_NAMES[i]}" == "kubelogin" && "${CHECK_STATUSES[i]}" != "pass" ]]; then
    write_warn 'kubelogin is formally optional but practically mandatory here.'
    write_warn 'connect-aks.sh runs `kubelogin convert-kubeconfig -l azurecli` after fetching credentials;'
    write_warn 'without it kubectl reports: "no Auth Provider found for name azure" or an exec plugin error.'
  fi
done

# -- 4. azure context -----------------------------------------------------------
azure_failures=0
if [[ "$SKIP_AZURE" -eq 1 ]]; then
  write_step 'Azure context (skipped via --skip-azure)'
else
  write_step 'Azure context'
  if ! az_path=$(command -v az 2>/dev/null); then
    write_err 'az is not installed - skipping the subscription checks (already counted as a failure above).'
  else
    account_json=$("$az_path" account show --output json 2>/dev/null || true)
    if [[ -z "$account_json" ]]; then
      azure_failures=$((azure_failures + 1))
      write_err 'az account show failed - you are not logged in (or the token expired).'
      write_info 'Fix:  az login           (add --use-device-code on a headless/remote host)'
      write_info '      az login --tenant <tenant-id>   if you belong to several tenants'
    else
      # Prefer jq when available for robust JSON parsing; fall back to a
      # tolerant grep/sed one-liner so this script has no hard dependency on
      # jq (preflight should work even before you have installed anything).
      if command -v jq >/dev/null 2>&1; then
        sub_name=$(printf '%s' "$account_json" | jq -r '.name // ""')
        sub_id=$(printf '%s' "$account_json" | jq -r '.id // ""')
        tenant_id=$(printf '%s' "$account_json" | jq -r '.tenantId // ""')
        user_name=$(printf '%s' "$account_json" | jq -r '.user.name // ""')
      else
        extract_json_field() { printf '%s' "$2" | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -n1 | sed -E 's/.*:"//; s/"$//'; }
        sub_name=$(extract_json_field name "$account_json")
        sub_id=$(extract_json_field id "$account_json")
        tenant_id=$(extract_json_field tenantId "$account_json")
        user_name=$(extract_json_field name "$(printf '%s' "$account_json" | grep -o '"user"[[:space:]]*:[[:space:]]*{[^}]*}' || true)")
      fi

      write_ok "$GLYPH_PASS  logged in as    $user_name"
      write_ok "$GLYPH_PASS  subscription    $sub_name"
      write_ok "$GLYPH_PASS  subscription id $sub_id"
      write_ok "$GLYPH_PASS  tenant id       $tenant_id"

      # More than one subscription in scope is the classic "applied an AKS
      # cluster into the client's production subscription" accident.
      list_json=$("$az_path" account list --all --output json 2>/dev/null || true)
      enabled_count=0
      enabled_lines=()
      if [[ -n "$list_json" ]] && command -v jq >/dev/null 2>&1; then
        enabled_count=$(printf '%s' "$list_json" | jq '[.[] | select(.state == "Enabled")] | length')
        while IFS= read -r line; do
          [[ -n "$line" ]] && enabled_lines+=("$line")
        done < <(printf '%s' "$list_json" | jq -r '.[] | select(.state == "Enabled") | (if .isDefault then "* " else "  " end) + .name + "  (" + .id + ")"')
      fi

      if [[ "$enabled_count" -gt 1 ]]; then
        write_warn "$GLYPH_WARN  $enabled_count subscriptions are visible to this login."
        write_warn '    Terraform will use whichever one is ACTIVE (or ARM_SUBSCRIPTION_ID if set).'
        write_warn '    Switch with:  az account set --subscription "<name-or-id>"'
        write_info '    Visible subscriptions:'
        for line in "${enabled_lines[@]}"; do
          write_info "      $line"
        done
      fi

      if [[ -n "${ARM_SUBSCRIPTION_ID:-}" && "${ARM_SUBSCRIPTION_ID}" != "$sub_id" ]]; then
        write_warn "$GLYPH_WARN  ARM_SUBSCRIPTION_ID (${ARM_SUBSCRIPTION_ID}) differs from the active az subscription ($sub_id)."
        write_warn '    The azurerm provider honours ARM_SUBSCRIPTION_ID, so Terraform will target that one.'
      fi
    fi
  fi
fi

# -- summary --------------------------------------------------------------------
total_failures=$((layout_failures + required_failures + azure_failures))

write_step 'Summary'
if [[ "$total_failures" -eq 0 ]]; then
  write_ok "$GLYPH_PASS  All required checks passed. You are ready to run bootstrap-backend.sh / init-env.sh."
  write_info 'Next:  ./scripts/bootstrap-backend.sh        (first time only - creates the remote state backend)'
  write_info '       ./scripts/init-env.sh dev'
  write_info '       ./scripts/plan-env.sh dev'
  exit 0
fi

write_err "$GLYPH_FAIL  $total_failures required check(s) failed. Fix the items marked above before continuing."
write_info 'Re-run this script after each fix - it is idempotent and free.'
exit 1

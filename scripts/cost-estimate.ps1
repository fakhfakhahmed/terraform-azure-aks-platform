#Requires -Version 5.1
<#
.SYNOPSIS
    Runs an Infracost cost breakdown for one environment.

.DESCRIPTION
    cost-estimate.ps1 is a thin, friendly wrapper around the Infracost CLI. It exists so
    operators do not have to remember Infracost's flags, and so a missing `infracost`
    binary produces a clear, actionable message instead of "infracost: command not found"
    with no context.

    What it does:
      1. Checks whether `infracost` is on PATH. If not, it prints the install link and a
         short explanation and exits with a distinct, documented exit code (2) rather than
         erroring the whole pipeline harshly - a CI job can choose to treat "not installed"
         as a soft warning rather than a hard failure.
      2. If `infracost` is found, runs:
             infracost breakdown --path envs/<env> --format table
         optionally adding --terraform-var-file / --terraform-plan-flags style arguments
         (see .PARAMETER TerraformPlanFlags) when a non-default tfvars file is in play.
      3. Reminds the operator that Infracost needs an INFRACOST_API_KEY (the free tier is
         enough for this repo) and that the result is an ESTIMATE - cross-check it with
         docs/cost.md and the Azure Pricing Calculator before trusting it for a budget.

    WHY THIS IS NOT PART OF plan-env.ps1
    -----------------------------------------------------------------------------------
    Infracost needs a Terraform plan (or can generate one itself via `infracost breakdown
    --path`), but unlike the conftest policy gate, a cost estimate is advisory, not a pass/
    fail gate. Keeping it a separate, opt-in script means plan-env.ps1 stays fast and
    conftest's exit code remains the only thing that can fail a plan.

.PARAMETER Environment
    dev, staging or prod. Positional, so `.\scripts\cost-estimate.ps1 dev` works.

.PARAMETER VarFile
    Terraform tfvars file (relative to envs/<env>) to pass through to Infracost's own
    Terraform invocation, equivalent to:
        infracost breakdown --path envs/<env> --format table \
          --terraform-plan-flags "-var-file=terraform.tfvars"
    Default: terraform.tfvars (only used if that file actually exists in the environment).

.PARAMETER Format
    Infracost output format: table (default), json, html, or diff. See
    https://www.infracost.io/docs/features/cli_commands/#breakdown for the full list.

.PARAMETER OutFile
    Optional path to also write the Infracost output to a file (useful for attaching a
    cost estimate to a pull request or a portfolio write-up).

.EXAMPLE
    PS> .\scripts\cost-estimate.ps1 dev
    Table breakdown of what envs/dev would cost, using envs/dev/terraform.tfvars if present.

.EXAMPLE
    PS> .\scripts\cost-estimate.ps1 prod -Format json -OutFile prod-cost.json
    Machine-readable breakdown for prod, also saved to prod-cost.json.

.NOTES
    Author : Ahmed Fakhfakh
    Repo   : https://github.com/fakhfakhahmed/terraform-azure-aks-platform
    Exit 0 = breakdown produced. Exit 2 = infracost is not installed (soft, documented).
    Exit 1 = infracost ran but failed (bad Terraform, auth error, etc).
    Needs INFRACOST_API_KEY in the environment - get a free one at
    https://dashboard.infracost.io (no credit card required for the free tier).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('dev', 'staging', 'prod')]
    [string]$Environment,

    [string]$VarFile = 'terraform.tfvars',
    [ValidateSet('table', 'json', 'html', 'diff')]
    [string]$Format = 'table',
    [string]$OutFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$global:LASTEXITCODE = 0

$RepoRoot = Split-Path -Parent $PSScriptRoot
$EnvDir   = Join-Path (Join-Path $RepoRoot 'envs') $Environment

$script:LastNativeExitCode = 0

# ---------------------------------------------------------------------------------------
# Helpers (same shape as the other scripts in this directory - see plan-env.ps1 for the
# fuller explanation of why every native call goes through Invoke-Native).
# ---------------------------------------------------------------------------------------

function Write-Colored { param([string]$Message, [System.ConsoleColor]$Color)
    if ($env:NO_COLOR) { Write-Host $Message } else { Write-Host $Message -ForegroundColor $Color }
}
function Write-Step { param([string]$Message) Write-Colored ("`n==> $Message") ([System.ConsoleColor]::Cyan) }
function Write-Ok   { param([string]$Message) Write-Colored ("    $Message")   ([System.ConsoleColor]::Green) }
function Write-Warn { param([string]$Message) Write-Colored ("    $Message")   ([System.ConsoleColor]::Yellow) }
function Write-Err  { param([string]$Message) Write-Colored ("    $Message")   ([System.ConsoleColor]::Red) }
function Write-Info { param([string]$Message) Write-Colored ("    $Message")   ([System.ConsoleColor]::Gray) }

function Invoke-Native {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int[]]$AllowedExitCodes = @(0),
        [string]$ErrorMessage
    )
    Write-Verbose ("exec: {0} {1}" -f $FilePath, ($Arguments -join ' '))
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'   # native stderr under 'Stop' => NativeCommandError
    try {
        & $FilePath @Arguments
    } finally {
        $ErrorActionPreference = $previous
    }
    $code = $global:LASTEXITCODE
    $script:LastNativeExitCode = $code
    if ($AllowedExitCodes -notcontains $code) {
        if ([string]::IsNullOrWhiteSpace($ErrorMessage)) {
            $ErrorMessage = "'$([System.IO.Path]::GetFileName($FilePath)) $($Arguments -join ' ')' failed with exit code $code."
        }
        throw $ErrorMessage
    }
}

function Get-CommandPath {
    param([Parameter(Mandatory)][string]$Name)
    $cmd = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $cmd) { return $null }
    if ($cmd -is [System.Array]) { return $cmd[0].Source }
    return $cmd.Source
}

# ---------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------

Write-Colored "" ([System.ConsoleColor]::White)
Write-Colored "  terraform-azure-aks-platform :: cost-estimate [$Environment]" ([System.ConsoleColor]::White)
Write-Colored "  repo root: $RepoRoot" ([System.ConsoleColor]::DarkGray)

if (-not (Test-Path -LiteralPath $EnvDir -PathType Container)) {
    throw "Environment directory '$EnvDir' does not exist."
}

# -- is infracost installed? -------------------------------------------------------------
# `Get-Command ... -ErrorAction SilentlyContinue` is the PowerShell idiom for "does this
# exist on PATH without throwing if it doesn't" - the bash port uses `command -v` for the
# same purpose.
$infracost = Get-CommandPath -Name 'infracost'
if ($null -eq $infracost) {
    Write-Step 'Infracost is not installed'
    Write-Warn 'This is informational, not a failure - cost estimation is optional tooling.'
    Write-Colored "" ([System.ConsoleColor]::Gray)
    Write-Info 'Infracost estimates the monthly cost of a Terraform plan before you apply it.'
    Write-Info 'Install it (free, no credit card required for the usage this repo needs):'
    Write-Colored "" ([System.ConsoleColor]::Gray)
    Write-Info '    winget install Infracost.Infracost'
    Write-Info '    choco install infracost'
    Write-Info '    brew install infracost'
    Write-Info '    https://www.infracost.io/docs/#quick-start'
    Write-Colored "" ([System.ConsoleColor]::Gray)
    Write-Info "Then re-run:  .\scripts\cost-estimate.ps1 $Environment"
    # Exit code 2 is a deliberate, documented "soft" failure distinct from exit 1 (a real
    # error). A CI job can special-case 2 to post a friendly PR comment instead of going red.
    exit 2
}

Write-Ok "infracost: $infracost"

# -- INFRACOST_API_KEY reminder -----------------------------------------------------------
if (-not $env:INFRACOST_API_KEY) {
    Write-Warn 'INFRACOST_API_KEY is not set in this shell.'
    Write-Info 'Infracost needs a (free) API key to price cloud resources:'
    Write-Info '    infracost auth login          # opens a browser, free tier, no credit card'
    Write-Info '    $env:INFRACOST_API_KEY = "ico-xxxxxxxx"   # or set it directly'
    Write-Info 'Continuing anyway - infracost itself will error out clearly if it truly needs one.'
}

# -- build the breakdown command -----------------------------------------------------------
# `--path envs/<env>` lets Infracost generate its own plan under the hood, so this script
# needs no saved tfplan and never touches Azure beyond what Infracost's HCL parsing does
# (which is none - Infracost prices the plan, it does not call the azurerm provider).
$breakdownArgs = @('breakdown', '--path', $EnvDir, '--format', $Format)

$varFilePath = Join-Path $EnvDir $VarFile
if (Test-Path -LiteralPath $varFilePath -PathType Leaf) {
    # Equivalent to: infracost breakdown --path envs/<env> --terraform-plan-flags "-var-file=terraform.tfvars"
    # Pointing Infracost at the same tfvars file Terraform itself would use keeps the
    # priced quantities (node counts, SKUs) honest instead of falling back to defaults.
    $breakdownArgs += @('--terraform-plan-flags', "-var-file=$VarFile")
    Write-Ok "using var file: $varFilePath"
} else {
    Write-Info "no '$VarFile' found in $EnvDir - Infracost will use the module's declared defaults."
}

if ($OutFile) {
    $breakdownArgs += @('--out-file', $OutFile)
    Write-Info "also writing output to: $OutFile"
}

Write-Step ("infracost " + ($breakdownArgs -join ' '))
Invoke-Native -FilePath $infracost -Arguments $breakdownArgs -ErrorMessage @"
infracost breakdown failed for '$Environment'.

Common causes:
  * INFRACOST_API_KEY missing/invalid -> infracost auth login
  * envs/$Environment has no .tf files yet, or a syntax error Infracost's HCL parser rejects
  * Network/proxy blocking pricing.api.infracost.io -> set HTTPS_PROXY / NO_PROXY
"@

# -- closing reminder -----------------------------------------------------------------------
Write-Step 'Reminder'
Write-Warn 'This is an ESTIMATE, not a bill. Infracost prices the resources in the plan at'
Write-Warn 'published list prices - it does not know about Reserved Instances, Azure Hybrid'
Write-Warn 'Benefit, negotiated discounts, or real-world autoscaling behaviour.'
Write-Info 'Cross-check against:'
Write-Info '    docs/cost.md                           (this repo'"'"'s own cost notes)'
Write-Info '    https://azure.microsoft.com/pricing/calculator/   (Azure Pricing Calculator)'

exit 0

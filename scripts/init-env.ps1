#Requires -Version 5.1
<#
.SYNOPSIS
    Initialises one environment root module against the shared azurerm remote backend.

.DESCRIPTION
    Every environment lives in its own directory (envs/dev, envs/staging, envs/prod) with
    its own state key in the shared storage account. There are no Terraform workspaces
    here on purpose: a workspace is one directory serving many environments, which makes
    per-environment provider versions, variables and policy impossible to diverge safely.
    Directory-per-environment is more files and far fewer surprises.

    envs/<env>/backend.tf contains a PARTIAL backend block - no account names, no keys.
    The concrete values come from envs/<env>/backend.hcl, which is gitignored and is
    produced either by scripts/bootstrap-backend.ps1 -WriteBackendFiles or by hand from
    backend.hcl.example.

    This script:
      1. validates the environment name,
      2. fails fast with a copy-pasteable fix if backend.hcl is missing,
      3. exports ARM_SUBSCRIPTION_ID (azurerm 4.x requires an explicit subscription),
      4. runs `terraform init -reconfigure -backend-config=backend.hcl`,
      5. runs `terraform validate` as a free sanity check.

    WHY -reconfigure AND NOT -migrate-state
    -----------------------------------------------------------------------------------
    -migrate-state asks Terraform to COPY state between backends and will happily do so,
    interactively, when it detects a change. That is exactly what you want once - when you
    genuinely move a backend - and exactly what you do not want on a routine init, where a
    stale .terraform/terraform.tfstate cache from a colleague's branch could silently push
    state into the wrong container.

    -reconfigure says: discard the cached backend settings, use what backend.hcl says now,
    and do not touch any state. It is the safe, repeatable, idempotent choice for an
    everyday init, and it is also what the CI workflow runs. If you ever truly need to move
    state between storage accounts, do it deliberately with -migrate-state (available here
    behind the explicit -MigrateState switch) and after taking a backup:
        terraform state pull > state-backup.json

.PARAMETER Environment
    dev, staging or prod. Positional, so `.\scripts\init-env.ps1 dev` works.

.PARAMETER Upgrade
    Pass -upgrade to terraform init: re-resolves provider and module versions within the
    constraints in versions.tf and rewrites .terraform.lock.hcl. Do this deliberately,
    review the lock file diff, and commit it.

.PARAMETER MigrateState
    Use -migrate-state instead of -reconfigure. Only for a genuine backend move. Prompts.

.PARAMETER SkipValidate
    Skip the post-init `terraform validate`.

.EXAMPLE
    PS> .\scripts\init-env.ps1 dev
    Standard init of the dev environment.

.EXAMPLE
    PS> .\scripts\init-env.ps1 -Environment prod -Upgrade
    Re-resolve provider versions for prod and refresh the lock file.

.NOTES
    Author : Ahmed Fakhfakh
    Repo   : https://github.com/fakhfakhahmed/terraform-azure-aks-platform
    Safe to re-run: init is idempotent and creates nothing billable.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('dev', 'staging', 'prod')]
    [string]$Environment,

    [switch]$Upgrade,
    [switch]$MigrateState,
    [switch]$SkipValidate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$global:LASTEXITCODE = 0

$RepoRoot = Split-Path -Parent $PSScriptRoot
$EnvDir   = Join-Path (Join-Path $RepoRoot 'envs') $Environment

$script:LastNativeExitCode = 0

# ---------------------------------------------------------------------------------------
# Helpers
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
    <#
        PowerShell does not raise a terminating error when an external executable exits
        non-zero - $ErrorActionPreference governs PowerShell errors, not process exit
        codes. Without this wrapper a failed `terraform init` would be followed by a
        cheerful "validate" step and a zero exit code.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int[]]$AllowedExitCodes = @(0),
        [string]$ErrorMessage
    )
    Write-Verbose ("exec: {0} {1}" -f $FilePath, ($Arguments -join ' '))
    $previous = $ErrorActionPreference
    # Relaxed because native stderr output under 'Stop' becomes a NativeCommandError in
    # Windows PowerShell, and terraform writes perfectly normal messages to stderr.
    $ErrorActionPreference = 'Continue'
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
Write-Colored "  terraform-azure-aks-platform :: init-env [$Environment]" ([System.ConsoleColor]::White)
Write-Colored "  repo root: $RepoRoot" ([System.ConsoleColor]::DarkGray)

$terraform = Get-CommandPath -Name 'terraform'
if ($null -eq $terraform) {
    throw "terraform was not found on PATH. Install it (winget install HashiCorp.Terraform) and re-run .\scripts\preflight.ps1."
}

if (-not (Test-Path -LiteralPath $EnvDir -PathType Container)) {
    throw "Environment directory '$EnvDir' does not exist. Expected one of envs/dev, envs/staging, envs/prod in a full clone of fakhfakhahmed/terraform-azure-aks-platform."
}

# -- backend.hcl must exist -------------------------------------------------------------
$backendFile    = Join-Path $EnvDir 'backend.hcl'
$backendExample = Join-Path $EnvDir 'backend.hcl.example'

if (-not (Test-Path -LiteralPath $backendFile -PathType Leaf)) {
    Write-Err "Missing backend configuration: $backendFile"
    Write-Colored "" ([System.ConsoleColor]::Yellow)
    Write-Warn 'backend.hcl holds the remote-state coordinates and is intentionally gitignored,'
    Write-Warn 'so a fresh clone never has one. Pick one of these:'
    Write-Colored "" ([System.ConsoleColor]::Yellow)
    Write-Info '  1. Generate all three from the bootstrap outputs (recommended):'
    Write-Info '       .\scripts\bootstrap-backend.ps1 -WriteBackendFiles'
    Write-Colored "" ([System.ConsoleColor]::Yellow)
    if (Test-Path -LiteralPath $backendExample -PathType Leaf) {
        Write-Info '  2. Copy the committed template and fill in the values:'
        Write-Info "       Copy-Item '$backendExample' '$backendFile'"
        Write-Info "       notepad '$backendFile'"
    } else {
        Write-Info '  2. Create it by hand with this shape:'
        Write-Info '       resource_group_name  = "<state rg>"'
        Write-Info '       storage_account_name = "<state storage account>"'
        Write-Info '       container_name       = "tfstate"'
        Write-Info "       key                  = `"$Environment/terraform.tfstate`""
        Write-Info '       use_azuread_auth     = true'
    }
    Write-Colored "" ([System.ConsoleColor]::Yellow)
    Write-Info '  3. If a teammate already bootstrapped, ask them for the storage account name;'
    Write-Info '     it is not a secret (access is controlled by Entra ID RBAC, not by the name).'
    exit 1
}

Write-Ok "backend config: $backendFile"

# Cheap validation of the backend file so a typo surfaces here rather than as an opaque
# "Error: Failed to get existing workspaces" three minutes into init.
$backendText = [string](Get-Content -LiteralPath $backendFile -Raw)
foreach ($key in @('resource_group_name', 'storage_account_name', 'container_name', 'key')) {
    if ($backendText -notmatch ("(?m)^\s*" + [regex]::Escape($key) + "\s*=")) {
        Write-Warn "backend.hcl does not define '$key' - terraform init will prompt for it or fail."
    }
}
$expectedKey = "$Environment/terraform.tfstate"
if ($backendText -notmatch [regex]::Escape($expectedKey)) {
    Write-Warn "backend.hcl does not contain the expected state key '$expectedKey'."
    Write-Warn "Initialising '$Environment' against another environment's state key would be a very bad day."
    Write-Warn 'Double-check the file before continuing.'
}

# -- ARM_SUBSCRIPTION_ID ----------------------------------------------------------------
# azurerm ~> 4.0 no longer falls back to the az CLI's default subscription; the provider
# requires subscription_id explicitly or via this variable. Setting it here keeps the
# backend, the provider and the az CLI pointed at the same place.
if (-not $env:ARM_SUBSCRIPTION_ID) {
    $az = Get-CommandPath -Name 'az'
    if ($null -ne $az) {
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $subId = & $az account show --query id --output tsv 2>$null
        } catch {
            $subId = $null
        } finally {
            $ErrorActionPreference = $previous
        }
        if ($global:LASTEXITCODE -eq 0 -and $subId) {
            $env:ARM_SUBSCRIPTION_ID = ([string]$subId).Trim()
            Write-Info "ARM_SUBSCRIPTION_ID set from the active az login: $env:ARM_SUBSCRIPTION_ID"
        } else {
            Write-Warn 'Could not read the active subscription from az (not logged in?). Run: az login'
        }
    }
} else {
    Write-Info "ARM_SUBSCRIPTION_ID already set: $env:ARM_SUBSCRIPTION_ID"
}

# -- init -------------------------------------------------------------------------------
$initArgs = @('init', '-input=false', '-backend-config=backend.hcl')

if ($MigrateState) {
    Write-Warn '-MigrateState requested: Terraform will attempt to MOVE state between backends.'
    Write-Warn 'Take a backup first:  terraform state pull > state-backup.json'
    if ([Environment]::UserInteractive) {
        $answer = Read-Host "Type 'migrate' to continue"
        if ($answer -cne 'migrate') {
            Write-Err 'Aborted. Nothing was changed.'
            exit 1
        }
    } else {
        throw '-MigrateState requires an interactive confirmation and this host is non-interactive.'
    }
    $initArgs += '-migrate-state'
} else {
    # See the .DESCRIPTION block above for why this is the default.
    $initArgs += '-reconfigure'
}

if ($Upgrade) {
    $initArgs += '-upgrade'
    Write-Info '-upgrade requested: provider/module versions will be re-resolved and .terraform.lock.hcl rewritten.'
    Write-Info 'Review the lock file diff and commit it with the change.'
}

try {
    # Push/Pop so a mid-run failure never strands the operator inside envs/<env>.
    Push-Location -LiteralPath $EnvDir

    Write-Step ("terraform " + ($initArgs -join ' '))
    Invoke-Native -FilePath $terraform -Arguments $initArgs -ErrorMessage @"
terraform init failed for '$Environment'.

Common causes:
  * Not logged in / token expired          -> az login
  * No RBAC on the state storage account   -> you need 'Storage Blob Data Contributor'
                                              on the state storage account (use_azuread_auth
                                              means the account key is NOT used)
  * Wrong storage account or container     -> check $backendFile
  * Corporate proxy blocking registry      -> set HTTPS_PROXY / NO_PROXY
"@

    if (-not $SkipValidate) {
        Write-Step 'terraform validate'
        Invoke-Native -FilePath $terraform -Arguments @('validate') `
            -ErrorMessage "terraform validate failed for '$Environment'. The backend is initialised but the configuration has errors."
        Write-Ok 'configuration is syntactically valid'
    }
}
finally {
    Pop-Location
}

Write-Step 'Done'
Write-Ok "'$Environment' is initialised against the remote backend."
Write-Info "Next:  .\scripts\plan-env.ps1 $Environment"
exit 0

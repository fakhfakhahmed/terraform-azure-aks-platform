#Requires -Version 5.1
<#
.SYNOPSIS
    One-time bootstrap: creates the Terraform remote-state backend and the GitHub OIDC
    Azure AD application, then prints everything you need to wire the repo up.

.DESCRIPTION
    This is the chicken-and-egg stack. Every environment under envs/ stores its state in
    an Azure Storage Account - but something has to create that storage account first, and
    that something cannot itself use a remote backend that does not exist yet. So the
    bootstrap/ stack runs with LOCAL state.

    What it creates:
      * a resource group for Terraform state
      * a storage account + the "tfstate" blob container (versioning / soft-delete on)
      * an Entra ID (Azure AD) application + federated credential for GitHub Actions OIDC,
        so CI never needs a client secret

    What this script does on top of `terraform apply`:
      1. Sanity-checks tooling and your Azure login, and pins ARM_SUBSCRIPTION_ID.
      2. Runs init + plan in bootstrap/ and shows you the plan.
      3. Asks for confirmation (skippable with -Force) BEFORE creating billable resources.
      4. Applies, reads `terraform output -json`, and prints:
           (a) the backend.hcl body for each of envs/dev, envs/staging, envs/prod
           (b) the `gh variable set` commands for the GitHub Actions workflow
      5. Optionally writes the three backend.hcl files for you (-WriteBackendFiles).

    IMPORTANT - LOCAL STATE
    bootstrap/terraform.tfstate lives on this machine only. It is gitignored and it must
    stay that way: it contains the storage account name and the Entra app object ids.
    Back it up somewhere safe (a password manager, an encrypted vault) or accept that
    re-running bootstrap on another machine will try to create everything again. Importing
    an existing backend is possible but tedious - treat the local state file as precious.

.PARAMETER SubscriptionId
    Target Azure subscription. Defaults to whatever `az account show` reports. When
    supplied, the script runs `az account set` first so az and Terraform agree.

.PARAMETER Location
    Azure region for the state resource group / storage account. Default: westeurope.

.PARAMETER Prefix
    Short naming prefix used by the bootstrap stack. Default: afk (Ahmed Fakhfakh).
    Keep it <= 6 lowercase alphanumeric characters - storage account names are globally
    unique, max 24 chars, and the stack appends a random suffix.

.PARAMETER WriteBackendFiles
    Also write envs/<env>/backend.hcl for dev, staging and prod using the applied outputs.
    Existing files are backed up to backend.hcl.bak first. These files are gitignored.

.PARAMETER Force
    Skip the interactive confirmation. Intended for a controlled CI bootstrap job, not for
    "I am in a hurry". Billable resources are created either way.

.EXAMPLE
    PS> .\scripts\bootstrap-backend.ps1
    Interactive bootstrap into the current subscription, westeurope, prefix afk.

.EXAMPLE
    PS> .\scripts\bootstrap-backend.ps1 -SubscriptionId 00000000-1111-2222-3333-444444444444 -Location northeurope -WriteBackendFiles
    Bootstrap into an explicit subscription and generate the three backend.hcl files.

.EXAMPLE
    PS> .\scripts\bootstrap-backend.ps1 -Force -WriteBackendFiles
    Non-interactive. Use only when you already know exactly what the plan contains.

.NOTES
    Author : Ahmed Fakhfakh
    Repo   : https://github.com/fakhfakhahmed/terraform-azure-aks-platform
    Run this ONCE per subscription. It is idempotent: a second run should plan zero
    changes, which is a cheap way to verify the backend is still intact.
#>
[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$Location = 'westeurope',
    [ValidatePattern('^[a-z0-9]{2,6}$')]
    [string]$Prefix = 'afk',
    [switch]$WriteBackendFiles,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$global:LASTEXITCODE = 0

$RepoRoot      = Split-Path -Parent $PSScriptRoot
$BootstrapDir  = Join-Path $RepoRoot 'bootstrap'
$GitHubRepo    = 'fakhfakhahmed/terraform-azure-aks-platform'
$Environments  = @('dev', 'staging', 'prod')
$PlanFile      = 'tfplan.bootstrap'

$script:LastNativeExitCode = 0

# ---------------------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------------------

function Write-Colored { param([string]$Message, [System.ConsoleColor]$Color)
    if ($env:NO_COLOR) { Write-Host $Message } else { Write-Host $Message -ForegroundColor $Color }
}
function Write-Step { param([string]$Message) Write-Colored ("`n==> $Message") ([System.ConsoleColor]::Cyan) }
function Write-Ok   { param([string]$Message) Write-Colored ("    $Message")   ([System.ConsoleColor]::Green) }
function Write-Warn { param([string]$Message) Write-Colored ("    $Message")   ([System.ConsoleColor]::Yellow) }
function Write-Err  { param([string]$Message) Write-Colored ("    $Message")   ([System.ConsoleColor]::Red) }
function Write-Info { param([string]$Message) Write-Colored ("    $Message")   ([System.ConsoleColor]::Gray) }

function Write-Banner {
    param([Parameter(Mandatory)][string[]]$Lines, [System.ConsoleColor]$Color = [System.ConsoleColor]::Yellow)
    $border = '*' * 78
    Write-Colored "" $Color
    Write-Colored $border $Color
    foreach ($line in $Lines) { Write-Colored ("* " + $line.PadRight(75) + "*") $Color }
    Write-Colored $border $Color
    Write-Colored "" $Color
}

# ---------------------------------------------------------------------------------------
# Native command helpers
#
# PowerShell does NOT turn a non-zero exit code from an external executable into a
# terminating error - $ErrorActionPreference only governs PowerShell's own error stream.
# `terraform apply` could fail and the script would merrily print "success" afterwards.
# Every external call therefore goes through one of these two helpers.
# ---------------------------------------------------------------------------------------

function Invoke-Native {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int[]]$AllowedExitCodes = @(0),
        [string]$ErrorMessage
    )
    Write-Verbose ("exec: {0} {1}" -f $FilePath, ($Arguments -join ' '))

    # Native stderr while $ErrorActionPreference is 'Stop' raises NativeCommandError in
    # Windows PowerShell. Terraform and az both write progress/warnings to stderr, so the
    # preference is relaxed for the duration of the call and the exit code is the only
    # thing we trust.
    $previous = $ErrorActionPreference
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

function Invoke-NativeCapture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int[]]$AllowedExitCodes = @(0),
        [string]$ErrorMessage
    )
    # stdout is captured; stderr goes to a temp file so a chatty tool (az loves writing
    # warnings to stderr) can never corrupt JSON we are about to parse.
    $stderrFile = Join-Path ([System.IO.Path]::GetTempPath()) ("tfaks-{0}.err" -f ([guid]::NewGuid().ToString('N')))
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $stdout = & $FilePath @Arguments 2> $stderrFile
        $code = $global:LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    $script:LastNativeExitCode = $code

    $stderrText = ''
    if (Test-Path -LiteralPath $stderrFile) {
        $stderrText = [string](Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue)
        Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue
    }

    if ($AllowedExitCodes -notcontains $code) {
        if ([string]::IsNullOrWhiteSpace($ErrorMessage)) {
            $ErrorMessage = "'$([System.IO.Path]::GetFileName($FilePath)) $($Arguments -join ' ')' failed with exit code $code."
        }
        if (-not [string]::IsNullOrWhiteSpace($stderrText)) { $ErrorMessage = "$ErrorMessage`n$($stderrText.Trim())" }
        throw $ErrorMessage
    }

    if ($null -eq $stdout) { return '' }
    return (($stdout | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
}

function Get-CommandPath {
    param([Parameter(Mandatory)][string]$Name)
    $cmd = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $cmd) { return $null }
    if ($cmd -is [System.Array]) { return $cmd[0].Source }
    return $cmd.Source
}

function Assert-Tool {
    param([Parameter(Mandatory)][string]$Name, [string]$Install = '')
    $path = Get-CommandPath -Name $Name
    if ($null -eq $path) {
        throw "Required tool '$Name' was not found on PATH. $Install`nRun .\scripts\preflight.ps1 for the full checklist."
    }
    return $path
}

function Confirm-Or-Exit {
    param(
        [Parameter(Mandatory)][string]$Question,
        [string]$Expected = 'yes'
    )
    if (-not [Environment]::UserInteractive) {
        throw "A confirmation is required but this host is non-interactive. Re-run with -Force only if you have already reviewed the plan."
    }
    Write-Colored "" ([System.ConsoleColor]::Yellow)
    Write-Colored "$Question" ([System.ConsoleColor]::Yellow)
    $answer = Read-Host "Type '$Expected' to continue"
    if ($answer -cne $Expected) {
        Write-Err "Aborted - you typed '$answer'. Nothing was applied."
        exit 1
    }
}

function Write-TextFileNoBom {
    # Terraform parses backend.hcl as UTF-8; a BOM written by PowerShell 5.1's
    # Set-Content -Encoding UTF8 has been known to upset HCL parsers. Write it ourselves.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Content)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Get-TfOutputValue {
    param(
        [Parameter(Mandatory)][object]$Outputs,
        [Parameter(Mandatory)][string]$Name,
        [switch]$Optional
    )
    if ($Outputs.PSObject.Properties.Name -contains $Name) {
        $entry = $Outputs.$Name
        if ($entry.PSObject.Properties.Name -contains 'value') { return [string]$entry.value }
    }
    if ($Optional) { return '' }
    throw "Bootstrap output '$Name' is missing. Expected outputs: state_resource_group_name, state_storage_account_name, state_container_name, github_actions_client_id, tenant_id, subscription_id. Check bootstrap/outputs.tf."
}

# ---------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------

Write-Colored "" ([System.ConsoleColor]::White)
Write-Colored "  terraform-azure-aks-platform :: bootstrap-backend" ([System.ConsoleColor]::White)
Write-Colored "  repo root: $RepoRoot" ([System.ConsoleColor]::DarkGray)

if (-not (Test-Path -LiteralPath $BootstrapDir -PathType Container)) {
    throw "bootstrap/ directory not found at '$BootstrapDir'. Run this from a full clone of $GitHubRepo."
}

Write-Banner -Color ([System.ConsoleColor]::Yellow) -Lines @(
    'COST WARNING - this script CREATES BILLABLE AZURE RESOURCES.',
    '',
    'It provisions a resource group, a storage account (GRS/LRS + versioning) and a',
    'blob container. A state storage account is cheap - typically well under 1 EUR',
    'per month at this volume - but it is NOT free, and it is not deleted for you.',
    '',
    'It also creates an Entra ID application + federated credential for GitHub OIDC.',
    'That is free, but it is a security principal: treat its lifecycle seriously.',
    '',
    'STATE IS LOCAL: bootstrap/terraform.tfstate stays on this machine. Back it up.'
)

# -- tooling + azure context ------------------------------------------------------------
Write-Step 'Checking tooling and Azure context'
$terraform = Assert-Tool -Name 'terraform' -Install 'Install: winget install HashiCorp.Terraform'
$az        = Assert-Tool -Name 'az'        -Install 'Install: winget install Microsoft.AzureCLI'
Write-Ok "terraform: $terraform"
Write-Ok "az:        $az"

if ($SubscriptionId) {
    Write-Info "Setting the active az subscription to $SubscriptionId ..."
    Invoke-Native -FilePath $az -Arguments @('account', 'set', '--subscription', $SubscriptionId) `
        -ErrorMessage "az account set failed for subscription '$SubscriptionId'. Are you logged in (az login) and does this account have access?"
}

$accountJson = Invoke-NativeCapture -FilePath $az -Arguments @('account', 'show', '--output', 'json') `
    -ErrorMessage "az account show failed - you are not logged in. Run: az login  (add --use-device-code on a headless host)."
$account = $accountJson | ConvertFrom-Json

$resolvedSubscriptionId = [string]$account.id
$resolvedTenantId       = [string]$account.tenantId
$resolvedSubName        = [string]$account.name

if (-not $SubscriptionId) { $SubscriptionId = $resolvedSubscriptionId }

Write-Ok "subscription: $resolvedSubName"
Write-Ok "id:           $resolvedSubscriptionId"
Write-Ok "tenant:       $resolvedTenantId"
Write-Ok "location:     $Location"
Write-Ok "prefix:       $Prefix"

# azurerm ~> 4.0 made subscription_id mandatory on the provider block (it no longer silently
# inherits the az CLI default). Exporting ARM_SUBSCRIPTION_ID guarantees provider and CLI
# agree even if the stack does not declare a subscription_id variable.
$env:ARM_SUBSCRIPTION_ID = $resolvedSubscriptionId
Write-Info 'ARM_SUBSCRIPTION_ID exported for this process (azurerm 4.x requires an explicit subscription).'

# -- build the -var list from what bootstrap/ actually declares --------------------------
# Hard-coding -var flags is brittle: if bootstrap/variables.tf does not declare a variable
# Terraform aborts with "Value for undeclared variable". Parse the declarations instead and
# only pass what exists. Aliases cover the usual naming variations.
Write-Step 'Resolving bootstrap input variables'

$declaredVars = New-Object 'System.Collections.Generic.List[string]'
Get-ChildItem -LiteralPath $BootstrapDir -Filter '*.tf' -File -ErrorAction SilentlyContinue | ForEach-Object {
    $content = [string](Get-Content -LiteralPath $_.FullName -Raw)
    foreach ($m in [regex]::Matches($content, '(?m)^\s*variable\s+"([^"]+)"')) {
        $declaredVars.Add($m.Groups[1].Value) | Out-Null
    }
}

$varCandidates = @(
    [pscustomobject]@{ Value = $SubscriptionId; Names = @('subscription_id', 'azure_subscription_id') },
    [pscustomobject]@{ Value = $Location;       Names = @('location', 'azure_location', 'region') },
    [pscustomobject]@{ Value = $Prefix;         Names = @('prefix', 'name_prefix', 'naming_prefix') }
)

$tfVarArgs = @()
foreach ($candidate in $varCandidates) {
    foreach ($name in $candidate.Names) {
        if ($declaredVars -contains $name) {
            $tfVarArgs += @('-var', ("{0}={1}" -f $name, $candidate.Value))
            Write-Ok "-var $name=$($candidate.Value)"
            break
        }
    }
}
if ($tfVarArgs.Count -eq 0) {
    Write-Info 'bootstrap/ declares none of the expected variables - relying on its defaults / terraform.tfvars.'
}

# -- init + plan ------------------------------------------------------------------------
# Push/Pop inside try/finally: a failure mid-apply must never leave the operator's shell
# sitting in bootstrap/ with a half-applied stack.
try {
    Push-Location -LiteralPath $BootstrapDir

    Write-Step 'terraform init (bootstrap uses LOCAL state - no -backend-config here)'
    Invoke-Native -FilePath $terraform -Arguments @('init', '-input=false') `
        -ErrorMessage 'terraform init failed in bootstrap/. Check your network/proxy and that the provider mirror is reachable.'

    Write-Step 'terraform validate'
    Invoke-Native -FilePath $terraform -Arguments @('validate') `
        -ErrorMessage 'terraform validate failed in bootstrap/. Fix the configuration before applying.'

    Write-Step 'terraform plan'
    $planArgs = @('plan', '-input=false', '-lock-timeout=5m', "-out=$PlanFile") + $tfVarArgs
    Invoke-Native -FilePath $terraform -Arguments $planArgs `
        -ErrorMessage 'terraform plan failed in bootstrap/.'

    if (-not $Force) {
        Confirm-Or-Exit -Question @"
Review the plan above. Continuing will CREATE the resources listed, in:
  subscription : $resolvedSubName ($resolvedSubscriptionId)
  location     : $Location
"@ -Expected 'yes'
    } else {
        Write-Warn '-Force supplied: skipping confirmation and applying immediately.'
    }

    Write-Step 'terraform apply'
    Invoke-Native -FilePath $terraform -Arguments @('apply', '-input=false', '-lock-timeout=5m', $PlanFile) `
        -ErrorMessage 'terraform apply failed in bootstrap/. The stack may be partially created - re-run this script, it is idempotent.'

    # A saved plan is single-use; leaving it around invites someone to apply a stale plan.
    if (Test-Path -LiteralPath $PlanFile) { Remove-Item -LiteralPath $PlanFile -Force -ErrorAction SilentlyContinue }

    Write-Step 'Reading outputs'
    $outputsJson = Invoke-NativeCapture -FilePath $terraform -Arguments @('output', '-json') `
        -ErrorMessage 'terraform output -json failed in bootstrap/.'
    $outputs = $outputsJson | ConvertFrom-Json
}
finally {
    Pop-Location
}

$stateRg        = Get-TfOutputValue -Outputs $outputs -Name 'state_resource_group_name'
$stateSa        = Get-TfOutputValue -Outputs $outputs -Name 'state_storage_account_name'
$stateContainer = Get-TfOutputValue -Outputs $outputs -Name 'state_container_name'
$clientId       = Get-TfOutputValue -Outputs $outputs -Name 'github_actions_client_id'
$tenantId       = Get-TfOutputValue -Outputs $outputs -Name 'tenant_id'
$subId          = Get-TfOutputValue -Outputs $outputs -Name 'subscription_id'

Write-Ok "state resource group : $stateRg"
Write-Ok "state storage account: $stateSa"
Write-Ok "state container      : $stateContainer"
Write-Ok "github oidc client id: $clientId"

# -- backend.hcl ------------------------------------------------------------------------
Write-Step 'Backend configuration (envs/<env>/backend.hcl)'
Write-Info 'backend.hcl is gitignored. backend.hcl.example is the committed template.'
Write-Info 'Each env initialises with:  terraform init -reconfigure -backend-config=backend.hcl'
Write-Colored "" ([System.ConsoleColor]::Gray)

function New-BackendHclContent {
    param([Parameter(Mandatory)][string]$EnvironmentName)
    return @"
# Generated by scripts/bootstrap-backend.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss K')
# Partial backend configuration for the '$EnvironmentName' environment.
# Consumed by: terraform init -reconfigure -backend-config=backend.hcl
# DO NOT COMMIT - this file is gitignored; backend.hcl.example is the committed template.

resource_group_name  = "$stateRg"
storage_account_name = "$stateSa"
container_name       = "$stateContainer"
key                  = "$EnvironmentName/terraform.tfstate"

# Authenticate to the state blob with the caller's Entra ID identity (az login locally,
# the federated OIDC principal in CI) instead of a shared storage account access key.
# Keys are long-lived credentials with full data-plane access - avoid them.
use_azuread_auth = true
"@
}

foreach ($envName in $Environments) {
    Write-Colored "----- envs/$envName/backend.hcl -----" ([System.ConsoleColor]::Magenta)
    Write-Host (New-BackendHclContent -EnvironmentName $envName)
    Write-Colored "" ([System.ConsoleColor]::Gray)
}

if ($WriteBackendFiles) {
    Write-Step 'Writing backend.hcl files'
    foreach ($envName in $Environments) {
        $envDir  = Join-Path (Join-Path $RepoRoot 'envs') $envName
        $target  = Join-Path $envDir 'backend.hcl'
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            $backup = "$target.bak"
            Copy-Item -LiteralPath $target -Destination $backup -Force
            Write-Warn "existing file backed up to $backup"
        }
        Write-TextFileNoBom -Path $target -Content (New-BackendHclContent -EnvironmentName $envName)
        Write-Ok "wrote $target"
    }
} else {
    Write-Info 'Re-run with -WriteBackendFiles to have these written for you.'
}

# -- GitHub configuration ---------------------------------------------------------------
Write-Step 'GitHub Actions configuration'
Write-Info 'These are repository VARIABLES, not secrets: with OIDC there is no client secret to'
Write-Info 'protect, and a client id / tenant id / subscription id are not sensitive on their own.'
Write-Info 'Access is controlled by the federated credential subject + the Azure role assignment.'
Write-Colored "" ([System.ConsoleColor]::Gray)
Write-Colored "----- paste into a shell with the gh CLI authenticated -----" ([System.ConsoleColor]::Magenta)

$ghCommands = @(
    "gh variable set AZURE_CLIENT_ID        --repo $GitHubRepo --body `"$clientId`"",
    "gh variable set AZURE_TENANT_ID        --repo $GitHubRepo --body `"$tenantId`"",
    "gh variable set AZURE_SUBSCRIPTION_ID  --repo $GitHubRepo --body `"$subId`"",
    "gh variable set TFSTATE_RESOURCE_GROUP --repo $GitHubRepo --body `"$stateRg`"",
    "gh variable set TFSTATE_STORAGE_ACCOUNT --repo $GitHubRepo --body `"$stateSa`"",
    "gh variable set TFSTATE_CONTAINER      --repo $GitHubRepo --body `"$stateContainer`""
)
foreach ($cmd in $ghCommands) { Write-Host "  $cmd" }
Write-Colored "" ([System.ConsoleColor]::Gray)

# -- closing notes ----------------------------------------------------------------------
Write-Banner -Color ([System.ConsoleColor]::Cyan) -Lines @(
    'BOOTSTRAP COMPLETE',
    '',
    'Next steps:',
    '  1. .\scripts\init-env.ps1 dev',
    '  2. .\scripts\plan-env.ps1 dev',
    '  3. .\scripts\apply-env.ps1 dev        (creates the AKS cluster - costs money)',
    '',
    'Reminder: bootstrap/terraform.tfstate is LOCAL and gitignored. Back it up.',
    'Reminder: tear dev down when you are done - see scripts/README.md.'
)

exit 0

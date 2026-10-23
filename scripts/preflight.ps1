#Requires -Version 5.1
<#
.SYNOPSIS
    Verifies that this workstation is ready to operate the terraform-azure-aks-platform repo.

.DESCRIPTION
    preflight.ps1 is the first script you should run on a new machine (or after a laptop
    rebuild, or when a colleague says "it works on mine"). It is strictly read-only: it
    creates nothing, deletes nothing and costs nothing, so it is safe to run as often as
    you like.

    It checks four things:

      1. Repository layout - the bootstrap/, envs/ and modules/ directories exist and the
         three environment directories (dev, staging, prod) are present. This catches the
         "I cloned only a sparse checkout" and "I am running this from the wrong folder"
         failure modes.

      2. Required tooling - terraform (>= 1.9), az, kubectl and git must be on PATH. The
         detected version is parsed and compared against the minimum the repo needs.
         A missing or too-old required tool fails the run (exit code 1).

      3. Optional tooling - tflint, checkov, conftest, infracost, terraform-docs and
         kubelogin. These only produce warnings. kubelogin deserves special attention:
         the AKS clusters in this repo are Entra ID (Azure AD) integrated with Azure RBAC
         and local accounts disabled, so `az aks get-credentials` alone produces a
         kubeconfig that kubectl cannot use. Without kubelogin every kubectl call fails
         with an opaque exec-plugin error. It is the single most common first-day gotcha.

      4. Azure context - `az account show` must succeed (you are logged in) and the active
         subscription is printed. If more than one subscription is visible you get a
         warning plus the exact `az account set` command, because applying an AKS cluster
         into the wrong subscription is an expensive and embarrassing mistake.

.PARAMETER SkipAzure
    Skip the `az account show` / subscription checks. Useful on an air-gapped machine or
    in a container image build where you only want to validate tooling.

.PARAMETER NoColor
    Disable ANSI colour output. Also honoured automatically via the NO_COLOR env var.

.EXAMPLE
    PS> .\scripts\preflight.ps1
    Runs the full checklist and exits 1 if a required check failed.

.EXAMPLE
    PS> .\scripts\preflight.ps1 -SkipAzure -NoColor
    Tooling-only run with plain output, suitable for piping into a log.

.NOTES
    Author : Ahmed Fakhfakh
    Repo   : https://github.com/fakhfakhahmed/terraform-azure-aks-platform
    Exit 0 = ready (warnings may still be present). Exit 1 = a required check failed.
#>
[CmdletBinding()]
param(
    [switch]$SkipAzure,
    [switch]$NoColor
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# $LASTEXITCODE is an *automatic global*. Seeding it here (explicitly in the global scope,
# never as a script-scoped copy, which would shadow the real one) means the first read of
# it cannot blow up under Set-StrictMode before any native command has run.
$global:LASTEXITCODE = 0

# ---------------------------------------------------------------------------------------
# Presentation helpers
# ---------------------------------------------------------------------------------------

$script:UseColor = $true
if ($NoColor) { $script:UseColor = $false }
if ($env:NO_COLOR) { $script:UseColor = $false }

# The source of this file is deliberately pure ASCII: Windows PowerShell 5.1 decodes a
# BOM-less .ps1 using the active ANSI code page, which would mangle literal check marks.
# Building the glyphs from code points at runtime keeps the file portable, and we fall
# back to ASCII when the console is not UTF-8 so the checklist never prints mojibake.
$script:GlyphPass = '+'
$script:GlyphFail = 'x'
$script:GlyphWarn = '!'
try {
    if ([Console]::OutputEncoding.CodePage -eq 65001) {
        $script:GlyphPass = [string][char]0x2714   # HEAVY CHECK MARK
        $script:GlyphFail = [string][char]0x2718   # HEAVY BALLOT X
        $script:GlyphWarn = [string][char]0x26A0   # WARNING SIGN
    }
} catch {
    # Some hosts (ISE, redirected output) do not expose a console encoding. ASCII it is.
}

function Write-Colored {
    param([string]$Message, [System.ConsoleColor]$Color)
    if ($script:UseColor) { Write-Host $Message -ForegroundColor $Color }
    else { Write-Host $Message }
}

function Write-Step { param([string]$Message) Write-Colored ("`n==> $Message") ([System.ConsoleColor]::Cyan) }
function Write-Ok   { param([string]$Message) Write-Colored ("    $Message")   ([System.ConsoleColor]::Green) }
function Write-Warn { param([string]$Message) Write-Colored ("    $Message")   ([System.ConsoleColor]::Yellow) }
function Write-Err  { param([string]$Message) Write-Colored ("    $Message")   ([System.ConsoleColor]::Red) }
function Write-Info { param([string]$Message) Write-Colored ("    $Message")   ([System.ConsoleColor]::Gray) }

# ---------------------------------------------------------------------------------------
# Result collection
# ---------------------------------------------------------------------------------------

$script:Checks = New-Object 'System.Collections.Generic.List[object]'

function Add-Check {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Pass', 'Fail', 'Warn')][string]$Status,
        [string]$Detail = '',
        [string]$Requirement = '',
        [string]$Hint = ''
    )
    $script:Checks.Add([pscustomobject]@{
        Name        = $Name
        Status      = $Status
        Detail      = $Detail
        Requirement = $Requirement
        Hint        = $Hint
    }) | Out-Null
}

function Show-Check {
    param([Parameter(Mandatory)][object]$Check, [int]$NameWidth = 16, [int]$DetailWidth = 22)

    $glyph = $script:GlyphWarn
    $color = [System.ConsoleColor]::Yellow
    if ($Check.Status -eq 'Pass') { $glyph = $script:GlyphPass; $color = [System.ConsoleColor]::Green }
    if ($Check.Status -eq 'Fail') { $glyph = $script:GlyphFail; $color = [System.ConsoleColor]::Red }

    $name   = $Check.Name.PadRight($NameWidth)
    $detail = $Check.Detail.PadRight($DetailWidth)
    $line   = "  $glyph  $name $detail $($Check.Requirement)"
    Write-Colored $line.TrimEnd() $color
    if ($Check.Hint) {
        Write-Colored ("       -> " + $Check.Hint) ([System.ConsoleColor]::DarkGray)
    }
}

# ---------------------------------------------------------------------------------------
# Tool discovery / version probing
# ---------------------------------------------------------------------------------------

function Get-CommandPath {
    <#
        Resolves an executable on PATH. -CommandType Application deliberately ignores
        PowerShell aliases and functions: we want the real binary (az resolves to az.cmd
        on Windows, which Application matches).
    #>
    param([Parameter(Mandatory)][string]$Name)
    $cmd = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $cmd) { return $null }
    if ($cmd -is [System.Array]) { return $cmd[0].Source }
    return $cmd.Source
}

function Invoke-VersionProbe {
    <#
        Runs "<tool> <args>" purely to read its version banner and returns the combined
        output as a single string. Several CLIs (kubelogin, older kubectl) print their
        version to stderr, so stderr is merged in. $ErrorActionPreference is relaxed for
        the duration because in Windows PowerShell a native command writing to stderr
        while the preference is 'Stop' raises a NativeCommandError - which would turn a
        harmless banner into a script-ending exception.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & $Path @Arguments 2>&1
    } catch {
        return $null
    } finally {
        $ErrorActionPreference = $previous
    }
    if ($null -eq $raw) { return $null }
    return (($raw | ForEach-Object { [string]$_ }) -join "`n")
}

function Get-SemVerFromText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $match = [regex]::Match($Text, 'v?(\d+)\.(\d+)(?:\.(\d+))?')
    if (-not $match.Success) { return $null }
    $patch = 0
    if ($match.Groups[3].Success) { $patch = [int]$match.Groups[3].Value }
    return (New-Object System.Version ([int]$match.Groups[1].Value), ([int]$match.Groups[2].Value), $patch)
}

function Test-Tool {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$ProbeArgs,
        [string[]]$ProbeArgsAlt,
        [System.Version]$MinVersion,
        [switch]$Required,
        [string]$Install = '',
        [string]$Why = ''
    )

    $kind = 'optional'
    if ($Required) { $kind = 'required' }

    $requirement = "($kind"
    if ($MinVersion) { $requirement += ", >= $($MinVersion.ToString(2))" }
    $requirement += ')'

    $path = Get-CommandPath -Name $Name
    if ($null -eq $path) {
        $status = 'Warn'
        if ($Required) { $status = 'Fail' }
        $hint = $Install
        if ($Why) { $hint = "$Why`n          $Install" }
        Add-Check -Name $Name -Status $status -Detail 'not found' -Requirement $requirement -Hint $hint
        return
    }

    $text = Invoke-VersionProbe -Path $path -Arguments $ProbeArgs
    $version = Get-SemVerFromText -Text $text
    if (($null -eq $version) -and $ProbeArgsAlt) {
        $text = Invoke-VersionProbe -Path $path -Arguments $ProbeArgsAlt
        $version = Get-SemVerFromText -Text $text
    }

    if ($null -eq $version) {
        # The binary exists but we could not parse a version. That is not a failure -
        # a tool we cannot fingerprint is still a tool we can call.
        Add-Check -Name $Name -Status 'Warn' -Detail 'installed (version ?)' -Requirement $requirement -Hint "Could not parse a version from '$Name $($ProbeArgs -join ' ')'. Found at: $path"
        return
    }

    $detail = $version.ToString()
    if ($MinVersion -and ($version -lt $MinVersion)) {
        $status = 'Warn'
        if ($Required) { $status = 'Fail' }
        Add-Check -Name $Name -Status $status -Detail $detail -Requirement $requirement -Hint "Installed version is older than the minimum this repo targets. $Install"
        return
    }

    Add-Check -Name $Name -Status 'Pass' -Detail $detail -Requirement $requirement
}

# ---------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------

# Always resolve paths from the script location, never from the caller's current
# directory. Operators run these from anywhere - C:\, a sibling repo, a scheduled task.
$RepoRoot = Split-Path -Parent $PSScriptRoot

Write-Colored "" ([System.ConsoleColor]::White)
Write-Colored "  terraform-azure-aks-platform :: preflight" ([System.ConsoleColor]::White)
Write-Colored "  repo root: $RepoRoot" ([System.ConsoleColor]::DarkGray)

# -- 1. repository layout ---------------------------------------------------------------
Write-Step 'Repository layout'

$requiredDirs = @(
    @{ Path = 'bootstrap';     Why = 'remote-state backend + GitHub OIDC app (local state, run once)' },
    @{ Path = 'modules';       Why = 'reusable Terraform modules' },
    @{ Path = 'envs';          Why = 'directory-per-environment root modules' },
    @{ Path = 'envs/dev';      Why = 'dev root module' },
    @{ Path = 'envs/staging';  Why = 'staging root module' },
    @{ Path = 'envs/prod';     Why = 'prod root module' }
)

foreach ($dir in $requiredDirs) {
    $full = Join-Path $RepoRoot $dir.Path
    if (Test-Path -LiteralPath $full -PathType Container) {
        Add-Check -Name $dir.Path -Status 'Pass' -Detail 'present' -Requirement "($($dir.Why))"
    } else {
        Add-Check -Name $dir.Path -Status 'Fail' -Detail 'MISSING' -Requirement "($($dir.Why))" -Hint "Expected directory '$full'. Are you running preflight.ps1 from inside a full clone of fakhfakhahmed/terraform-azure-aks-platform?"
    }
}

$layoutChecks = @($script:Checks)
foreach ($check in $layoutChecks) { Show-Check -Check $check -NameWidth 14 -DetailWidth 9 }

# Informational only: backend.hcl is gitignored, so a fresh clone will never have one.
$missingBackends = @()
foreach ($envName in @('dev', 'staging', 'prod')) {
    $backendFile = Join-Path (Join-Path (Join-Path $RepoRoot 'envs') $envName) 'backend.hcl'
    if (-not (Test-Path -LiteralPath $backendFile -PathType Leaf)) { $missingBackends += $envName }
}
if ($missingBackends.Count -gt 0) {
    Write-Info "note: backend.hcl missing for: $($missingBackends -join ', ')  (expected on a fresh clone - it is gitignored)"
    Write-Info "      generate them with: .\scripts\bootstrap-backend.ps1 -WriteBackendFiles"
    Write-Info "      or copy envs/<env>/backend.hcl.example to envs/<env>/backend.hcl and fill it in."
}

# -- 2. required tooling ----------------------------------------------------------------
Write-Step 'Required tooling'
$script:Checks.Clear()

Test-Tool -Name 'terraform' -Required -MinVersion (New-Object System.Version 1, 9, 0) `
    -ProbeArgs @('version', '-json') -ProbeArgsAlt @('version') `
    -Install 'winget install HashiCorp.Terraform   |   choco install terraform   |   brew install terraform   |   https://developer.hashicorp.com/terraform/install'

Test-Tool -Name 'az' -Required -MinVersion (New-Object System.Version 2, 60, 0) `
    -ProbeArgs @('version', '--output', 'json') `
    -Install 'winget install Microsoft.AzureCLI   |   brew install azure-cli   |   https://learn.microsoft.com/cli/azure/install-azure-cli'

Test-Tool -Name 'kubectl' -Required -MinVersion (New-Object System.Version 1, 28, 0) `
    -ProbeArgs @('version', '--client', '-o', 'json') -ProbeArgsAlt @('version', '--client') `
    -Install 'az aks install-cli   |   winget install Kubernetes.kubectl   |   brew install kubectl'

Test-Tool -Name 'git' -Required -MinVersion (New-Object System.Version 2, 30, 0) `
    -ProbeArgs @('--version') `
    -Install 'winget install Git.Git   |   brew install git'

foreach ($check in $script:Checks) { Show-Check -Check $check }
$requiredFailures = @($script:Checks | Where-Object { $_.Status -eq 'Fail' }).Count

# Terraform deserves an explicit callout: the repo pins `required_version >= 1.9` because
# it uses provider-defined functions and the `removed` block semantics introduced there.
$terraformCheck = $script:Checks | Where-Object { $_.Name -eq 'terraform' } | Select-Object -First 1
if ($terraformCheck -and $terraformCheck.Status -ne 'Pass' -and $terraformCheck.Detail -ne 'not found') {
    Write-Warn "terraform $($terraformCheck.Detail) is below the 1.9 floor this repo pins in versions.tf."
    Write-Warn "Upgrade before running init - a too-old binary fails at init with a required_version error."
}

# -- 3. optional tooling ----------------------------------------------------------------
Write-Step 'Optional tooling (quality gates and conveniences)'
$script:Checks.Clear()

Test-Tool -Name 'kubelogin' -MinVersion (New-Object System.Version 0, 1, 0) `
    -ProbeArgs @('--version') `
    -Why 'REQUIRED IN PRACTICE for these clusters: AKS here is Entra ID integrated with Azure RBAC and local accounts disabled, so the kubeconfig uses an exec credential plugin. Without kubelogin, every kubectl command fails.' `
    -Install 'az aks install-cli (installs kubelogin too)   |   winget install Microsoft.Azure.Kubelogin   |   brew install Azure/kubelogin/kubelogin'

Test-Tool -Name 'tflint' -MinVersion (New-Object System.Version 0, 50, 0) `
    -ProbeArgs @('--version') `
    -Why 'Linting: catches invalid Azure VM sizes/regions before a 10-minute apply does.' `
    -Install 'winget install TFLint.TFLint   |   brew install tflint'

Test-Tool -Name 'checkov' -MinVersion (New-Object System.Version 3, 0, 0) `
    -ProbeArgs @('--version') `
    -Why 'Static security scanning of the Terraform plan.' `
    -Install 'pipx install checkov   |   pip install checkov   |   brew install checkov'

Test-Tool -Name 'conftest' -MinVersion (New-Object System.Version 0, 45, 0) `
    -ProbeArgs @('--version') `
    -Why 'Rego policy gate - plan-env.ps1 runs it automatically against policy/conftest when present.' `
    -Install 'winget install OpenPolicyAgent.Conftest   |   brew install conftest'

Test-Tool -Name 'infracost' -MinVersion (New-Object System.Version 0, 10, 0) `
    -ProbeArgs @('--version') `
    -Why 'Cost estimation - see scripts/cost-estimate.ps1. Free tier is sufficient.' `
    -Install 'winget install Infracost.Infracost   |   choco install infracost   |   brew install infracost'

Test-Tool -Name 'terraform-docs' -MinVersion (New-Object System.Version 0, 17, 0) `
    -ProbeArgs @('--version') `
    -Why 'Regenerates the module README tables.' `
    -Install 'winget install Terraform-docs.Terraform-docs   |   brew install terraform-docs'

foreach ($check in $script:Checks) { Show-Check -Check $check }

$kubeloginCheck = $script:Checks | Where-Object { $_.Name -eq 'kubelogin' } | Select-Object -First 1
if ($kubeloginCheck -and $kubeloginCheck.Status -ne 'Pass') {
    Write-Warn 'kubelogin is formally optional but practically mandatory here.'
    Write-Warn 'connect-aks.ps1 runs `kubelogin convert-kubeconfig -l azurecli` after fetching credentials;'
    Write-Warn 'without it kubectl reports: "no Auth Provider found for name azure" or an exec plugin error.'
}

# -- 4. azure context -------------------------------------------------------------------
$azureFailures = 0
if ($SkipAzure) {
    Write-Step 'Azure context (skipped via -SkipAzure)'
} else {
    Write-Step 'Azure context'
    $azPath = Get-CommandPath -Name 'az'
    if ($null -eq $azPath) {
        Write-Err 'az is not installed - skipping the subscription checks (already counted as a failure above).'
    } else {
        $accountJson = Invoke-VersionProbe -Path $azPath -Arguments @('account', 'show', '--output', 'json')
        $account = $null
        if ($accountJson) {
            try { $account = $accountJson | ConvertFrom-Json } catch { $account = $null }
        }

        if ($null -eq $account) {
            $azureFailures++
            Write-Err 'az account show failed - you are not logged in (or the token expired).'
            Write-Info 'Fix:  az login           (add --use-device-code on a headless/remote host)'
            Write-Info '      az login --tenant <tenant-id>   if you belong to several tenants'
        } else {
            $subName = ''
            $subId = ''
            $tenantId = ''
            $userName = ''
            if ($account.PSObject.Properties.Name -contains 'name')     { $subName  = [string]$account.name }
            if ($account.PSObject.Properties.Name -contains 'id')       { $subId    = [string]$account.id }
            if ($account.PSObject.Properties.Name -contains 'tenantId') { $tenantId = [string]$account.tenantId }
            if ($account.PSObject.Properties.Name -contains 'user') {
                if ($account.user -and ($account.user.PSObject.Properties.Name -contains 'name')) {
                    $userName = [string]$account.user.name
                }
            }

            Write-Ok   "$script:GlyphPass  logged in as    $userName"
            Write-Ok   "$script:GlyphPass  subscription    $subName"
            Write-Ok   "$script:GlyphPass  subscription id $subId"
            Write-Ok   "$script:GlyphPass  tenant id       $tenantId"

            # More than one subscription in scope is the classic "applied an AKS cluster
            # into the client's production subscription" accident. Warn loudly.
            $listJson = Invoke-VersionProbe -Path $azPath -Arguments @('account', 'list', '--all', '--output', 'json')
            $subs = @()
            if ($listJson) {
                try { $subs = @($listJson | ConvertFrom-Json) } catch { $subs = @() }
            }
            $enabled = @($subs | Where-Object { $_.PSObject.Properties.Name -contains 'state' -and $_.state -eq 'Enabled' })
            if ($enabled.Count -gt 1) {
                Write-Warn "$script:GlyphWarn  $($enabled.Count) subscriptions are visible to this login."
                Write-Warn '    Terraform will use whichever one is ACTIVE (or ARM_SUBSCRIPTION_ID if set).'
                Write-Warn '    Switch with:  az account set --subscription "<name-or-id>"'
                Write-Info '    Visible subscriptions:'
                foreach ($sub in $enabled) {
                    $marker = '  '
                    if ($sub.PSObject.Properties.Name -contains 'isDefault' -and $sub.isDefault) { $marker = '* ' }
                    Write-Info ("      {0}{1}  ({2})" -f $marker, $sub.name, $sub.id)
                }
            }

            if ($env:ARM_SUBSCRIPTION_ID -and ($env:ARM_SUBSCRIPTION_ID -ne $subId)) {
                Write-Warn "$script:GlyphWarn  ARM_SUBSCRIPTION_ID ($env:ARM_SUBSCRIPTION_ID) differs from the active az subscription ($subId)."
                Write-Warn '    The azurerm provider honours ARM_SUBSCRIPTION_ID, so Terraform will target that one.'
            }
        }
    }
}

# -- summary ----------------------------------------------------------------------------
$layoutFailures = @($layoutChecks | Where-Object { $_.Status -eq 'Fail' }).Count
$totalFailures  = $layoutFailures + $requiredFailures + $azureFailures

Write-Step 'Summary'
if ($totalFailures -eq 0) {
    Write-Ok "$script:GlyphPass  All required checks passed. You are ready to run bootstrap-backend.ps1 / init-env.ps1."
    Write-Info 'Next:  .\scripts\bootstrap-backend.ps1        (first time only - creates the remote state backend)'
    Write-Info '       .\scripts\init-env.ps1 dev'
    Write-Info '       .\scripts\plan-env.ps1 dev'
    exit 0
}

Write-Err "$script:GlyphFail  $totalFailures required check(s) failed. Fix the items marked above before continuing."
Write-Info 'Re-run this script after each fix - it is idempotent and free.'
exit 1

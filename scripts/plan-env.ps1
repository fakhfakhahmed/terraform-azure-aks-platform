#Requires -Version 5.1
<#
.SYNOPSIS
    Produces a saved Terraform plan for one environment, summarises it, and runs the
    Rego policy gate. Never applies anything.

.DESCRIPTION
    plan-env.ps1 is the read-mostly workhorse of this repo. It:

      1. Runs init automatically if envs/<env>/.terraform is missing, so a fresh clone
         needs one command instead of two.
      2. Runs `terraform plan -input=false -lock-timeout=5m -out=<file>`. The lock timeout
         matters: the azurerm backend takes a blob lease, and a colleague's CI run holding
         it for 30 seconds should make you wait, not fail.
      3. Parses `terraform show -json <plan>` and prints a human summary, calling out
         DESTROY and REPLACE actions in red - those are the ones that ruin afternoons.
      4. If conftest is installed and policy/conftest exists, evaluates the plan JSON
         against the Rego policies. A policy failure fails the script.

    A plan is a read operation against Azure, so it is safe and free. It does refresh
    state, which means it needs the same credentials an apply would.

    -Detailed and exit codes
    -----------------------------------------------------------------------------------
    With -Detailed the script passes -detailed-exitcode to Terraform, which splits the
    outcome into three: 0 = no changes, 1 = error, 2 = changes present. Exit code 2 is NOT
    a failure here - it is the signal a drift-detection pipeline wants. The script
    propagates it verbatim so a scheduled job can do:

        .\scripts\plan-env.ps1 prod -Detailed
        if ($LASTEXITCODE -eq 2) { # open a drift ticket }

.PARAMETER Environment
    dev, staging or prod. Positional.

.PARAMETER Out
    Plan output file name, relative to envs/<env>. Default: tfplan.

.PARAMETER Detailed
    Pass -detailed-exitcode and propagate exit code 2 when changes are present.

.PARAMETER Destroy
    Produce a DESTROY plan (`terraform plan -destroy`). Still never applies - but it is
    the correct way to preview a teardown before running it.

.PARAMETER SkipPolicy
    Do not run conftest even when it is installed.

.PARAMETER KeepPlanJson
    Keep the intermediate <out>.json file instead of deleting it. Useful for feeding
    checkov, opa eval, or your own jq one-liners.

.PARAMETER Refresh
    Set to $false to pass -refresh=false. Faster, and the right call when you are
    iterating on a module and know nothing drifted. Default $true.

.EXAMPLE
    PS> .\scripts\plan-env.ps1 dev
    Plan dev into envs/dev/tfplan, summarise, run the policy gate.

.EXAMPLE
    PS> .\scripts\plan-env.ps1 prod -Detailed
    Drift check for prod. Exit 2 means "prod has drifted or has pending changes".

.EXAMPLE
    PS> .\scripts\plan-env.ps1 dev -Destroy -Out tfplan.destroy
    Preview exactly what a teardown of dev would remove.

.NOTES
    Author : Ahmed Fakhfakh
    Repo   : https://github.com/fakhfakhahmed/terraform-azure-aks-platform
    Exit 0 = no changes / plan produced. Exit 1 = error or policy failure.
    Exit 2 = (-Detailed only) changes present.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('dev', 'staging', 'prod')]
    [string]$Environment,

    [string]$Out = 'tfplan',
    [switch]$Detailed,
    [switch]$Destroy,
    [switch]$SkipPolicy,
    [switch]$KeepPlanJson,
    [bool]$Refresh = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$global:LASTEXITCODE = 0

$RepoRoot   = Split-Path -Parent $PSScriptRoot
$EnvDir     = Join-Path (Join-Path $RepoRoot 'envs') $Environment
$PolicyDir  = Join-Path (Join-Path $RepoRoot 'policy') 'conftest'
$PlanJson   = "$Out.json"

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
        A non-zero exit from a native exe is NOT a PowerShell error - execution would
        continue as if nothing happened. Every external call is funnelled through here so
        failures stop the script, and so -detailed-exitcode's "2" can be whitelisted
        explicitly rather than accidentally swallowed.
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

function Get-ActionKind {
    <#
        Terraform encodes the change as an array of actions. Map it to one of our buckets.
          ["create"]            -> create
          ["update"]            -> update
          ["delete"]            -> delete
          ["delete","create"]   -> replace   (and ["create","delete"] for create_before_destroy)
          ["no-op"] / ["read"]  -> ignored
    #>
    param([Parameter(Mandatory)][string[]]$Actions)
    if ($Actions.Count -eq 2 -and ($Actions -contains 'delete') -and ($Actions -contains 'create')) { return 'replace' }
    if ($Actions -contains 'create') { return 'create' }
    if ($Actions -contains 'delete') { return 'delete' }
    if ($Actions -contains 'update') { return 'update' }
    return 'noop'
}

# ---------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------

Write-Colored "" ([System.ConsoleColor]::White)
Write-Colored "  terraform-azure-aks-platform :: plan-env [$Environment]" ([System.ConsoleColor]::White)
Write-Colored "  repo root: $RepoRoot" ([System.ConsoleColor]::DarkGray)

$terraform = Get-CommandPath -Name 'terraform'
if ($null -eq $terraform) {
    throw "terraform was not found on PATH. Run .\scripts\preflight.ps1 for the full checklist."
}

if (-not (Test-Path -LiteralPath $EnvDir -PathType Container)) {
    throw "Environment directory '$EnvDir' does not exist."
}

$backendFile = Join-Path $EnvDir 'backend.hcl'
if (-not (Test-Path -LiteralPath $backendFile -PathType Leaf)) {
    throw "Missing '$backendFile'. Run: .\scripts\init-env.ps1 $Environment  (it explains how to create it), or .\scripts\bootstrap-backend.ps1 -WriteBackendFiles"
}

# Auto-init on a cold directory. Delegating to init-env.ps1 keeps the backend handling in
# exactly one place instead of duplicating the -reconfigure logic here.
$terraformDir = Join-Path $EnvDir '.terraform'
if (-not (Test-Path -LiteralPath $terraformDir -PathType Container)) {
    Write-Step "envs/$Environment/.terraform not found - running init first"
    & (Join-Path $PSScriptRoot 'init-env.ps1') -Environment $Environment -SkipValidate
    if ($LASTEXITCODE -ne 0) { throw "init-env.ps1 failed for '$Environment' (exit $LASTEXITCODE)." }
}

if (-not $env:ARM_SUBSCRIPTION_ID) {
    $az = Get-CommandPath -Name 'az'
    if ($null -ne $az) {
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { $subId = & $az account show --query id --output tsv 2>$null } catch { $subId = $null } finally { $ErrorActionPreference = $previous }
        if ($global:LASTEXITCODE -eq 0 -and $subId) {
            $env:ARM_SUBSCRIPTION_ID = ([string]$subId).Trim()
        }
    }
}

$exitCode = 0

try {
    Push-Location -LiteralPath $EnvDir

    # -- plan ---------------------------------------------------------------------------
    $planArgs = @('plan', '-input=false', '-lock-timeout=5m', "-out=$Out")
    if ($Destroy) { $planArgs += '-destroy' }
    if (-not $Refresh) { $planArgs += '-refresh=false' }

    $allowed = @(0)
    if ($Detailed) {
        $planArgs += '-detailed-exitcode'
        $allowed = @(0, 2)
    }

    if ($Destroy) {
        Write-Warn 'This is a DESTROY plan. Nothing is destroyed by planning, but read it carefully.'
    }

    Write-Step ("terraform " + ($planArgs -join ' '))
    Invoke-Native -FilePath $terraform -Arguments $planArgs -AllowedExitCodes $allowed -ErrorMessage @"
terraform plan failed for '$Environment'.

Common causes:
  * Expired Azure token                 -> az login
  * State blob lease held by CI         -> wait, or inspect with: terraform force-unlock <id> (last resort)
  * Missing required variable           -> check envs/$Environment/terraform.tfvars
  * Insufficient RBAC on the state blob -> you need Storage Blob Data Contributor
"@
    $planExit = $script:LastNativeExitCode

    if ($Detailed) {
        if ($planExit -eq 2) {
            Write-Warn 'detailed-exitcode = 2 : changes are present (drift, or pending config changes).'
            Write-Warn 'This is informational, not an error.'
            $exitCode = 2
        } else {
            Write-Ok 'detailed-exitcode = 0 : infrastructure matches the configuration. No drift.'
        }
    }

    # -- change summary -----------------------------------------------------------------
    Write-Step 'Change summary'

    # `terraform show -json <plan>` is the machine-readable form of the plan. We write it
    # to disk because conftest (next step) consumes a file, and because it is genuinely
    # useful to keep around while debugging (-KeepPlanJson).
    $showExit = 0
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $showOutput = & $terraform show -json $Out 2>$null
        $showExit = $global:LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }

    if ($showExit -eq 0) {
        # Written with an explicit BOM-less UTF-8 encoder: Set-Content -Encoding UTF8 on
        # Windows PowerShell 5.1 emits a BOM, and a leading BOM breaks both
        # ConvertFrom-Json and conftest's JSON parser.
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        $joined = ''
        if ($null -ne $showOutput) { $joined = (($showOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) }
        [System.IO.File]::WriteAllText((Join-Path $EnvDir $PlanJson), $joined, $utf8NoBom)
    }

    if ($showExit -ne 0) {
        Write-Warn "terraform show -json exited $showExit - skipping the structured summary."
    } else {
        $planData = $null
        try {
            $planData = (Get-Content -LiteralPath $PlanJson -Raw) | ConvertFrom-Json
        } catch {
            Write-Warn "Could not parse $PlanJson - skipping the structured summary."
        }

        if ($null -ne $planData -and ($planData.PSObject.Properties.Name -contains 'resource_changes')) {
            $creates  = New-Object 'System.Collections.Generic.List[string]'
            $updates  = New-Object 'System.Collections.Generic.List[string]'
            $deletes  = New-Object 'System.Collections.Generic.List[string]'
            $replaces = New-Object 'System.Collections.Generic.List[string]'

            foreach ($rc in @($planData.resource_changes)) {
                if (-not ($rc.PSObject.Properties.Name -contains 'change')) { continue }
                if (-not ($rc.change.PSObject.Properties.Name -contains 'actions')) { continue }
                $address = [string]$rc.address
                $kind = Get-ActionKind -Actions ([string[]]@($rc.change.actions))
                switch ($kind) {
                    'create'  { $creates.Add($address)  | Out-Null }
                    'update'  { $updates.Add($address)  | Out-Null }
                    'delete'  { $deletes.Add($address)  | Out-Null }
                    'replace' { $replaces.Add($address) | Out-Null }
                    default   { }
                }
            }

            $total = $creates.Count + $updates.Count + $deletes.Count + $replaces.Count
            if ($total -eq 0) {
                Write-Ok 'No changes. Infrastructure matches the configuration.'
            } else {
                Write-Ok      ("  create  : {0}" -f $creates.Count)
                Write-Colored ("      update  : {0}" -f $updates.Count) ([System.ConsoleColor]::Yellow)
                Write-Colored ("      replace : {0}" -f $replaces.Count) ([System.ConsoleColor]::Magenta)
                Write-Colored ("      destroy : {0}" -f $deletes.Count) ([System.ConsoleColor]::Red)

                # Destroys and replaces are the dangerous half of any plan. Enumerate them
                # explicitly so nobody has to scroll back through 400 lines of diff.
                if ($replaces.Count -gt 0) {
                    Write-Colored "`n      RESOURCES TO BE REPLACED (destroyed and recreated):" ([System.ConsoleColor]::Magenta)
                    foreach ($address in $replaces) { Write-Colored "        -/+ $address" ([System.ConsoleColor]::Magenta) }
                    Write-Warn 'A replace on a stateful resource (AKS node pool, storage, Key Vault) means downtime or data loss.'
                }
                if ($deletes.Count -gt 0) {
                    Write-Colored "`n      RESOURCES TO BE DESTROYED:" ([System.ConsoleColor]::Red)
                    foreach ($address in $deletes) { Write-Colored "        -   $address" ([System.ConsoleColor]::Red) }
                }
            }
        }
    }

    # -- policy gate --------------------------------------------------------------------
    $conftest = Get-CommandPath -Name 'conftest'
    if ($SkipPolicy) {
        Write-Step 'Policy gate skipped (-SkipPolicy)'
    } elseif ($null -eq $conftest) {
        Write-Step 'Policy gate'
        Write-Warn 'conftest is not installed - skipping the Rego policy evaluation.'
        Write-Info 'Install: winget install OpenPolicyAgent.Conftest  |  brew install conftest'
        Write-Info 'CI runs this gate regardless, so a local skip only defers the feedback.'
    } elseif (-not (Test-Path -LiteralPath $PolicyDir -PathType Container)) {
        Write-Step 'Policy gate'
        Write-Warn "conftest is installed but '$PolicyDir' does not exist - nothing to evaluate."
    } elseif (-not (Test-Path -LiteralPath $PlanJson -PathType Leaf)) {
        Write-Step 'Policy gate'
        Write-Warn 'Plan JSON was not produced - skipping the policy evaluation.'
    } else {
        Write-Step "conftest test --policy policy/conftest $PlanJson"
        # --all-namespaces so policies are not silently ignored when they declare a package
        # other than `main` (e.g. package terraform.azure.aks).
        Invoke-Native -FilePath $conftest -Arguments @('test', '--policy', $PolicyDir, '--all-namespaces', $PlanJson) `
            -ErrorMessage "Policy violations found in the '$Environment' plan. Fix the configuration (or the policy, with a good reason) before applying."
        Write-Ok 'All policies passed.'
    }

    if (-not $KeepPlanJson -and (Test-Path -LiteralPath $PlanJson -PathType Leaf)) {
        Remove-Item -LiteralPath $PlanJson -Force -ErrorAction SilentlyContinue
    } elseif ($KeepPlanJson) {
        Write-Info "plan JSON kept at: $(Join-Path $EnvDir $PlanJson)"
    }
}
finally {
    Pop-Location
}

# -- next steps -------------------------------------------------------------------------
Write-Step 'Done - NOTHING WAS APPLIED'
Write-Ok "Saved plan: $(Join-Path $EnvDir $Out)"
Write-Info 'A saved plan is a snapshot. If the configuration or remote state changes, Terraform'
Write-Info 'will refuse to apply it - re-plan rather than forcing it.'
Write-Colored "" ([System.ConsoleColor]::Gray)
Write-Info "To apply:  .\scripts\apply-env.ps1 $Environment -PlanFile $Out"

exit $exitCode

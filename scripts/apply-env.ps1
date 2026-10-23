#Requires -Version 5.1
<#
.SYNOPSIS
    Applies Terraform for one environment, with cost warnings and a break-glass guard
    around production.

.DESCRIPTION
    This is the only script in the repo that creates billable infrastructure in an
    environment. It is deliberately noisy and deliberately hard to misuse.

    Behaviour:
      * Runs init if envs/<env>/.terraform is missing.
      * If a saved plan file exists, it applies THAT - the whole point of a saved plan is
        that what you reviewed is what gets applied. The plan file is deleted afterwards
        because a saved plan is single-use and a stale one is a trap.
      * If no plan file exists it plans first, shows you the result, and asks before
        applying.
      * Prints the outputs and a teardown reminder at the end.

    PRODUCTION IS GUARDED
    -----------------------------------------------------------------------------------
    Applying to prod from a laptop is a smell, not a workflow. The sanctioned path is the
    GitHub Actions pipeline, where a GitHub Environment with required reviewers gates the
    apply, the OIDC principal is scoped to exactly what it needs, and there is an audit
    trail that is not "Ahmed says he ran it on Tuesday".

    This script therefore refuses prod unless BOTH hold:
      1. -Force is passed, and
      2. you type the literal string  apply-prod  at an interactive prompt.

    That is break-glass: the pipeline is down, there is an incident, and someone senior
    decided a manual apply is the lesser evil. If you find yourself typing apply-prod
    routinely, the pipeline is what needs fixing.

.PARAMETER Environment
    dev, staging or prod. Positional.

.PARAMETER PlanFile
    Saved plan to apply, relative to envs/<env>. Default: tfplan. If the file does not
    exist the script plans first.

.PARAMETER Force
    Skip the yes/no confirmation for dev and staging. For prod it is necessary but NOT
    sufficient - the typed apply-prod confirmation is always required.

.PARAMETER KeepPlanFile
    Do not delete the plan file after a successful apply. Off by default on purpose.

.EXAMPLE
    PS> .\scripts\apply-env.ps1 dev
    Apply envs/dev/tfplan if present, otherwise plan then apply after confirmation.

.EXAMPLE
    PS> .\scripts\apply-env.ps1 staging -PlanFile tfplan -Force
    Non-interactive staging apply of an already-reviewed plan.

.EXAMPLE
    PS> .\scripts\apply-env.ps1 prod -Force
    Break-glass production apply. You will still have to type apply-prod.

.NOTES
    Author : Ahmed Fakhfakh
    Repo   : https://github.com/fakhfakhahmed/terraform-azure-aks-platform
    COST: an AKS cluster with its node pools, a Log Analytics workspace, an ACR and a
    Key Vault is NOT free. Destroy dev when you are done - see the reminder printed at
    the end of a successful run.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('dev', 'staging', 'prod')]
    [string]$Environment,

    [string]$PlanFile = 'tfplan',
    [switch]$Force,
    [switch]$KeepPlanFile
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

function Write-Banner {
    param([Parameter(Mandatory)][string[]]$Lines, [System.ConsoleColor]$Color = [System.ConsoleColor]::Yellow)
    $border = '*' * 78
    Write-Colored "" $Color
    Write-Colored $border $Color
    foreach ($line in $Lines) {
        $text = $line
        if ($text.Length -gt 74) { $text = $text.Substring(0, 74) }
        Write-Colored ("* " + $text.PadRight(75) + "*") $Color
    }
    Write-Colored $border $Color
    Write-Colored "" $Color
}

function Invoke-Native {
    <#
        PowerShell treats a native executable's non-zero exit code as a normal result, not
        an error. Without this wrapper a failed apply would be followed by "Done" and a
        zero exit code, which is how a broken deploy gets reported as green.
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

function Invoke-NativeCapture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int[]]$AllowedExitCodes = @(0),
        [string]$ErrorMessage
    )
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

function Read-TypedConfirmation {
    param(
        [Parameter(Mandatory)][string]$Expected,
        [string]$Prompt = 'Type the confirmation string'
    )
    if (-not [Environment]::UserInteractive) {
        throw "An interactive confirmation ('$Expected') is required and this host is non-interactive. There is no flag that bypasses it - that is the point."
    }
    $answer = Read-Host $Prompt
    # -cne: case-SENSITIVE comparison. 'YES' is not 'yes'.
    return ($answer -ceq $Expected)
}

# ---------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------

Write-Colored "" ([System.ConsoleColor]::White)
Write-Colored "  terraform-azure-aks-platform :: apply-env [$Environment]" ([System.ConsoleColor]::White)
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
    throw "Missing '$backendFile'. Run: .\scripts\init-env.ps1 $Environment  (it explains how to create it)."
}

# -- cost warning -----------------------------------------------------------------------
Write-Banner -Color ([System.ConsoleColor]::Yellow) -Lines @(
    "COST WARNING - APPLYING TO '$($Environment.ToUpperInvariant())'",
    '',
    'This creates and/or modifies real Azure resources that are billed by the hour:',
    '  * AKS cluster + node pools (VMs, managed disks, public IPs)',
    '  * Log Analytics workspace (ingestion + retention)',
    '  * Azure Container Registry, Key Vault, networking',
    '',
    'Nothing here is covered by a free tier at a meaningful scale. An idle dev cluster',
    'left running over a weekend is a real, recurring charge on a real credit card.',
    '',
    'Estimate first:  .\scripts\cost-estimate.ps1 ' + $Environment
)

# -- production guard -------------------------------------------------------------------
if ($Environment -eq 'prod') {
    Write-Banner -Color ([System.ConsoleColor]::Red) -Lines @(
        'PRODUCTION APPLY - BREAK-GLASS ONLY',
        '',
        'The sanctioned path to prod is the GitHub Actions workflow, gated by a GitHub',
        'Environment with required reviewers. That gives you an approval record, a',
        'scoped OIDC identity and a reproducible log. A laptop gives you none of those.',
        '',
        'Use this script only when the pipeline itself is unavailable and someone has',
        'consciously accepted the risk. Write it up afterwards.'
    )

    if (-not $Force) {
        Write-Err 'Refusing to apply to prod without -Force.'
        Write-Info 'Sanctioned path:'
        Write-Info '    gh workflow run terraform-apply.yml -f environment=prod'
        Write-Info '    (then approve the deployment in the GitHub Environment)'
        Write-Info ''
        Write-Info 'Break-glass path:'
        Write-Info '    .\scripts\apply-env.ps1 prod -Force     (you will also have to type apply-prod)'
        exit 1
    }

    Write-Warn 'Second gate: type the confirmation string EXACTLY (case-sensitive).'
    if (-not (Read-TypedConfirmation -Expected 'apply-prod' -Prompt "Type 'apply-prod' to proceed")) {
        Write-Err 'Confirmation did not match. Nothing was applied.'
        exit 1
    }
    Write-Warn 'Break-glass confirmation accepted. Proceeding with the production apply.'
}

# -- init if cold -----------------------------------------------------------------------
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
            Write-Info "ARM_SUBSCRIPTION_ID: $env:ARM_SUBSCRIPTION_ID"
        }
    }
}

$outputsText = ''

try {
    Push-Location -LiteralPath $EnvDir

    $planPath   = Join-Path $EnvDir $PlanFile
    $hasPlan    = Test-Path -LiteralPath $planPath -PathType Leaf
    $applyArgs  = @('apply', '-input=false', '-lock-timeout=5m')

    if ($hasPlan) {
        $age = (Get-Date) - (Get-Item -LiteralPath $planPath).LastWriteTime
        Write-Step "Using saved plan: $PlanFile  (created $([int]$age.TotalMinutes) minute(s) ago)"
        Write-Info 'Terraform will refuse this plan if the configuration or state has changed since'
        Write-Info 'it was produced. That is a feature - re-plan rather than fighting it.'

        if ($age.TotalHours -gt 1) {
            Write-Warn "This plan is $([int]$age.TotalHours) hour(s) old. Consider re-running plan-env.ps1 first."
        }

        # A saved plan already encodes the approval - `terraform apply <planfile>` does not
        # prompt, and -auto-approve is rejected when a plan file is supplied.
        $applyArgs += $PlanFile
    } else {
        Write-Step "No saved plan at '$planPath' - planning now"
        Invoke-Native -FilePath $terraform -Arguments @('plan', '-input=false', '-lock-timeout=5m', "-out=$PlanFile") `
            -ErrorMessage "terraform plan failed for '$Environment'."
        $applyArgs += $PlanFile
        $hasPlan = $true
    }

    # -- confirmation (prod already did its own, stricter, gate) ------------------------
    if ($Environment -ne 'prod') {
        if ($Force) {
            Write-Warn '-Force supplied: applying without a confirmation prompt.'
        } else {
            if (-not [Environment]::UserInteractive) {
                throw "A confirmation is required and this host is non-interactive. Pass -Force once you have reviewed the plan."
            }
            Write-Colored "" ([System.ConsoleColor]::Yellow)
            Write-Colored "About to APPLY the plan above to '$Environment'. This creates billable resources." ([System.ConsoleColor]::Yellow)
            $answer = Read-Host "Type 'yes' to continue"
            if ($answer -cne 'yes') {
                Write-Err "Aborted - you typed '$answer'. Nothing was applied."
                Write-Info "The plan file is still at $planPath if you want to apply it later."
                exit 1
            }
        }
    }

    # -- apply --------------------------------------------------------------------------
    Write-Step ("terraform " + ($applyArgs -join ' '))
    Write-Info 'An AKS apply typically takes 8-15 minutes. Do not interrupt it: a Ctrl+C mid-apply'
    Write-Info 'leaves the state lease held and resources half-created.'

    Invoke-Native -FilePath $terraform -Arguments $applyArgs -ErrorMessage @"
terraform apply FAILED for '$Environment'.

The state may now describe a partially-created environment. Do NOT panic and do NOT
delete resources by hand in the portal - that desynchronises state.

Recovery:
  1. Read the error. Quota and SKU-availability errors are the most common.
  2. Re-run:  .\scripts\plan-env.ps1 $Environment      (Terraform is idempotent; it will
     plan only what is still missing)
  3. If the state lease is stuck (a previous run was killed):
        terraform force-unlock <LOCK_ID>      # last resort, only when you are certain
                                              # no other apply is running
"@

    Write-Ok 'Apply completed successfully.'

    # The plan has been consumed. Leaving it on disk invites someone to apply a stale
    # snapshot later; Terraform would reject it, but the confusion is avoidable.
    if (-not $KeepPlanFile -and (Test-Path -LiteralPath $planPath -PathType Leaf)) {
        Remove-Item -LiteralPath $planPath -Force -ErrorAction SilentlyContinue
        Write-Info "Consumed plan file removed: $PlanFile"
    }

    # -- outputs ------------------------------------------------------------------------
    Write-Step 'Outputs'
    $outputsJson = Invoke-NativeCapture -FilePath $terraform -Arguments @('output', '-json') `
        -AllowedExitCodes @(0, 1) -ErrorMessage 'terraform output -json failed.'

    $outputs = $null
    if (-not [string]::IsNullOrWhiteSpace($outputsJson)) {
        try { $outputs = $outputsJson | ConvertFrom-Json } catch { $outputs = $null }
    }

    if ($null -eq $outputs) {
        Write-Warn ("Could not read outputs. Run 'terraform output' inside envs/{0} manually." -f $Environment)
    } else {
        $names = @($outputs.PSObject.Properties.Name)
        if ($names.Count -eq 0) {
            Write-Info 'This environment declares no outputs.'
        } else {
            $width = 0
            foreach ($name in $names) { if ($name.Length -gt $width) { $width = $name.Length } }
            foreach ($name in $names) {
                $entry = $outputs.$name
                $isSensitive = $false
                if ($entry.PSObject.Properties.Name -contains 'sensitive') { $isSensitive = [bool]$entry.sensitive }
                if ($isSensitive) {
                    # Never echo a sensitive output into a terminal buffer / CI log.
                    Write-Colored ("    {0}  <sensitive - reveal with: terraform output {1}>" -f $name.PadRight($width), $name) ([System.ConsoleColor]::DarkYellow)
                } else {
                    $value = ''
                    if ($entry.PSObject.Properties.Name -contains 'value') { $value = [string]$entry.value }
                    Write-Colored ("    {0}  {1}" -f $name.PadRight($width), $value) ([System.ConsoleColor]::Green)
                }
            }
        }
    }
}
finally {
    Pop-Location
}

# -- closing ----------------------------------------------------------------------------
Write-Step 'Next steps'
Write-Info "Connect kubectl to the cluster:   .\scripts\connect-aks.ps1 $Environment"
Write-Info "Check what it costs:              .\scripts\cost-estimate.ps1 $Environment"

if ($Environment -eq 'dev') {
    Write-Banner -Color ([System.ConsoleColor]::Yellow) -Lines @(
        'TEARDOWN REMINDER - dev is not free',
        '',
        'When you are finished for the day, destroy it:',
        '',
        '  .\scripts\plan-env.ps1 dev -Destroy -Out tfplan.destroy    # review first',
        '  terraform -chdir=envs\dev destroy                          # then tear down',
        '',
        'The remote state backend and the bootstrap stack survive a destroy, so you can',
        'rebuild dev from scratch in one apply tomorrow.'
    )
} else {
    Write-Warn "Remember that '$Environment' keeps billing until it is destroyed."
}

exit 0

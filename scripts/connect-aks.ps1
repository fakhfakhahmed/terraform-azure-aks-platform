#Requires -Version 5.1
<#
.SYNOPSIS
    Points kubectl at the AKS cluster for one environment and verifies the connection.

.DESCRIPTION
    Fetches the cluster name and resource group from the environment's Terraform outputs
    (aks_cluster_name, resource_group_name), downloads credentials, converts the
    kubeconfig for Entra ID auth, and then proves the connection actually works.

    WHY kubelogin IS NOT OPTIONAL HERE
    -----------------------------------------------------------------------------------
    These clusters are Entra ID (Azure AD) integrated with Azure RBAC for Kubernetes
    authorization, and local accounts are disabled - there is no cluster-admin kubeconfig
    with a static certificate to fall back on. `az aks get-credentials` writes a kubeconfig
    whose user block uses an exec credential plugin named "kubelogin". If that binary is
    not on PATH, every single kubectl command fails with something like:

        Unable to connect to the server: getting credentials: exec: executable kubelogin not found

    `kubelogin convert-kubeconfig -l azurecli` rewrites the kubeconfig to reuse the token
    already cached by the Azure CLI, which is the right mode for an interactive operator.
    Other useful modes: -l devicecode (headless/SSH), -l workloadidentity (in-cluster CI),
    -l spn (service principal, discouraged).

    AUTHORIZATION vs AUTHENTICATION
    Getting a kubeconfig proves nothing about your permissions. With Azure RBAC enabled,
    your Entra identity needs an Azure role such as "Azure Kubernetes Service RBAC Reader"
    or "... Cluster Admin" scoped to the cluster. A successful login followed by
    "forbidden" on `kubectl get nodes` means the role assignment is missing, not that the
    connection is broken. The script distinguishes these two cases for you.

    PRIVATE CLUSTERS
    prod runs with a private API server. From outside the VNet, DNS for the API server
    FQDN resolves to a private IP you cannot reach, so kubectl hangs and then fails with
    "dial tcp ... i/o timeout" or "no such host". The script detects this and prints the
    four legitimate ways in.

.PARAMETER Environment
    dev, staging or prod. Positional.

.PARAMETER ClusterName
    Override the cluster name instead of reading it from Terraform outputs. Useful when
    the environment is not initialised locally or you are helping someone else debug.

.PARAMETER ResourceGroup
    Override the resource group. Must be supplied together with -ClusterName.

.PARAMETER Admin
    Use `az aks get-credentials --admin`. This only works when local accounts are ENABLED,
    which they are not on these clusters - it is here so the failure message is explicit
    rather than mysterious.

.PARAMETER SkipVerify
    Fetch and convert the kubeconfig but skip the kubectl verification steps.

.EXAMPLE
    PS> .\scripts\connect-aks.ps1 dev
    Resolve dev's cluster from Terraform outputs, log in, verify.

.EXAMPLE
    PS> .\scripts\connect-aks.ps1 prod -ClusterName aks-prod-weu -ResourceGroup rg-aks-prod-weu
    Connect without needing the prod environment initialised locally.

.NOTES
    Author : Ahmed Fakhfakh
    Repo   : https://github.com/fakhfakhahmed/terraform-azure-aks-platform
    This script is read-only with respect to Azure: it changes your local kubeconfig
    (~/.kube/config) and nothing else. No cost.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('dev', 'staging', 'prod')]
    [string]$Environment,

    [string]$ClusterName,
    [string]$ResourceGroup,
    [switch]$Admin,
    [switch]$SkipVerify
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
    # See the long comment in apply-env.ps1: PowerShell does not fail on a native
    # executable's non-zero exit code, so every external call is checked explicitly.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int[]]$AllowedExitCodes = @(0),
        [string]$ErrorMessage
    )
    Write-Verbose ("exec: {0} {1}" -f $FilePath, ($Arguments -join ' '))
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

function Invoke-NativeSoft {
    <#
        Runs a command, captures stdout+stderr and returns a result object WITHOUT
        throwing. Used for the verification steps, where a failure is information to be
        interpreted (private cluster? missing RBAC?) rather than a reason to abort.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @()
    )
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & $FilePath @Arguments 2>&1
        $code = $global:LASTEXITCODE
    } catch {
        $raw = $_.Exception.Message
        $code = 1
    } finally {
        $ErrorActionPreference = $previous
    }
    $text = ''
    if ($null -ne $raw) { $text = (($raw | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) }
    return [pscustomobject]@{ ExitCode = $code; Output = $text }
}

function Get-CommandPath {
    param([Parameter(Mandatory)][string]$Name)
    $cmd = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $cmd) { return $null }
    if ($cmd -is [System.Array]) { return $cmd[0].Source }
    return $cmd.Source
}

function Get-TfOutputValue {
    param([Parameter(Mandatory)][object]$Outputs, [Parameter(Mandatory)][string]$Name)
    if ($Outputs.PSObject.Properties.Name -contains $Name) {
        $entry = $Outputs.$Name
        if ($entry.PSObject.Properties.Name -contains 'value') { return [string]$entry.value }
    }
    return ''
}

function Show-PrivateClusterGuidance {
    param([string]$Cluster, [string]$Group)
    Write-Colored "" ([System.ConsoleColor]::Yellow)
    Write-Colored "    ----------------------------------------------------------------------" ([System.ConsoleColor]::Yellow)
    Write-Colored "    THE API SERVER IS NOT REACHABLE FROM THIS NETWORK" ([System.ConsoleColor]::Yellow)
    Write-Colored "    ----------------------------------------------------------------------" ([System.ConsoleColor]::Yellow)
    Write-Info 'This cluster has a private API server. Its FQDN resolves to a private IP inside'
    Write-Info 'the cluster VNet, so kubectl from a laptop on the public internet cannot reach it.'
    Write-Info 'This is working as designed - it is not a broken kubeconfig.'
    Write-Colored "" ([System.ConsoleColor]::Gray)
    Write-Info 'Four legitimate ways in, roughly in order of convenience:'
    Write-Colored "" ([System.ConsoleColor]::Gray)
    Write-Info '  1. az aks command invoke - runs a command in a managed pod inside the cluster.'
    Write-Info '     No network access required; needs the "Azure Kubernetes Service Cluster'
    Write-Info '     User" role plus Microsoft.ContainerService/managedClusters/runcommand/action.'
    Write-Info ''
    Write-Info "       az aks command invoke --resource-group $Group --name $Cluster \"
    Write-Info '         --command "kubectl get nodes -o wide"'
    Write-Info ''
    Write-Info '  2. A jumpbox/bastion VM inside the cluster VNet (or a peered one). Use Azure'
    Write-Info '     Bastion rather than exposing SSH/RDP to the internet.'
    Write-Info ''
    Write-Info '  3. A VPN gateway or ExpressRoute circuit into the VNet, with the private DNS'
    Write-Info '     zone (privatelink.<region>.azmk8s.io) linked to the network you dial in from.'
    Write-Info '     Forgetting the DNS zone link is the usual cause of "no such host" over VPN.'
    Write-Info ''
    Write-Info '  4. A Private Endpoint for the cluster in a hub VNet your workstation can route'
    Write-Info '     to, again with the private DNS zone linked.'
    Write-Colored "" ([System.ConsoleColor]::Gray)
    Write-Info 'Check whether the cluster really is private:'
    Write-Info "    az aks show -g $Group -n $Cluster --query apiServerAccessProfile -o json"
    Write-Colored "    ----------------------------------------------------------------------" ([System.ConsoleColor]::Yellow)
}

# ---------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------

Write-Colored "" ([System.ConsoleColor]::White)
Write-Colored "  terraform-azure-aks-platform :: connect-aks [$Environment]" ([System.ConsoleColor]::White)
Write-Colored "  repo root: $RepoRoot" ([System.ConsoleColor]::DarkGray)

$az      = Get-CommandPath -Name 'az'
$kubectl = Get-CommandPath -Name 'kubectl'
if ($null -eq $az)      { throw "az was not found on PATH. Install: winget install Microsoft.AzureCLI" }
if ($null -eq $kubectl) { throw "kubectl was not found on PATH. Install: az aks install-cli" }

if ($ClusterName -and -not $ResourceGroup) { throw '-ClusterName requires -ResourceGroup (and vice versa).' }
if ($ResourceGroup -and -not $ClusterName) { throw '-ResourceGroup requires -ClusterName (and vice versa).' }

# -- resolve the cluster ----------------------------------------------------------------
if (-not $ClusterName) {
    Write-Step 'Resolving the cluster from Terraform outputs'

    if (-not (Test-Path -LiteralPath $EnvDir -PathType Container)) {
        throw "Environment directory '$EnvDir' does not exist, and no -ClusterName/-ResourceGroup were supplied."
    }

    $terraform = Get-CommandPath -Name 'terraform'
    if ($null -eq $terraform) {
        throw "terraform was not found on PATH, so the cluster name cannot be resolved. Pass -ClusterName and -ResourceGroup explicitly."
    }

    $outputsJson = ''
    try {
        Push-Location -LiteralPath $EnvDir
        $result = Invoke-NativeSoft -FilePath $terraform -Arguments @('output', '-json')
        if ($result.ExitCode -ne 0) {
            Write-Err 'terraform output -json failed.'
            Write-Info 'Most likely this environment is not initialised on this machine.'
            Write-Info "Fix:   .\scripts\init-env.ps1 $Environment"
            Write-Info 'Or bypass Terraform entirely:'
            Write-Info "       .\scripts\connect-aks.ps1 $Environment -ClusterName <name> -ResourceGroup <rg>"
            Write-Info ''
            Write-Info ('terraform said: ' + $result.Output.Trim())
            exit 1
        }
        $outputsJson = $result.Output
    } finally {
        Pop-Location
    }

    $outputs = $null
    try { $outputs = $outputsJson | ConvertFrom-Json } catch { $outputs = $null }
    if ($null -eq $outputs) { throw "Could not parse the Terraform outputs for '$Environment'." }

    $ClusterName   = Get-TfOutputValue -Outputs $outputs -Name 'aks_cluster_name'
    $ResourceGroup = Get-TfOutputValue -Outputs $outputs -Name 'resource_group_name'

    if (-not $ClusterName -or -not $ResourceGroup) {
        throw "Outputs 'aks_cluster_name' and/or 'resource_group_name' are missing or empty for '$Environment'. Has it been applied yet? (.\scripts\apply-env.ps1 $Environment). Alternatively pass -ClusterName and -ResourceGroup."
    }
} else {
    Write-Step 'Using the cluster supplied on the command line'
}

Write-Ok "cluster        : $ClusterName"
Write-Ok "resource group : $ResourceGroup"

# -- is it private? ---------------------------------------------------------------------
# Asking up front sets expectations before kubectl hangs for 30 seconds.
$isPrivate = $false
$privateProbe = Invoke-NativeSoft -FilePath $az -Arguments @(
    'aks', 'show', '--resource-group', $ResourceGroup, '--name', $ClusterName,
    '--query', 'apiServerAccessProfile.enablePrivateCluster', '--output', 'tsv'
)
if ($privateProbe.ExitCode -eq 0) {
    if ($privateProbe.Output.Trim() -match '^(?i)true$') {
        $isPrivate = $true
        Write-Warn 'This is a PRIVATE cluster - the API server has no public endpoint.'
    } else {
        Write-Ok 'public API server endpoint (authorized IP ranges may still apply)'
    }
} else {
    Write-Warn 'Could not query the cluster with az aks show. Continuing anyway.'
    Write-Info ('az said: ' + $privateProbe.Output.Trim())
}

# -- credentials ------------------------------------------------------------------------
Write-Step 'az aks get-credentials'

$credArgs = @('aks', 'get-credentials', '--resource-group', $ResourceGroup, '--name', $ClusterName, '--overwrite-existing')
if ($Admin) {
    Write-Warn '-Admin requested. These clusters set local_account_disabled = true, so admin'
    Write-Warn 'credentials are expected to be refused. Use Entra ID + Azure RBAC instead.'
    $credArgs += '--admin'
}

# --overwrite-existing avoids the "A different object named X already exists in your
# kubeconfig" error that otherwise appears every time a cluster is recreated.
Invoke-Native -FilePath $az -Arguments $credArgs -ErrorMessage @"
az aks get-credentials failed.

Common causes:
  * Not logged in / wrong subscription -> az login; az account set --subscription <id>
  * Missing the 'Azure Kubernetes Service Cluster User' role on the cluster
  * The cluster does not exist (wrong environment, or not applied yet)
  * -Admin on a cluster with local accounts disabled (expected; drop -Admin)
"@
Write-Ok 'kubeconfig updated'

# -- kubelogin ---------------------------------------------------------------------------
Write-Step 'kubelogin convert-kubeconfig -l azurecli'

$kubelogin = Get-CommandPath -Name 'kubelogin'
if ($null -eq $kubelogin) {
    Write-Err 'kubelogin is NOT installed - and these clusters cannot be used without it.'
    Write-Info 'The kubeconfig just written uses an exec credential plugin called "kubelogin".'
    Write-Info 'Until it is on PATH, every kubectl command will fail with:'
    Write-Info '    exec: executable kubelogin not found'
    Write-Info ''
    Write-Info 'Install one of:'
    Write-Info '    az aks install-cli                                  (installs kubectl + kubelogin)'
    Write-Info '    winget install Microsoft.Azure.Kubelogin'
    Write-Info '    brew install Azure/kubelogin/kubelogin'
    Write-Info ''
    Write-Info 'Then re-run this script.'
    exit 1
}

# -l azurecli reuses the token the Azure CLI already holds - no second interactive login,
# and no device-code dance. On a headless host use: kubelogin convert-kubeconfig -l devicecode
Invoke-Native -FilePath $kubelogin -Arguments @('convert-kubeconfig', '-l', 'azurecli') `
    -ErrorMessage 'kubelogin convert-kubeconfig failed. Is your az login still valid? Try: az account get-access-token'
Write-Ok 'kubeconfig converted for Entra ID (azurecli) authentication'

if ($SkipVerify) {
    Write-Step 'Verification skipped (-SkipVerify)'
    exit 0
}

# -- verification -------------------------------------------------------------------------
Write-Step 'kubectl config current-context'
$context = Invoke-NativeSoft -FilePath $kubectl -Arguments @('config', 'current-context')
if ($context.ExitCode -ne 0) {
    throw "kubectl could not read the current context. Is KUBECONFIG pointing somewhere unexpected? (KUBECONFIG=$env:KUBECONFIG)"
}
Write-Ok $context.Output.Trim()

Write-Step 'kubectl get nodes -o wide'
$nodes = Invoke-NativeSoft -FilePath $kubectl -Arguments @('get', 'nodes', '-o', 'wide')

if ($nodes.ExitCode -eq 0) {
    Write-Host $nodes.Output
    Write-Ok 'API server reachable and the request was authorized.'
} else {
    $text = $nodes.Output

    # Distinguish "cannot reach the API server" from "reached it and was refused".
    $unreachable = ($text -match 'i/o timeout') -or
                   ($text -match 'dial tcp') -or
                   ($text -match 'no such host') -or
                   ($text -match 'connection refused') -or
                   ($text -match 'context deadline exceeded') -or
                   ($text -match 'Unable to connect to the server')

    $forbidden = ($text -match '(?i)forbidden') -or ($text -match '(?i)cannot list resource')

    Write-Err 'kubectl get nodes failed.'
    Write-Info $text.Trim()

    if ($forbidden) {
        Write-Colored "" ([System.ConsoleColor]::Yellow)
        Write-Warn 'You reached the API server but Azure RBAC refused the request.'
        Write-Warn 'Authentication worked; AUTHORIZATION did not. You need an Azure role on the cluster:'
        Write-Info ''
        Write-Info '    az role assignment create \'
        Write-Info '      --assignee "$(az ad signed-in-user show --query id -o tsv)" \'
        Write-Info '      --role "Azure Kubernetes Service RBAC Cluster Admin" \'
        Write-Info "      --scope `"`$(az aks show -g $ResourceGroup -n $ClusterName --query id -o tsv)`""
        Write-Info ''
        Write-Info 'Role assignments can take a couple of minutes to propagate.'
    } elseif ($unreachable) {
        if ($isPrivate) {
            Show-PrivateClusterGuidance -Cluster $ClusterName -Group $ResourceGroup
        } else {
            Write-Colored "" ([System.ConsoleColor]::Yellow)
            Write-Warn 'The API server is public but still unreachable. The usual cause is an'
            Write-Warn 'authorized IP range that does not include your current egress address.'
            Write-Info ''
            Write-Info '    Current public IP:  (curl https://ifconfig.me)'
            Write-Info "    Allowed ranges   :  az aks show -g $ResourceGroup -n $ClusterName --query apiServerAccessProfile.authorizedIpRanges -o json"
            Write-Info ''
            Write-Info 'If you are on a VPN or a corporate proxy, your egress IP is not what you think.'
            Show-PrivateClusterGuidance -Cluster $ClusterName -Group $ResourceGroup
        }
    } else {
        Write-Warn 'Unrecognised failure. Re-run with: kubectl get nodes -v=6   for verbose transport logs.'
    }
    exit 1
}

Write-Step 'kubectl get pods -A'
$pods = Invoke-NativeSoft -FilePath $kubectl -Arguments @('get', 'pods', '-A')
if ($pods.ExitCode -eq 0) {
    Write-Host $pods.Output
} else {
    Write-Warn 'Could not list pods across all namespaces (an RBAC scope issue, most likely).'
    Write-Info $pods.Output.Trim()
}

# -- platform add-on sanity checks --------------------------------------------------------
# These two are what make the platform's security story work:
#   * workload identity webhook  -> projects federated tokens into pods (no secrets)
#   * secrets-store CSI + azure  -> mounts Key Vault secrets as files (no secrets in etcd)
# If either is missing, applications that rely on them fail in confusing ways at runtime,
# so it is worth 2 seconds to confirm now.
Write-Step 'Platform add-on checks'

$addons = @(
    [pscustomobject]@{
        Label    = 'workload identity webhook'
        Selector = 'app=azure-wi-webhook-controller-manager'
        Why      = 'Required for Entra Workload Identity. Enable with oidc_issuer_enabled + workload_identity_enabled on the cluster.'
    },
    [pscustomobject]@{
        Label    = 'secrets-store CSI driver'
        Selector = 'app=secrets-store-csi-driver'
        Why      = 'Required to mount Key Vault secrets as volumes. Enable the key_vault_secrets_provider add-on.'
    },
    [pscustomobject]@{
        Label    = 'secrets-store azure provider'
        Selector = 'app=csi-secrets-store-provider-azure'
        Why      = 'The Azure provider for the CSI driver. Ships with the key_vault_secrets_provider add-on.'
    }
)

foreach ($addon in $addons) {
    $probe = Invoke-NativeSoft -FilePath $kubectl -Arguments @(
        'get', 'pods', '-n', 'kube-system', '-l', $addon.Selector, '--no-headers'
    )
    $found = $false
    if ($probe.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($probe.Output)) {
        if ($probe.Output -notmatch 'No resources found') { $found = $true }
    }

    if ($found) {
        $running = @($probe.Output -split "`r?`n" | Where-Object { $_ -match '\S' -and $_ -match 'Running' }).Count
        $total   = @($probe.Output -split "`r?`n" | Where-Object { $_ -match '\S' }).Count
        if ($running -eq $total) {
            Write-Ok ("{0}: {1}/{2} pods Running" -f $addon.Label, $running, $total)
        } else {
            Write-Warn ("{0}: only {1}/{2} pods Running" -f $addon.Label, $running, $total)
            Write-Info ("    kubectl -n kube-system get pods -l {0}" -f $addon.Selector)
        }
    } else {
        Write-Warn ("{0}: not found" -f $addon.Label)
        Write-Info ("    " + $addon.Why)
    }
}

Write-Step 'Connected'
Write-Ok "kubectl is now pointed at '$ClusterName' ($Environment)."
Write-Info 'Switch back later with:  kubectl config use-context <context>'
Write-Info "Remove this context when done:  kubectl config delete-context $ClusterName"
exit 0

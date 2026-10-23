# Getting started

Zero to a working AKS cluster with Workload Identity, and back to zero again.

> ⚠️ **This guide creates billable Azure resources.** The dev environment costs roughly
> **€190/month** if you leave it running 24/7. Most of that is VM node hours and Log Analytics
> ingestion, neither of which is covered by a free tier. Read [cost.md](./cost.md) before you
> run `apply`, and read [Step 12 — tear it down](#step-12--tear-it-down) before you walk away.
> The AKS *control plane* is free on the `Free` SKU tier. Everything attached to it is not.

PowerShell commands come first because the repository is developed on Windows. Bash equivalents
follow every step. The two sets are functionally identical.

**Contents**

- [Prerequisites](#prerequisites)
- [Step 1 — install the toolchain](#step-1--install-the-toolchain)
- [Step 2 — sign in and select a subscription](#step-2--sign-in-and-select-a-subscription)
- [Step 3 — register resource providers](#step-3--register-resource-providers)
- [Step 4 — run preflight](#step-4--run-preflight)
- [Step 5 — bootstrap the backend and OIDC identity](#step-5--bootstrap-the-backend-and-oidc-identity)
- [Step 6 — wire up GitHub](#step-6--wire-up-github)
- [Step 7 — configure GitHub Environments](#step-7--configure-github-environments)
- [Step 8 — create the backend config for dev](#step-8--create-the-backend-config-for-dev)
- [Step 9 — init, plan, apply](#step-9--init-plan-apply)
- [Step 10 — connect to the cluster](#step-10--connect-to-the-cluster)
- [Step 11 — deploy the sample workload and verify Workload Identity](#step-11--deploy-the-sample-workload-and-verify-workload-identity)
- [Step 12 — tear it down](#step-12--tear-it-down)
- [Timings](#timings)
- [Troubleshooting](#troubleshooting)

---

## Prerequisites

| Requirement | Why |
|---|---|
| An Azure subscription where you hold **Owner**, or **Contributor + User Access Administrator** | The bootstrap stack creates role assignments; Contributor alone cannot do that |
| Permission to create an **Entra ID application registration** | Either the `Application Developer` role, or a tenant that allows user app registration |
| A GitHub account and a fork or copy of this repository | The federated credential subjects are pinned to a repository path |
| Windows 10/11 with PowerShell 5.1+ (or PowerShell 7), **or** any Linux/macOS shell | |
| Roughly €10 of budget if you are following along for a day and then destroying | See [cost.md](./cost.md) |

Check your subscription role before you start — this is the single most common reason the
bootstrap fails halfway through:

```powershell
az role assignment list --assignee (az ad signed-in-user show --query id -o tsv) `
  --scope "/subscriptions/$(az account show --query id -o tsv)" `
  --query "[].roleDefinitionName" -o tsv
```

```bash
az role assignment list --assignee "$(az ad signed-in-user show --query id -o tsv)" \
  --scope "/subscriptions/$(az account show --query id -o tsv)" \
  --query "[].roleDefinitionName" -o tsv
```

You want to see `Owner`, or both `Contributor` and `User Access Administrator`.

---

## Step 1 — install the toolchain

| Tool | Minimum version | Used for |
|---|---|---|
| Terraform | `>= 1.9` | Everything. `removed {}` blocks need 1.7+, and the provider constraints assume 1.9 |
| Azure CLI | `>= 2.61` | Sign-in, provider registration, break-glass operations |
| kubectl | `>= 1.29` | Talking to the cluster |
| kubelogin | `>= 0.1.3` | **Mandatory.** Azure RBAC + `local_account_disabled` means plain `kubectl` cannot authenticate |
| GitHub CLI (`gh`) | `>= 2.40` | Setting repository variables and environments |
| jq | any | Several scripts parse `terraform output -json` |

### Windows (winget)

```powershell
winget install --id Hashicorp.Terraform --source winget
winget install --id Microsoft.AzureCLI --source winget
winget install --id Kubernetes.kubectl --source winget
winget install --id Microsoft.Azure.Kubelogin --source winget
winget install --id GitHub.cli --source winget
winget install --id jqlang.jq --source winget
```

### Windows (Chocolatey)

```powershell
choco install terraform azure-cli kubernetes-cli kubelogin gh jq -y
```

### Linux / macOS

```bash
# macOS
brew install terraform azure-cli kubectl Azure/kubelogin/kubelogin gh jq

# Debian / Ubuntu — Terraform and the Azure CLI come from their own repos
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install -y terraform jq
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
sudo az aks install-cli   # installs both kubectl and kubelogin
```

Verify:

```powershell
terraform version; az version --query '"azure-cli"'; kubectl version --client ; kubelogin --version; gh --version
```

```bash
terraform version && az version --query '"azure-cli"' && kubectl version --client && kubelogin --version && gh --version
```

**Cost: €0.**

---

## Step 2 — sign in and select a subscription

```powershell
az login
az account list --output table
az account set --subscription "<your-subscription-name-or-id>"

# Confirm, and capture the IDs you will need later.
$SUBSCRIPTION_ID = az account show --query id -o tsv
$TENANT_ID       = az account show --query tenantId -o tsv
Write-Host "Subscription: $SUBSCRIPTION_ID"
Write-Host "Tenant:       $TENANT_ID"
```

```bash
az login
az account list --output table
az account set --subscription "<your-subscription-name-or-id>"

export SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
export TENANT_ID="$(az account show --query tenantId -o tsv)"
echo "Subscription: ${SUBSCRIPTION_ID}"
echo "Tenant:       ${TENANT_ID}"
```

> The `azurerm` v4 provider **requires** `subscription_id` in the provider block or the
> `ARM_SUBSCRIPTION_ID` environment variable. This is a breaking change from v3, where the
> provider silently inherited the CLI's active subscription. If you skip this you will get
> `Error: subscription_id is required` at `terraform plan` time. Set it now:

```powershell
$env:ARM_SUBSCRIPTION_ID = $SUBSCRIPTION_ID
```

```bash
export ARM_SUBSCRIPTION_ID="${SUBSCRIPTION_ID}"
```

**Cost: €0.**

---

## Step 3 — register resource providers

A fresh subscription has most providers unregistered. Terraform will fail with
`MissingSubscriptionRegistration` partway through an apply, which is a slow and annoying way to
discover this. The `azurerm` provider has `resource_provider_registrations = "none"` set
deliberately — automatic registration hides failures and needs subscription-level write access
that a scoped CI principal should not have.

```powershell
$providers = @(
  'Microsoft.ContainerService',
  'Microsoft.ContainerRegistry',
  'Microsoft.KeyVault',
  'Microsoft.OperationalInsights',
  'Microsoft.Network',
  'Microsoft.ManagedIdentity',
  'Microsoft.Insights'
)
foreach ($p in $providers) { az provider register --namespace $p }

# Registration is asynchronous. Poll until every provider reports Registered.
foreach ($p in $providers) {
  $state = az provider show --namespace $p --query registrationState -o tsv
  Write-Host ("{0,-35} {1}" -f $p, $state)
}
```

```bash
providers=(
  Microsoft.ContainerService
  Microsoft.ContainerRegistry
  Microsoft.KeyVault
  Microsoft.OperationalInsights
  Microsoft.Network
  Microsoft.ManagedIdentity
  Microsoft.Insights
)
for p in "${providers[@]}"; do az provider register --namespace "$p"; done
for p in "${providers[@]}"; do
  printf '%-35s %s\n' "$p" "$(az provider show --namespace "$p" --query registrationState -o tsv)"
done
```

Registration typically takes **1–3 minutes** per provider, and they run in parallel. Re-run the
status loop until everything says `Registered`. Do not continue while any provider is
`Registering`.

**Cost: €0.**

---

## Step 4 — run preflight

[`scripts/preflight.ps1`](../scripts/preflight.ps1) checks everything above in one pass so you
find problems before Terraform does: tool versions, an active `az` login, the signed-in
principal's roles, provider registration state, regional quota for the VM families used by the
node pools, and whether the Key Vault name you are about to use is sitting in a soft-deleted
state from a previous run.

```powershell
.\scripts\preflight.ps1 -Environment dev
```

```bash
./scripts/preflight.sh dev
```

Expected output ends with `PREFLIGHT OK`. Anything else is actionable and the script tells you
what to do.

The quota check matters more than it looks. A default subscription often has a regional vCPU
quota of 10 for the `Standard DSv5 Family`. The prod environment wants 3 × `Standard_D4s_v5` in
the system pool and up to 10 in the user pool — that is 52 vCPUs. You will hit
`QuotaExceeded` during apply, after the VNet and Key Vault have already been created, leaving
you with a half-built environment. Request the quota increase first.

**Cost: €0.**

---

## Step 5 — bootstrap the backend and OIDC identity

This is the chicken-and-egg step. The backend that stores Terraform state cannot itself be
stored in that backend, so [`bootstrap/`](../bootstrap/) runs with **local state**.

It creates:

1. a resource group for shared platform state;
2. a storage account with versioning, blob soft delete and `shared_access_key_enabled = false`;
3. a `tfstate` blob container;
4. an Entra ID application registration + service principal for GitHub Actions;
5. five federated identity credentials (main branch, pull_request, and one per environment);
6. role assignments for the CI principal: `Contributor` and `User Access Administrator` at
   subscription scope, and `Storage Blob Data Contributor` on the state container.

```powershell
.\scripts\bootstrap-backend.ps1 `
  -Location "westeurope" `
  -GitHubOrg "fakhfakhahmed" `
  -GitHubRepo "terraform-azure-aks-platform"
```

```bash
./scripts/bootstrap-backend.sh \
  --location westeurope \
  --github-org fakhfakhahmed \
  --github-repo terraform-azure-aks-platform
```

The script is a thin wrapper around:

```powershell
Push-Location .\bootstrap
terraform init
terraform plan  -out=tfplan -var="location=westeurope" -var="github_org=fakhfakhahmed" -var="github_repo=terraform-azure-aks-platform"
terraform apply tfplan
Pop-Location
```

```bash
cd bootstrap
terraform init
terraform plan  -out=tfplan -var="location=westeurope" -var="github_org=fakhfakhahmed" -var="github_repo=terraform-azure-aks-platform"
terraform apply tfplan
cd -
```

### Afterwards: protect the local state file

`bootstrap/terraform.tfstate` now exists on your laptop and it is **not** a throwaway file. It
contains the application object ID, the service principal object ID and the storage account
details. It is gitignored. Three reasonable options:

1. **Keep it locally and back it up** (simplest; fine for a solo project).
2. **Migrate bootstrap state into the container it just created** — add a `backend "azurerm"`
   block to `bootstrap/` and run `terraform init -migrate-state`. Elegant, and the usual
   recommendation, but it means a destroyed state container takes its own state file with it.
3. **Accept that bootstrap is re-runnable** — the resources are all importable, and
   re-bootstrapping into an existing setup is a documented recovery path in
   [state-management.md](./state-management.md#recovering-a-corrupted-or-lost-state-file).

This repository takes option 1 and documents the recovery path. That is a defensible choice for
a single operator and an indefensible one for a team of ten.

**Cost: ≈ €0.** A storage account with a few hundred kilobytes of state and versioning enabled
costs a fraction of a cent per month. An Entra app registration, service principal and federated
credentials are free. **Do not delete the state storage account when you tear everything else
down** — see [Step 12](#step-12--tear-it-down).

---

## Step 6 — wire up GitHub

The bootstrap outputs everything the workflows need. Push it into GitHub as repository
**variables** (not secrets — none of these is a credential; see
[architecture.md](./architecture.md#why-repository-variables-not-secrets)).

```powershell
Push-Location .\bootstrap
$out = terraform output -json | ConvertFrom-Json
Pop-Location

gh variable set AZURE_CLIENT_ID         --body $out.github_actions_client_id.value
gh variable set AZURE_TENANT_ID         --body $out.tenant_id.value
gh variable set AZURE_SUBSCRIPTION_ID   --body $out.subscription_id.value
gh variable set TFSTATE_RESOURCE_GROUP  --body $out.state_resource_group_name.value
gh variable set TFSTATE_STORAGE_ACCOUNT --body $out.state_storage_account_name.value
gh variable set TFSTATE_CONTAINER       --body $out.state_container_name.value

gh variable list
```

```bash
cd bootstrap
gh variable set AZURE_CLIENT_ID         --body "$(terraform output -raw github_actions_client_id)"
gh variable set AZURE_TENANT_ID         --body "$(terraform output -raw tenant_id)"
gh variable set AZURE_SUBSCRIPTION_ID   --body "$(terraform output -raw subscription_id)"
gh variable set TFSTATE_RESOURCE_GROUP  --body "$(terraform output -raw state_resource_group_name)"
gh variable set TFSTATE_STORAGE_ACCOUNT --body "$(terraform output -raw state_storage_account_name)"
gh variable set TFSTATE_CONTAINER       --body "$(terraform output -raw state_container_name)"
cd -

gh variable list
```

Expected result:

```text
AZURE_CLIENT_ID          00000000-0000-0000-0000-000000000000  Updated 2026-01-14
AZURE_TENANT_ID          00000000-0000-0000-0000-000000000000  Updated 2026-01-14
AZURE_SUBSCRIPTION_ID    00000000-0000-0000-0000-000000000000  Updated 2026-01-14
TFSTATE_RESOURCE_GROUP   rg-tfstate-aksplat-weu                Updated 2026-01-14
TFSTATE_STORAGE_ACCOUNT  sttfstateaksplatweu4f2a               Updated 2026-01-14
TFSTATE_CONTAINER        tfstate                               Updated 2026-01-14
```

> There is **no** `gh secret set` step in this guide. If you find yourself reaching for one,
> something has gone wrong with the OIDC setup.

**Cost: €0.**

---

## Step 7 — configure GitHub Environments

The `environment:` federated credential subjects only produce a usable token if the matching
GitHub Environment exists. The protection rules on that environment are what make the credential
safe — see [security.md](./security.md#federated-credential-subject-pinning).

Create the three environments and attach reviewers:

```powershell
$repo = gh repo view --json nameWithOwner -q .nameWithOwner
$me   = gh api user -q .login
$myId = gh api user -q .id

foreach ($e in @('dev','staging','prod')) {
  gh api --method PUT "repos/$repo/environments/$e" --silent
}

# staging: one reviewer, no wait timer.
gh api --method PUT "repos/$repo/environments/staging" `
  -f "wait_timer=0" `
  -F "reviewers[][type]=User" -F "reviewers[][id]=$myId"

# prod: reviewer plus a 5 minute wait timer, and only main may deploy.
gh api --method PUT "repos/$repo/environments/prod" `
  -f "wait_timer=5" `
  -F "reviewers[][type]=User" -F "reviewers[][id]=$myId" `
  -f "deployment_branch_policy[protected_branches]=true" `
  -f "deployment_branch_policy[custom_branch_policies]=false"
```

```bash
repo="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
my_id="$(gh api user -q .id)"

for e in dev staging prod; do
  gh api --method PUT "repos/${repo}/environments/${e}" --silent
done

gh api --method PUT "repos/${repo}/environments/staging" \
  -f "wait_timer=0" \
  -F "reviewers[][type]=User" -F "reviewers[][id]=${my_id}"

gh api --method PUT "repos/${repo}/environments/prod" \
  -f "wait_timer=5" \
  -F "reviewers[][type]=User" -F "reviewers[][id]=${my_id}" \
  -f "deployment_branch_policy[protected_branches]=true" \
  -f "deployment_branch_policy[custom_branch_policies]=false"
```

> **Required reviewers on an environment require a public repository or a GitHub Team/Enterprise
> plan.** On a private repo on the Free plan the environment is created but the protection rules
> silently do not apply. If you are publishing this as a portfolio piece on a public repo, you
> get them for free. If you keep it private on a Free plan, the apply workflow still works but
> the approval gate does not — know which situation you are in, because a screenshot of an
> approval gate that does not actually gate anything is worse than no screenshot.

Verify in the UI at `https://github.com/<org>/<repo>/settings/environments`. This is
[screenshot `03-environment-approval.png`](./screenshots/README.md).

**Cost: €0.**

---

## Step 8 — create the backend config for dev

The `backend "azurerm"` block in `envs/dev/backend.tf` is intentionally empty. All coordinates
arrive via partial configuration, which is what lets the same code target three different state
files. See [state-management.md](./state-management.md#partial-backend-configuration).

```powershell
Copy-Item .\envs\dev\backend.hcl.example .\envs\dev\backend.hcl

Push-Location .\bootstrap
$out = terraform output -json | ConvertFrom-Json
Pop-Location

@"
resource_group_name  = "$($out.state_resource_group_name.value)"
storage_account_name = "$($out.state_storage_account_name.value)"
container_name       = "$($out.state_container_name.value)"
key                  = "dev/terraform.tfstate"
use_azuread_auth     = true
"@ | Set-Content -Encoding utf8 .\envs\dev\backend.hcl

Get-Content .\envs\dev\backend.hcl
```

```bash
cd bootstrap
cat > ../envs/dev/backend.hcl <<EOF
resource_group_name  = "$(terraform output -raw state_resource_group_name)"
storage_account_name = "$(terraform output -raw state_storage_account_name)"
container_name       = "$(terraform output -raw state_container_name)"
key                  = "dev/terraform.tfstate"
use_azuread_auth     = true
EOF
cd -

cat envs/dev/backend.hcl
```

`backend.hcl` is **gitignored**. `backend.hcl.example` is committed. The file contains no
secrets, but it does contain your storage account name, and committing it would make the repo
non-portable for anyone forking it.

`use_azuread_auth = true` makes the backend authenticate to the storage account with your Entra
identity rather than a shared account key. The storage account has
`shared_access_key_enabled = false`, so there is no key to fall back on. You need
**`Storage Blob Data Contributor`** on the container — the bootstrap grants it to you and to the
CI principal. Note that `Contributor` on the storage account is *not* sufficient: it lets you
manage the account but not read the data plane.

**Cost: €0.**

---

## Step 9 — init, plan, apply

> ⚠️ **This is the step that starts the meter.** `make apply-dev` creates two VMs, two managed
> disks, a NAT Gateway, a public IP, a container registry, a Key Vault and a Log Analytics
> workspace. Running cost ≈ **€190/month** if left up. See [cost.md](./cost.md#dev).

```powershell
make init-dev
make plan-dev
make apply-dev
```

```bash
make init-dev
make plan-dev
make apply-dev
```

If you do not have `make` on Windows, the scripts are the real implementation and the Makefile
just calls them:

```powershell
.\scripts\init-env.ps1  -Environment dev
.\scripts\plan-env.ps1  -Environment dev
.\scripts\apply-env.ps1 -Environment dev
```

```bash
./scripts/init-env.sh  dev
./scripts/plan-env.sh  dev
./scripts/apply-env.sh dev
```

Underneath, `init-env` runs:

```bash
terraform -chdir=envs/dev init -reconfigure -backend-config=backend.hcl
```

`-reconfigure` tells Terraform to discard any cached backend configuration and use what is in
`backend.hcl` verbatim. The alternative, `-migrate-state`, would try to **copy state from the
old backend to the new one** — which is correct when you are genuinely moving state and
dangerous when you are just pointing a fresh checkout at an existing backend. Use
`-reconfigure`. The distinction is explained in
[state-management.md](./state-management.md#reconfigure-versus-migrate-state).

`plan-env` runs a plan, saves it to `tfplan`, renders `tfplan.json` and runs conftest against it
locally — the same gate the PR workflow applies, so you find policy violations before you open a
pull request:

```bash
terraform -chdir=envs/dev plan -out=tfplan -lock-timeout=5m
terraform -chdir=envs/dev show -json tfplan > envs/dev/tfplan.json
conftest test --policy policy/conftest --all-namespaces envs/dev/tfplan.json
```

`apply-env` applies **the saved plan file**, never a fresh plan:

```bash
terraform -chdir=envs/dev apply -lock-timeout=5m tfplan
```

Applying a saved plan is not pedantry. A bare `terraform apply` re-plans at apply time, so what
gets applied is not necessarily what you reviewed. Applying the artefact you reviewed is the
whole point of the plan/apply split, and it is the same reason the CI workflow uploads the plan
file as an artifact.

### What to expect

```text
Plan: 41 to add, 0 to change, 0 to destroy.
...
module.aks.azurerm_kubernetes_cluster.this: Still creating... [5m20s elapsed]
...
Apply complete! Resources: 41 added, 0 changed, 0 destroyed.

Outputs:

aks_cluster_name      = "aks-aksplat-dev-weu"
acr_login_server      = "acraksplatdevweu.azurecr.io"
key_vault_name        = "kv-aksplat-dev-weu"
node_resource_group   = "MC_rg-aksplat-dev-weu_aks-aksplat-dev-weu_westeurope"
oidc_issuer_url       = "https://westeurope.oic.prod-aks.azure.com/00000000-.../00000000-.../"
workload_identity_client_id = "00000000-0000-0000-0000-000000000000"
```

Note the `MC_*` resource group. AKS creates it automatically to hold the node VMs, scale sets,
disks, the load balancer and the NAT gateway association. **It is not managed by Terraform** and
it is where most of your money lives. Deleting the cluster deletes it; deleting it by hand
breaks the cluster.

---

## Step 10 — connect to the cluster

```powershell
.\scripts\connect-aks.ps1 -Environment dev
kubectl get nodes -o wide
```

```bash
./scripts/connect-aks.sh dev
kubectl get nodes -o wide
```

The script does two things that a plain `az aks get-credentials` does not:

```bash
az aks get-credentials \
  --resource-group "rg-aksplat-dev-weu" \
  --name "aks-aksplat-dev-weu" \
  --overwrite-existing

# Mandatory. local_account_disabled = true means the admin kubeconfig does not exist,
# and azure_rbac_enabled = true means the token must come from Entra ID.
kubelogin convert-kubeconfig -l azurecli
```

Without the `kubelogin convert-kubeconfig` step, `kubectl` hangs or fails with an exec-plugin
error. `-l azurecli` reuses the token from your existing `az login`, which is the least annoying
mode for interactive use; `-l devicecode` is the fallback when you are on a machine without a
browser.

You also need an Azure RBAC role on the cluster. The bootstrap grants your user
**Azure Kubernetes Service RBAC Cluster Admin** on dev. Without it, `kubectl get nodes` returns a
clean, correct, and initially baffling `Error from server (Forbidden)` — your *authentication*
worked and your *authorisation* did not.

Expected output ([screenshot `05-kubectl-get-nodes.png`](./screenshots/README.md)):

```text
NAME                              STATUS   ROLES   AGE   VERSION   INTERNAL-IP   EXTERNAL-IP
aks-system-12345678-vmss000000    Ready    <none>  4m    v1.31.x   10.10.0.4     <none>
aks-user-87654321-vmss000000      Ready    <none>  3m    v1.31.x   10.10.16.4    <none>
```

Two things to notice: the internal IPs land in the subnets from the
[IP address plan](./architecture.md#ip-address-plan), and `EXTERNAL-IP` is `<none>` — nodes have
no public IPs.

---

## Step 11 — deploy the sample workload and verify Workload Identity

This is the step that proves the whole chain described in
[architecture.md](./architecture.md#3-workload-identity-token-exchange) actually works.

First, put a secret in the vault. Note that you need **Key Vault Secrets Officer** to write —
`enable_rbac_authorization = true` means access policies do not apply, and being the vault's
creator grants you nothing by itself:

```powershell
$kv = terraform -chdir=envs/dev output -raw key_vault_name
az keyvault secret set --vault-name $kv --name "demo-secret" --value "hello-from-key-vault"
```

```bash
kv="$(terraform -chdir=envs/dev output -raw key_vault_name)"
az keyvault secret set --vault-name "$kv" --name "demo-secret" --value "hello-from-key-vault"
```

The manifests in [`kubernetes/`](../kubernetes/) are templated with the values Terraform emits:

```powershell
$ns  = "apps"
$cid = terraform -chdir=envs/dev output -raw workload_identity_client_id
$tid = az account show --query tenantId -o tsv

kubectl create namespace $ns --dry-run=client -o yaml | kubectl apply -f -

(Get-Content .\kubernetes\workload-identity\serviceaccount.yaml) `
  -replace '<AZURE_CLIENT_ID>', $cid | kubectl apply -n $ns -f -

(Get-Content .\kubernetes\secrets-store\secretproviderclass.yaml) `
  -replace '<AZURE_CLIENT_ID>', $cid `
  -replace '<AZURE_TENANT_ID>', $tid `
  -replace '<KEY_VAULT_NAME>', $kv | kubectl apply -n $ns -f -
```

```bash
ns=apps
cid="$(terraform -chdir=envs/dev output -raw workload_identity_client_id)"
tid="$(az account show --query tenantId -o tsv)"

kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -

sed "s|<AZURE_CLIENT_ID>|${cid}|g" kubernetes/workload-identity/serviceaccount.yaml | kubectl apply -n "$ns" -f -
sed -e "s|<AZURE_CLIENT_ID>|${cid}|g" \
    -e "s|<AZURE_TENANT_ID>|${tid}|g" \
    -e "s|<KEY_VAULT_NAME>|${kv}|g" \
    kubernetes/secrets-store/secretproviderclass.yaml | kubectl apply -n "$ns" -f -
```

Note: `kubernetes/workload-identity/serviceaccount.yaml` already includes the sample `demo-app`
Deployment alongside the ServiceAccount and Namespace in one file (applied by the command above),
so there is no separate `deployment.yaml` to apply. See
[`kubernetes/README.md`](../kubernetes/README.md) for the full manifest layout and the end-to-end
secretless chain this wiring implements.

### Verify, in four escalating checks

**1. The webhook mutated the pod.** If this is empty, the `azure.workload.identity/use: "true"`
label is in the wrong place:

```bash
kubectl -n apps get pod -l app=demo -o jsonpath='{.items[0].spec.containers[0].env}' | jq
```

Expect `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_FEDERATED_TOKEN_FILE` and
`AZURE_AUTHORITY_HOST`.

**2. The projected token exists and has the right claims.** The `sub` here must byte-for-byte
equal the `subject` on the federated identity credential:

```bash
pod="$(kubectl -n apps get pod -l app=demo -o jsonpath='{.items[0].metadata.name}')"
kubectl -n apps exec "$pod" -- cat /var/run/secrets/azure/tokens/azure-identity-token \
  | cut -d. -f2 | base64 -d 2>/dev/null | jq '{iss, sub, aud, exp}'
```

```json
{
  "iss": "https://westeurope.oic.prod-aks.azure.com/00000000-0000-0000-0000-000000000000/00000000-0000-0000-0000-000000000000/",
  "sub": "system:serviceaccount:apps:demo-app",
  "aud": ["api://AzureADTokenExchange"],
  "exp": 1771000000
}
```

**3. The secret was mounted.** This is the money shot —
[screenshot `06-workload-identity-secret.png`](./screenshots/README.md):

```powershell
$pod = kubectl -n apps get pod -l app=demo -o jsonpath='{.items[0].metadata.name}'
kubectl -n apps exec $pod -- ls -l /mnt/secrets-store/
kubectl -n apps exec $pod -- cat /mnt/secrets-store/demo-secret
```

```bash
pod="$(kubectl -n apps get pod -l app=demo -o jsonpath='{.items[0].metadata.name}')"
kubectl -n apps exec "$pod" -- ls -l /mnt/secrets-store/
kubectl -n apps exec "$pod" -- cat /mnt/secrets-store/demo-secret
```

```text
hello-from-key-vault
```

**4. Prove it is actually federated and not something cached.** Change the secret in Azure and
watch the file update in place, without a pod restart — `secret_rotation_enabled` with the
default two-minute poll interval:

```bash
az keyvault secret set --vault-name "$kv" --name demo-secret --value "rotated-value"
sleep 150
kubectl -n apps exec "$pod" -- cat /mnt/secrets-store/demo-secret   # rotated-value
```

If all four pass, there is no credential anywhere in this path. The pod holds a one-hour
Kubernetes token; Entra ID issues an Azure token in exchange; Key Vault RBAC authorises the read.

---

## Step 12 — tear it down

> ⚠️ **Do this.** An idle dev environment is still a billed dev environment. Nodes bill per
> second whether or not a pod is scheduled.

### Full destroy

```powershell
make destroy-dev
```

```bash
make destroy-dev
```

which is:

```bash
terraform -chdir=envs/dev destroy -lock-timeout=5m
```

Takes **8–12 minutes**. Expect `Destroy complete! Resources: 41 destroyed.`

### Verify nothing is left

```powershell
az group list --query "[?starts_with(name,'rg-aksplat-dev') || starts_with(name,'MC_rg-aksplat-dev')].name" -o tsv
az network public-ip list --query "[].{name:name,rg:resourceGroup}" -o table
az disk list --query "[?diskState=='Unattached'].{name:name,rg:resourceGroup,gb:diskSizeGb}" -o table
az keyvault list-deleted --query "[].{name:name,scheduledPurge:properties.scheduledPurgeDate}" -o table
```

```bash
az group list --query "[?starts_with(name,'rg-aksplat-dev') || starts_with(name,'MC_rg-aksplat-dev')].name" -o tsv
az network public-ip list -o table
az disk list --query "[?diskState=='Unattached']" -o table
az keyvault list-deleted -o table
```

The first command should return **nothing**. If it returns an `MC_*` group, the cluster was
deleted but its node resource group was left behind — delete it manually.

### Cheaper than destroying: stop the cluster

If you want to come back tomorrow without a 15-minute rebuild:

```powershell
az aks stop --resource-group rg-aksplat-dev-weu --name aks-aksplat-dev-weu
# later
az aks start --resource-group rg-aksplat-dev-weu --name aks-aksplat-dev-weu
```

```bash
az aks stop  --resource-group rg-aksplat-dev-weu --name aks-aksplat-dev-weu
az aks start --resource-group rg-aksplat-dev-weu --name aks-aksplat-dev-weu
```

`az aks stop` deallocates the node VMs, so **VM compute charges stop**. Managed disks, the
public IP, the NAT Gateway hourly charge, ACR and the Log Analytics workspace keep billing — call
it €60/month residual on dev versus €190 running. Stop takes ~3 minutes, start ~4.

> Note: a stopped cluster still counts against your AKS cluster quota, and a cluster left
> stopped for more than 12 months may be deleted by the platform. Neither matters for a dev
> environment you rebuild weekly.

### What survives a destroy, on purpose

| Resource | Why it survives | Does it cost? |
|---|---|---|
| State storage account + container | Created by `bootstrap/`, not by `envs/dev/` | Fractions of a cent |
| Entra app registration + federated credentials | Created by `bootstrap/` | Free |
| Soft-deleted Key Vault (if purge protection was on) | Azure retains it for the retention period | **No cost**, but the name is reserved |
| Log Analytics workspace, for 14 days after delete | Azure soft-deletes workspaces | No cost |

Dev has purge protection **off**, so `terraform destroy` genuinely removes the vault and you can
reuse the name immediately. Staging and prod have it on; see
[cost.md](./cost.md#teardown-gotchas).

The full teardown story, including every way Azure can keep charging you after a successful
`destroy`, is in [cost.md](./cost.md#teardown).

---

## Timings

Measured on `westeurope`, one operator, nothing cached. Your mileage will vary by ±40 %;
Azure's control plane is not consistent.

| Step | Wall clock |
|---|---|
| Tool installation (Step 1) | 5–10 min |
| `az login` + subscription select | < 1 min |
| Resource provider registration | 1–3 min (parallel) |
| `scripts/preflight` | 30–60 s |
| `bootstrap` apply | 2–4 min |
| GitHub variables + environments | 2 min |
| `terraform init` (dev, first run) | 30–60 s (provider download) |
| `terraform plan` (dev) | 45–90 s |
| **`terraform apply` (dev) — total** | **12–18 min** |
| ⤷ VNet, NSGs, NAT Gateway | 1–2 min |
| ⤷ Log Analytics workspace | 1 min |
| ⤷ ACR | 1 min |
| ⤷ Key Vault | 1 min |
| ⤷ **AKS cluster** | **5–10 min** |
| ⤷ User node pool | 3–5 min |
| ⤷ Managed identities + federated credentials | < 1 min |
| ⤷ Role assignments (+ propagation) | 1–2 min |
| `connect-aks` + first `kubectl` | < 1 min |
| Sample workload + CSI mount | 1–2 min |
| Secret rotation visible in the mount | ~2 min (poll interval) |
| `terraform destroy` (dev) | 8–12 min |
| `az aks stop` / `az aks start` | 3 min / 4 min |
| **Staging apply** | 15–22 min |
| **Prod apply** (private cluster + private endpoints + DNS zones) | 20–30 min |

Prod is slower mainly because a private cluster has to provision a private endpoint and link
private DNS zones before the API server is reachable, and because three-zone node pools
provision serially per zone.

---

## Troubleshooting

### `Error: subscription_id is required`

The azurerm v4 provider no longer infers the subscription from the Azure CLI. Set
`ARM_SUBSCRIPTION_ID`, or pass `-var="subscription_id=..."`. This is the single most common
v3-to-v4 migration failure.

### `AADSTS70021: No matching federated identity record found`

The `iss`/`sub`/`aud` triple in the presented token does not exactly match any federated
identity credential. There is no wildcard matching. Diagnose by comparing the two sides:

```powershell
az ad app federated-credential list --id <APP_OBJECT_ID> `
  --query "[].{name:name, issuer:issuer, subject:subject, aud:audiences[0]}" -o table
```

For CI, compare against the `sub` the workflow actually sends — a job with
`environment: prod` sends `repo:<org>/<repo>:environment:prod`, a job without an `environment:`
key on `main` sends `repo:<org>/<repo>:ref:refs/heads/main`. Forgetting the `environment:` key
on an apply job is the classic cause.

For pods, compare against the token's `sub` claim using the decode command in
[Step 11, check 2](#verify-in-four-escalating-checks).

### `Error acquiring the state lock` / `state blob is already locked`

Another operation holds the blob lease. Usually a cancelled CI job. Do **not** force-unlock
reflexively — confirm nothing is running first. The full decision procedure is in
[state-management.md](./state-management.md#recovering-from-a-stuck-lock).

### Pod stuck in `ContainerCreating`, event says `failed to get secretproviderclass`

Three usual causes, in order of likelihood:

1. The `SecretProviderClass` is in a different namespace from the pod. It is a namespaced
   resource and must live alongside the pod.
2. `clientID` in the `SecretProviderClass` parameters does not match the managed identity's
   **client** ID (people paste the object ID or the principal ID).
3. `usePodIdentity: "false"` and `useVMManagedIdentity: "false"` are not both set — the provider
   defaults can select the wrong auth mode.

```bash
kubectl -n apps describe pod -l app=demo | tail -30
kubectl -n kube-system logs -l app=secrets-store-csi-driver -c secrets-store --tail=100
kubectl -n kube-system logs -l app=csi-secrets-store-provider-azure --tail=100
```

### `Forbidden: ... does not have secrets get permission`

Key Vault RBAC propagation, or the wrong role. The managed identity needs **Key Vault Secrets
User** (read) — `Reader` on the vault is a control-plane role and grants nothing on the data
plane. Allow 60 seconds for propagation, then:

```bash
az role assignment list --assignee "<MI_PRINCIPAL_ID>" --scope "<KEY_VAULT_ID>" -o table
```

### `kubectl` hangs, or `error: exec plugin ... kubelogin not found`

You skipped `kubelogin convert-kubeconfig -l azurecli`. Run
[`scripts/connect-aks`](../scripts/connect-aks.ps1) rather than `az aks get-credentials` by hand.

### `Error from server (Forbidden): nodes is forbidden`

Authentication worked; authorisation did not. You need an Azure RBAC role on the cluster:

```bash
az role assignment create \
  --assignee "$(az ad signed-in-user show --query id -o tsv)" \
  --role "Azure Kubernetes Service RBAC Cluster Admin" \
  --scope "$(terraform -chdir=envs/dev output -raw aks_cluster_id)"
```

### `QuotaExceeded` / `Operation could not be completed as it results in exceeding approved Total Regional Cores quota`

Request an increase for the relevant VM family in your region, then re-apply. `terraform apply`
is idempotent and will pick up where it stopped. [`scripts/preflight`](../scripts/preflight.ps1)
checks this up front for exactly this reason.

### `VaultAlreadyExists` / `the vault name is already in use`

A soft-deleted Key Vault is holding the name. Key Vault names are globally unique and soft-delete
is mandatory:

```bash
az keyvault list-deleted -o table
az keyvault purge --name "<vault-name>" --location westeurope
```

If **purge protection** was enabled (staging/prod) you cannot purge it. You must wait out the
retention period or choose a different name. This is the intended behaviour, not a bug.

### `ImagePullBackOff` with a 401 from ACR

The `AcrPull` role assignment is on the wrong principal. It must target the **kubelet** identity
(`kubelet_identity[0].object_id`), not the cluster identity:

```bash
az aks show -g rg-aksplat-dev-weu -n aks-aksplat-dev-weu \
  --query identityProfile.kubeletidentity.objectId -o tsv
az role assignment list --assignee "<that-object-id>" --all -o table
```

### `terraform destroy` fails on the Key Vault

Expected in staging/prod: `prevent_destroy` is set. That is the guard working. If you genuinely
mean it, remove the lifecycle block in a reviewed commit — never with `-target` or a local edit.
The prod destroy workflow is blocked outright; see
[`.github/workflows/terraform-destroy.yml`](../.github/workflows/terraform-destroy.yml).

### The PR plan comment never appears

Check that the workflow has `pull-requests: write` **and** `issues: write` (PR comments are
issue comments in the REST API), and that the PR touched a path in the workflow's `paths:`
filter — doc-only PRs deliberately skip the plan. See
[`.github/workflows/terraform-plan.yml`](../.github/workflows/terraform-plan.yml).

---

## See also

- [architecture.md](./architecture.md) — what you just built and why it looks like that
- [cost.md](./cost.md) — what it costs, and the full teardown checklist
- [security.md](./security.md) — the threat model behind the choices above
- [state-management.md](./state-management.md) — backend internals and recovery procedures
- [screenshots/README.md](./screenshots/README.md) — what to capture, and what to redact

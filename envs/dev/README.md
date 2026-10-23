# envs/dev

The cheapest, least-gated environment in this platform. Same modules and the same code paths as
staging and prod (docs/architecture.md, design principle 5) -- only `terraform.tfvars` and this
file differ.

See [docs/architecture.md](../../docs/architecture.md) for the full design (topology, IP address
plan, module composition) and [docs/cost.md](../../docs/cost.md) for what this actually costs and
how to stop paying for it.

## What makes dev different

| | dev | staging | prod |
|---|---|---|---|
| AKS SKU tier | `Free` (no SLA, lower API rate limit -- see below) | `Standard` | `Standard` |
| System pool | 1 x `Standard_B2s` | 2 x `Standard_D2s_v5` | 3 x `Standard_D4s_v5` |
| User pool | 1-2 x `Standard_D2s_v5` | 2-4 x `Standard_D4s_v5` | 3-10 x `Standard_D4s_v5` |
| Availability zones | none | `["1","2"]` | `["1","2","3"]` |
| Network policy | `azure` | `cilium` | `cilium` |
| Private cluster | no (public API server) | no | yes |
| Private endpoints (ACR, Key Vault) | none | none | both |
| ACR SKU | `Basic` | `Standard` | `Premium` |
| Key Vault purge protection | off | on | on |
| Log retention | 30 days | 30 days | 90 days |
| Approval to apply | none | 1 reviewer | 2 reviewers |
| Destroy workflow | allowed | allowed | blocked |

**Why `Free` in dev is not just a cost call.** The `Free` AKS tier has no uptime SLA and a lower
API server request/rate-limit ceiling. Running dev on `Free` means the team hits control-plane
throttling in dev first -- as an annoyance -- instead of discovering it in prod, as an incident.
The ~€70/month saving is a bonus, not the point. See docs/architecture.md's "Environment topology
differences" section.

**Why `network_policy = "azure"` here and `"cilium"` in staging/prod.** Cilium's eBPF dataplane
needs node SKU/kernel combinations that interact poorly with the burstable `Standard_B2s` dev
runs on. This is a deliberate, documented gap: dev does not exercise the same dataplane as prod.
If you are testing a `NetworkPolicy` change, test it in staging. See docs/architecture.md,
"Network policy: Cilium in staging/prod, azure in dev".

**Why no private endpoints.** ACR and Key Vault stay on their public, RBAC/Entra-protected
data-plane endpoints in dev and staging -- only prod pays for private endpoints and the private
DNS zones they need. `admin_enabled` on ACR and shared-key auth are disabled regardless, in every
environment, so "public endpoint" here never means "unauthenticated".

**Dev is designed to be destroyed nightly.** There is no `lifecycle.prevent_destroy` anywhere in
this directory and Key Vault's `purge_protection_enabled = false`, specifically so a routine
`terraform destroy` actually releases every reserved name (see `versions.tf`'s
`purge_soft_delete_on_destroy = true` comment for why that setting exists only here).

## Known limitation: cluster-scoped observability alerts are not created

`module.observability` is called with `aks_cluster_id = null` in `main.tf`. The three
scheduled-query alerts that module can create (node not ready, pod restart rate, node disk
pressure) require a non-null `aks_cluster_id` -- but `module.aks` needs this module's
`log_analytics_workspace_id` *before* the cluster exists, which is a genuine two-way need between
two modules that are not allowed to call each other (docs/architecture.md, design principle 4).
`main.tf` documents the two ways to resolve this (a second `observability_alerts`-shaped module
call referencing `module.aks.cluster_id`, or a deliberate two-pass apply) and neither is wired up
today. Container Insights (`oms_agent`) and the ACR/Key Vault diagnostic settings are unaffected --
none of them depend on `aks_cluster_id`.

## Usage

```powershell
# One-time, after bootstrap/ has been applied: create envs/dev/backend.hcl
# (see backend.hcl.example in this directory, or run
# .\scripts\bootstrap-backend.ps1 -WriteBackendFiles for all three environments at once).

.\scripts\init-env.ps1 dev      # terraform init -backend-config=backend.hcl, then validate
.\scripts\plan-env.ps1 dev      # terraform plan, human-readable change summary, Rego policy gate
.\scripts\apply-env.ps1 dev     # applies the saved plan; prompts unless -Force
```

Before the first `plan-env.ps1`, copy `terraform.tfvars`'s placeholders into something real:
`subscription_id`, `tenant_id`, and (if you care about restricting the public API server)
`authorized_ip_ranges`.

### Teardown

Dev is not free to leave running (an AKS cluster with its node pools, Log Analytics ingestion, ACR
and Key Vault bill continuously). When you are done:

```powershell
.\scripts\plan-env.ps1 dev -Destroy -Out tfplan.destroy   # review first
terraform -chdir=envs\dev destroy                          # then tear down
```

The remote state backend and the bootstrap stack survive this, so dev can be rebuilt from scratch
in one apply the next time you need it.

## See also

- [docs/architecture.md](../../docs/architecture.md) -- full design, IP address plan, module
  composition, ordering constraints
- [docs/cost.md](../../docs/cost.md) -- what this environment costs and how to estimate it before
  applying (`scripts/cost-estimate.ps1 dev`)

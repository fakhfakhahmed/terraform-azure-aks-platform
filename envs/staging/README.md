# envs/staging

Mirrors prod's topology at a smaller scale, so a change is validated against the same shape it
will run in production before it ever reaches prod -- same modules and the same code paths as dev
and prod (docs/architecture.md, design principle 5), only `terraform.tfvars` and this file differ.

See [docs/architecture.md](../../docs/architecture.md) for the full design (topology, IP address
plan, module composition) and [docs/cost.md](../../docs/cost.md) for what this actually costs.

## What makes staging different

| | dev | staging | prod |
|---|---|---|---|
| AKS SKU tier | `Free` | `Standard` (99.95% SLA) | `Standard` |
| System pool | 1 x `Standard_B2s` | 2 x `Standard_D2s_v5` | 3 x `Standard_D4s_v5` |
| User pool | 1-2 x `Standard_D2s_v5` | 2-4 x `Standard_D4s_v5` | 3-10 x `Standard_D4s_v5` |
| Availability zones | none | `["1","2"]` | `["1","2","3"]` |
| Network policy | `azure` | `cilium` | `cilium` |
| Private cluster | no | no (public API server) | yes |
| Private endpoints (ACR, Key Vault) | none | **none** | both |
| ACR SKU | `Basic` | `Standard` | `Premium` |
| Key Vault purge protection | off | **on** | on |
| Log retention | 30 days | 30 days | 90 days |
| Approval to apply | none | **1 reviewer** | 2 reviewers |
| Destroy workflow | allowed | allowed | blocked |

**Staging runs `cilium` network policy, not `azure`.** This is the environment where a
`NetworkPolicy` change gets validated against the real dataplane before it reaches prod --
dev intentionally does not exercise Cilium (see `envs/dev/README.md`). If a policy change passes
here, it is safe to promote.

**Key Vault purge protection is on in staging, same as prod.** Unlike dev, staging's vault is not
meant to be thrown away casually: `key_vault_purge_protection_enabled = true` means a deleted
vault stays soft-deleted and its name stays reserved for `key_vault_soft_delete_retention_days`
(30 here), and this **cannot be reversed** once applied (Azure's own one-way-door design -- see
docs/architecture.md, "Why prod's purge protection is on and irreversible"). `versions.tf`
deliberately does **not** set `purge_soft_delete_on_destroy = true` here, unlike dev, precisely
because that flag would be a silent no-op against a purge-protected vault.

**Staging still has NO private endpoints.** This is the one place staging does *not* mirror prod:
per docs/architecture.md's environment topology table, private endpoints for ACR and Key Vault are
a prod-only cost and complexity addition. ACR and Key Vault here stay on their public,
RBAC/Entra-protected data-plane endpoints -- `admin_enabled` and shared-key auth remain disabled
regardless.

**Applying to staging requires one reviewer approval** in the GitHub Actions pipeline (the
GitHub Environment named `staging` is protected -- see bootstrap/github-oidc.tf and
docs/architecture.md's "2. GitHub OIDC to Azure authentication flow"). A local
`.\scripts\apply-env.ps1 staging` still works without that gate (there is no break-glass guard on
staging the way there is on prod), but the sanctioned path is the pipeline.

## Known limitation: cluster-scoped observability alerts are not created

`module.observability` is called with `aks_cluster_id = null` in `main.tf`. The three
scheduled-query alerts that module can create (node not ready, pod restart rate, node disk
pressure) require a non-null `aks_cluster_id` -- but `module.aks` needs this module's
`log_analytics_workspace_id` *before* the cluster exists, which is a genuine two-way need between
two modules that are not allowed to call each other (docs/architecture.md, design principle 4).
`main.tf` documents the two ways to resolve this (a second `observability_alerts`-shaped module
call referencing `module.aks.cluster_id`, or a deliberate two-pass apply) and neither is wired up
today. Container Insights (`oms_agent`) and the ACR/Key Vault diagnostic settings are unaffected --
none of them depend on `aks_cluster_id`. Set `action_group_email_receivers` to a real address: it
is the only alerting this platform has until that limitation is resolved.

## Usage

```powershell
# One-time, after bootstrap/ has been applied: create envs/staging/backend.hcl
# (see backend.hcl.example in this directory, or run
# .\scripts\bootstrap-backend.ps1 -WriteBackendFiles for all three environments at once).

.\scripts\init-env.ps1 staging      # terraform init -backend-config=backend.hcl, then validate
.\scripts\plan-env.ps1 staging      # terraform plan, human-readable change summary, Rego policy gate
.\scripts\apply-env.ps1 staging     # applies the saved plan; prompts unless -Force
```

Before the first `plan-env.ps1`, copy `terraform.tfvars`'s placeholders into something real:
`subscription_id`, `tenant_id`, `authorized_ip_ranges`, and at least one
`action_group_email_receivers` entry.

### Teardown

```powershell
.\scripts\plan-env.ps1 staging -Destroy -Out tfplan.destroy   # review first
terraform -chdir=envs\staging destroy                          # then tear down
```

Unlike prod, staging's destroy workflow is **not** blocked -- it is meant to be rebuildable, just
like dev. Remember that `key_vault_purge_protection_enabled = true` means the Key Vault's name
stays reserved for 30 days after a destroy, even though the vault itself is gone.

## See also

- [docs/architecture.md](../../docs/architecture.md) -- full design, IP address plan, module
  composition, ordering constraints
- [docs/cost.md](../../docs/cost.md) -- what this environment costs

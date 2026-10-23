# envs/prod

The superset environment (docs/architecture.md's topology diagram is drawn for prod). Same
modules and the same code paths as dev and staging (docs/architecture.md, design principle 5) --
only `terraform.tfvars` differs, with one documented exception below.

See [docs/architecture.md](../../docs/architecture.md) for the full design (topology, IP address
plan, module composition) and [docs/cost.md](../../docs/cost.md) for what this actually costs.

## What makes prod different

| | dev | staging | prod |
|---|---|---|---|
| AKS SKU tier | `Free` | `Standard` | `Standard` |
| System pool | 1 x `Standard_B2s` | 2 x `Standard_D2s_v5` | 3 x `Standard_D4s_v5` |
| User pool | 1-2 x `Standard_D2s_v5` | 2-4 x `Standard_D4s_v5` | 3-10 x `Standard_D4s_v5` |
| Availability zones | none | `["1","2"]` | **`["1","2","3"]`** |
| Network policy | `azure` | `cilium` | `cilium` |
| Private cluster | no | no | **yes** -- API server has no public FQDN |
| Private endpoints (ACR, Key Vault) | none | none | **both** |
| ACR SKU | `Basic` | `Standard` | **`Premium`** (required for private endpoints) |
| Key Vault purge protection | off | on | **on, irreversible** |
| Log retention | 30 days | 30 days | **90 days** |
| Approval to apply | none | 1 reviewer | **2 reviewers** |
| Destroy workflow | allowed | allowed | **blocked** |

## Known limitation: cluster-scoped observability alerts are not created

`module.observability` is called with `aks_cluster_id = null` in `main.tf`. The three
scheduled-query alerts that module can create (node not ready, pod restart rate, node disk
pressure) require a non-null `aks_cluster_id` -- but `module.aks` needs this module's
`log_analytics_workspace_id` *before* the cluster exists, which is a genuine two-way need between
two modules that are not allowed to call each other (docs/architecture.md, design principle 4).
`main.tf` documents the two ways to resolve this (a second `observability_alerts`-shaped module
call referencing `module.aks.cluster_id`, or a deliberate two-pass apply) and neither is wired up
today. Container Insights (`oms_agent`) and the ACR/Key Vault diagnostic settings are unaffected --
none of them depend on `aks_cluster_id`. **This is a materially bigger gap in prod than
elsewhere**: it means there is no automated "node not ready" or "pod restart rate" alert until it
is resolved. `action_group_email_receivers` must still be set to a real, monitored address so that
whatever alerting does exist (today: none from this module, but any workload-level alerting added
later that reuses `module.observability.action_group_id`) actually reaches someone.

## Known limitation: `prevent_destroy` is not implemented as Terraform code

docs/architecture.md's environment topology table lists `prevent_destroy` as "yes (Key Vault,
ACR, Log Analytics)" for prod. That line is a statement of intent, not a description of code in
this repository: `lifecycle { prevent_destroy = true }` is a **resource-level** meta-argument. It
can only be written inside the `resource` block it protects -- there is no way to pass it through
a `module` block's arguments, because Terraform has no `lifecycle` argument a module consumer can
set on the resources a module creates. `modules/keyvault`, `modules/acr` and
`modules/observability`'s `variables.tf` (read in full while building this root module) expose no
`prevent_destroy`-shaped variable, and none was fabricated here to paper over that gap -- a fake
variable that silently does nothing would be worse than an honest limitation.

`main.tf` documents three real ways to close this properly (in increasing order of cost: add a
`prevent_destroy` variable to the three modules behind a `count`/`for_each` toggle since
Terraform has no conditional `lifecycle` block; write prod-specific resource wrappers here that
bypass the shared modules for just these three resources; or accept the gap). This repository
takes the third option and leans on what is **actually** protecting prod today:

- **`prevent_deletion_if_contains_resources = true`** on the provider's `resource_group` features
  block (`versions.tf`) -- ARM itself refuses to delete prod's resource group while it still
  contains resources. This is most of what `prevent_destroy` would buy, enforced one level up and
  impossible to forget on a single resource.
- **Key Vault `purge_protection_enabled = true`** -- even a successful `terraform destroy` only
  soft-deletes the vault; the key material is recoverable for `key_vault_soft_delete_retention_days`
  (90 days here) and cannot be purged by Terraform, the portal, or Azure support. This is a
  *stronger* guarantee than `prevent_destroy` specifically for the vault.
- **The GitHub Environment approval gate**: 2 required reviewers before a prod apply can run (see
  docs/architecture.md, "2. GitHub OIDC to Azure authentication flow").
- **`scripts/apply-env.ps1`'s production guard**: refuses to touch prod without `-Force` **and** a
  typed `apply-prod` confirmation at an interactive prompt.
- **`.github/workflows/terraform-destroy.yml` blocks the destroy workflow for prod entirely.**
- **State backend hardening** (`bootstrap/main.tf`): blob versioning + soft delete on the state
  storage account mean the record of what existed survives even if the resources themselves did
  not.
- A **management lock** (`az lock create --lock-type CanNotDelete`) can be applied by hand on
  prod's resource group for an extra, deliberately-manual layer -- the same pattern
  `bootstrap/main.tf` uses for its own state resource group.

## Usage

```powershell
# One-time, after bootstrap/ has been applied: create envs/prod/backend.hcl
# (see backend.hcl.example in this directory, or run
# .\scripts\bootstrap-backend.ps1 -WriteBackendFiles for all three environments at once).

.\scripts\init-env.ps1 prod      # terraform init -backend-config=backend.hcl, then validate
.\scripts\plan-env.ps1 prod      # terraform plan, human-readable change summary, Rego policy gate
```

**The sanctioned path to apply prod is the GitHub Actions pipeline**, gated by the `prod` GitHub
Environment's 2 required reviewers:

```bash
gh workflow run terraform-apply.yml -f environment=prod
# then approve the deployment in the GitHub Environment
```

`scripts/apply-env.ps1 prod` exists only as a **break-glass** path for when the pipeline itself is
unavailable. It refuses outright without `-Force`, and even with `-Force` it demands you type the
literal string `apply-prod` at an interactive prompt. If you find yourself doing this routinely,
the pipeline is what needs fixing, not this guard.

Before the first `plan-env.ps1`, replace every placeholder in `terraform.tfvars`:
`subscription_id`, `tenant_id`, `admin_group_object_ids` (a real Entra group), and
`action_group_email_receivers` (a real, monitored address). None of those placeholders should ever
reach a real prod apply.

### Teardown

**Prod's destroy workflow is blocked in CI** (`.github/workflows/terraform-destroy.yml`), and
Key Vault's `purge_protection_enabled = true` means even a manual destroy cannot permanently
remove the vault's key material for `key_vault_soft_delete_retention_days` (90 days). If you
genuinely need to decommission prod, that is a deliberate, documented, multi-step process -- see
[docs/cost.md](../../docs/cost.md#teardown) -- not a single command.

## See also

- [docs/architecture.md](../../docs/architecture.md) -- full design, IP address plan, module
  composition, ordering constraints
- [docs/security.md](../../docs/security.md) -- threat model and what is deliberately relaxed in
  dev (and, by contrast, what prod does not relax)
- [docs/cost.md](../../docs/cost.md) -- what this environment costs and prod teardown gotchas

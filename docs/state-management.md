# State management

Everything about how this platform stores, locks, isolates, refactors and recovers Terraform
state. If you only read one section, read
[Recovering from a stuck lock](#recovering-from-a-stuck-lock) — it is the one that gets
improvised badly under pressure.

**Contents**

- [Why remote state at all](#why-remote-state-at-all)
- [The azurerm backend](#the-azurerm-backend)
- [Locking: blob leases, not DynamoDB](#locking-blob-leases-not-dynamodb)
- [State isolation](#state-isolation)
- [Partial backend configuration](#partial-backend-configuration)
- [`-reconfigure` versus `-migrate-state`](#reconfigure-versus-migrate-state)
- [Versioning and soft delete as the recovery mechanism](#versioning-and-soft-delete-as-the-recovery-mechanism)
- [Operating on state: the CLI surface](#operating-on-state-the-cli-surface)
- [Importing existing resources](#importing-existing-resources)
- [`moved {}` — refactoring without destroying](#moved--refactoring-without-destroying)
- [`removed {}` — forgetting without destroying](#removed--forgetting-without-destroying)
- [Recovering from a stuck lock](#recovering-from-a-stuck-lock)
- [Recovering a corrupted or lost state file](#recovering-a-corrupted-or-lost-state-file)
- [State size and performance](#state-size-and-performance)
- [Secrets in state](#secrets-in-state)
- [Operational checklist](#operational-checklist)

---

## Why remote state at all

Terraform's state file is the mapping between the resources declared in HCL and the real objects
in Azure. Without it, Terraform has no idea that `azurerm_kubernetes_cluster.this` corresponds to
a specific cluster, and `plan` would propose creating everything from scratch.

Local state fails for four separate reasons, and all four apply here:

1. **Collaboration.** Two people with two local state files produce two divergent views of the
   same infrastructure. Whoever applies second destroys or duplicates the first one's work.
2. **Locking.** Local state has no concurrency control beyond a file lock on one machine. Two
   simultaneous applies against the same resources produce a corrupted state and partially
   applied infrastructure. This is not theoretical; it is a near-certainty with a CI pipeline
   and a human both able to run `apply`.
3. **Durability.** A laptop dies and takes prod's state with it. Rebuilding state by hand means
   `terraform import` for every one of ~55 resources, and some of them (role assignments,
   federated credentials) have import IDs that are tedious to construct.
4. **Secrets.** State contains sensitive values in plaintext. See
   [Secrets in state](#secrets-in-state). A plaintext secret store on a developer laptop, inside
   a OneDrive-synced folder, is a data breach waiting to be written up.

**State is never committed to git.** `.gitignore` covers `*.tfstate`, `*.tfstate.*`,
`.terraform/`, `*.tfplan`, `tfplan.json` and `backend.hcl`. The gitleaks job in
[`security.yml`](../.github/workflows/security.yml) is the second line of defence if someone
force-adds one.

The one exception in this repository is [`bootstrap/`](../bootstrap/), which must use local
state because it creates the backend that everything else uses. That chicken-and-egg problem and
its three resolutions are discussed in
[getting-started.md](./getting-started.md#afterwards-protect-the-local-state-file).

---

## The azurerm backend

```hcl
# envs/dev/backend.tf — deliberately empty. All values come from backend.hcl.
terraform {
  backend "azurerm" {}
}
```

```hcl
# envs/dev/backend.hcl — gitignored; backend.hcl.example is committed.
resource_group_name  = "rg-tfstate-aksplat-weu"
storage_account_name = "sttfstateaksplatweu4f2a"
container_name       = "tfstate"
key                  = "dev/terraform.tfstate"
use_azuread_auth     = true
```

The state storage account is created by [`bootstrap/`](../bootstrap/) with the following
non-default settings, each of which is load-bearing:

| Setting | Value | Why |
|---|---|---|
| `blob_properties.versioning_enabled` | `true` | Every write creates a new version. This is the undo button for a corrupted state. |
| `blob_properties.delete_retention_policy.days` | `30` | Soft delete for blobs; recovers an accidentally deleted state file. |
| `blob_properties.container_delete_retention_policy.days` | `30` | Recovers an accidentally deleted *container*. |
| `shared_access_key_enabled` | `false` | Kills the "copy the storage key into a secret" pattern dead. There is no key to leak. |
| `allow_nested_items_to_be_public` | `false` | A public state blob is a full infrastructure disclosure. |
| `min_tls_version` | `TLS1_2` | |
| `public_network_access_enabled` | `true` (with network rules) | CI runners have dynamic IPs; locking the state account to a private endpoint would require self-hosted runners. An honest trade-off, revisited below. |
| `infrastructure_encryption_enabled` | `true` | Double encryption at rest. Cheap, so why not. |
| Container access | RBAC only | `Storage Blob Data Contributor` on the container, granted to the CI principal and to operators. |

### `use_azuread_auth = true`

This is the setting that makes the whole model work. By default the azurerm backend
authenticates to the storage account with a **shared account key** — a long-lived, high-value,
copy-pasteable credential that grants full data-plane access to every blob in the account, and
that most teams end up storing in a CI secret.

With `use_azuread_auth = true` the backend uses the caller's Entra ID token instead, and
authorisation is Azure RBAC on the container. Combined with `shared_access_key_enabled = false`,
there is no account key in existence. In CI this is set via `ARM_USE_AZUREAD=true` alongside
`ARM_USE_OIDC=true`, so the runner's OIDC token is what reads and writes state — see
[`terraform-plan.yml`](../.github/workflows/terraform-plan.yml).

The role you need is **`Storage Blob Data Contributor`**, scoped to the container. Note what does
*not* work:

- `Contributor` on the storage account — a control-plane role. It lets you delete the account
  but not read a blob. (It *can* list keys, but there are no keys.)
- `Reader` — neither plane.
- `Storage Blob Data Reader` — can read state, cannot write it, so `plan` works and `apply`
  fails at the very end. A genuinely useful role for a read-only auditor.

### The honest caveat about public network access

The state account accepts traffic from the internet, filtered by a network rule set. GitHub-hosted
runners come from a large, published, frequently-changing IP range, so IP allow-listing is
impractical; the account instead relies on Entra authentication plus RBAC with no key fallback.

If this were a regulated production tenant, the right answer is a private endpoint on the state
account and self-hosted runners (or an Azure-hosted GitHub runner in the VNet). That is a real
piece of deferred work, not a rationalisation — it is listed in
[security.md](./security.md#what-i-would-add-next).

---

## Locking: blob leases, not DynamoDB

Terraform must guarantee that two `apply` operations never write the same state file
concurrently. Every backend solves this differently, and the Azure solution is pleasingly boring.

**The azurerm backend acquires an exclusive lease on the state blob itself.** A blob lease is a
native Azure Storage primitive: a time-bounded exclusive write lock on a single blob, identified
by a lease ID (a GUID). While a lease is held, any write without the lease ID returns HTTP 412.
Terraform takes an infinite-duration lease at the start of an operation and releases it at the
end, and writes a small `.tflock` companion blob holding the lock metadata (who, when, which
operation, and the lease ID).

### Why this matters compared with AWS

| | S3 + DynamoDB (classic AWS) | azurerm blob lease |
|---|---|---|
| Extra infrastructure to provision | A DynamoDB table, with its own IAM, capacity mode and cost | **None** |
| Where the lock lives | A separate service, in a separate row keyed by state path | On the state blob itself |
| Failure mode on backend outage | State and lock can disagree | They cannot disagree; they are the same object |
| Can the lock be orphaned? | Yes — a row left behind | Yes — a lease left held |
| Cost | A few cents to a few dollars per month | €0 |
| Terraform config needed | `dynamodb_table = "..."` | Nothing |

There is no `dynamodb_table` equivalent in the azurerm backend and no second resource to forget
to create. Engineers arriving from AWS routinely look for it; it does not exist, and its absence
is a genuine simplification rather than a missing feature.

(For completeness: S3 gained native lockfile support in Terraform 1.10 via `use_lockfile`,
narrowing the gap. The azurerm backend has worked this way since the beginning.)

### Lock timeouts

Every Terraform invocation in this repository passes `-lock-timeout=5m`:

```bash
terraform plan  -lock-timeout=5m -out=tfplan
terraform apply -lock-timeout=5m tfplan
```

Without it, Terraform fails **immediately** if the lock is held. With it, Terraform retries for
five minutes. This matters in CI, where a drift-detection run and a PR plan can legitimately
collide for thirty seconds. Five minutes is long enough to absorb an overlapping plan and short
enough that a genuinely stuck lock fails the job rather than hanging the runner.

---

## State isolation

### Per environment

One state file per environment, in a single container:

```text
tfstate/
├── dev/terraform.tfstate
├── staging/terraform.tfstate
└── prod/terraform.tfstate
```

Separate blobs mean **separate leases**. An apply in dev cannot block, corrupt, or accidentally
include prod. A catastrophic mistake in a dev state file — a bad `state rm`, a corrupted write —
has a blast radius of exactly one environment.

This is the operational half of [ADR-0001](./decisions/0001-directory-per-environment.md). The
other half is that `terraform plan` in `envs/dev` *physically cannot* see prod's resources, so
there is no version of a typo that produces a prod change.

### Why not `terraform workspace`?

Workspaces store all environments in **one state file namespace managed by one backend
configuration**, under `env:/<workspace>/<key>`. Concretely:

- A misremembered `terraform workspace select` is a silent, catastrophic failure mode. The code
  is identical; only an invisible CLI-local setting distinguishes dev from prod. There is no
  review artefact that records which workspace you were in.
- The backend configuration is shared, so all workspaces must use the same storage account and
  the same RBAC. You cannot grant someone dev access without granting them the ability to read
  prod state.
- Environment differences have to be expressed as `terraform.workspace == "prod" ? ... : ...`
  conditionals inside the code, which is strictly worse than a `.tfvars` file.

Workspaces are a good fit for ephemeral, identical, short-lived instances — a per-PR review
environment, for example. They are a poor fit for long-lived environments with different
permission boundaries.

### Per layer (not done here, and why)

A larger platform would split further — networking, cluster, and workload-identity layers each
with their own state, consuming each other via `terraform_remote_state` data sources. The
benefit is smaller blast radius and faster plans. The cost is real:

- `terraform_remote_state` requires the consumer to hold read access to the producer's state —
  the whole state, including its secrets.
- Cross-layer changes need a coordinated multi-apply, in order, with no transaction.
- A single-command "build me an environment" no longer exists.

At ~55 resources per environment and a plan time under 90 seconds, splitting layers would buy
nothing and cost a lot of ceremony. **Split when plan time or team contention makes you,
not before.** The natural first cut, if it comes, is the VNet: it changes rarely and everything
depends on it.

---

## Partial backend configuration

A `backend` block cannot use variables, interpolation, or expressions. This is a deliberate
Terraform limitation: the backend must be resolvable before any variable evaluation happens.

Partial configuration is the escape hatch. Leave the block empty and supply the values at
`init`:

```bash
terraform init -reconfigure -backend-config=backend.hcl
```

or as discrete flags, which is what CI does because the values come from GitHub variables:

```bash
terraform init \
  -input=false \
  -backend-config="resource_group_name=${TFSTATE_RESOURCE_GROUP}" \
  -backend-config="storage_account_name=${TFSTATE_STORAGE_ACCOUNT}" \
  -backend-config="container_name=${TFSTATE_CONTAINER}" \
  -backend-config="key=${ENVIRONMENT}/terraform.tfstate"
```

Both forms are used: `backend.hcl` locally (one file, easy to inspect), flags in CI (no file to
write, values come straight from `vars`).

`backend.hcl` is gitignored and `backend.hcl.example` is committed. The file holds no secrets —
a storage account name is not a credential — but committing it would hardcode *my* storage
account into a repository other people are meant to fork.

### Reading state from the CLI without a full init

Useful for scripts and for debugging a broken backend:

```bash
az storage blob download \
  --account-name sttfstateaksplatweu4f2a \
  --container-name tfstate \
  --name dev/terraform.tfstate \
  --auth-mode login \
  --file ./dev.tfstate.inspect
```

`--auth-mode login` is required: without it the CLI tries to find an account key, and there
isn't one. Delete the file when you are done; it is a plaintext secret store.

---

## `-reconfigure` versus `-migrate-state`

These two flags look interchangeable and are not. Choosing wrongly can copy prod state over dev
state.

| Flag | What it does | Use when |
|---|---|---|
| `-reconfigure` | Discards the cached backend config in `.terraform/` and initialises against the new one. **Does not touch state data.** | A fresh clone; switching between environments; the backend config changed but the state is already where you want it |
| `-migrate-state` | Reads state from the **previously configured** backend and **writes it into the new one**, prompting for confirmation | Genuinely relocating state: local → remote, or one storage account → another |

This repository always uses `-reconfigure`:

```bash
terraform -chdir=envs/dev init -reconfigure -backend-config=backend.hcl
```

The dangerous scenario is concrete. Suppose you ran `init` in `envs/prod`, then switched to
`envs/dev`. Terraform's `.terraform/terraform.tfstate` (the backend *config* cache, not your
infrastructure state) still remembers `key = "prod/terraform.tfstate"`. If you now run
`init -migrate-state -backend-config=backend.hcl` and accept the prompt, Terraform will copy
**prod's state into dev's blob**. The next `terraform apply` in dev sees prod's resources in
state and dev's configuration in code, and proposes to reshape prod into dev.

Mitigations, layered:

1. `scripts/init-env.*` hardcodes `-reconfigure` and never exposes `-migrate-state`.
2. A separate `.terraform/` directory per environment directory (free, because of
   directory-per-environment).
3. Blob versioning on the container, so even the worst case is recoverable.

If you genuinely need to migrate state, do it deliberately, with a `terraform state pull` backup
taken first, and read the confirmation prompt rather than typing `yes` reflexively.

---

## Versioning and soft delete as the recovery mechanism

The state container has three overlapping safety nets:

| Mechanism | Protects against | Retention |
|---|---|---|
| Blob versioning | A bad write — corruption, a destructive `state rm`, a truncated upload | All versions, pruned by lifecycle policy |
| Blob soft delete | Deletion of the state blob | 30 days |
| Container soft delete | Deletion of the whole container | 30 days |

Terraform itself keeps no history. Every `apply` overwrites the blob. **Versioning is the only
reason a bad state write is survivable**, and it is the single most valuable setting on the
storage account.

List the versions of a state file:

```powershell
az storage blob list `
  --account-name sttfstateaksplatweu4f2a `
  --container-name tfstate `
  --prefix "dev/terraform.tfstate" `
  --include v `
  --auth-mode login `
  --query "[].{name:name, version:versionId, current:isCurrentVersion, modified:properties.lastModified, bytes:properties.contentLength}" `
  -o table
```

```bash
az storage blob list \
  --account-name sttfstateaksplatweu4f2a \
  --container-name tfstate \
  --prefix "dev/terraform.tfstate" \
  --include v \
  --auth-mode login \
  --query "[].{name:name, version:versionId, current:isCurrentVersion, modified:properties.lastModified}" \
  -o table
```

Restoring is covered in
[Recovering a corrupted or lost state file](#recovering-a-corrupted-or-lost-state-file).

---

## Operating on state: the CLI surface

Everything here mutates or reads the real state file. Rules of engagement:

- **Always `terraform state pull > backup.tfstate` before any mutating command.** It costs two
  seconds. Versioning covers you too, but a local file is faster to reason about at 2 a.m.
- **Never run a mutating state command in CI.** State surgery is an interactive, considered act.
- **Prefer `moved {}` and `import {}` blocks over `state mv` and `state import`** — they are
  reviewable in a pull request and visible in a plan. The CLI is for the cases blocks cannot
  express.

### Read-only

```bash
# Every resource address in state. The first thing to run when orienting yourself.
terraform -chdir=envs/dev state list

# Filter by module.
terraform -chdir=envs/dev state list 'module.aks.*'

# Full attributes of one resource, as Terraform sees it.
terraform -chdir=envs/dev state show 'module.aks.azurerm_kubernetes_cluster.this'

# The whole state as JSON, to stdout. Does NOT write a local file.
terraform -chdir=envs/dev state pull > /tmp/dev-backup.tfstate

# Resource count — a rough health signal.
terraform -chdir=envs/dev state list | wc -l
```

> `terraform state show` prints sensitive attributes in the clear. Do not run it in a shared
> terminal, and never paste its output into a PR or a screenshot. See
> [Secrets in state](#secrets-in-state).

### Mutating

```bash
# Rename / move a resource within state. The resource is NOT touched in Azure.
terraform -chdir=envs/dev state mv \
  'azurerm_key_vault.this' \
  'module.keyvault.azurerm_key_vault.this'

# Forget a resource without destroying it. The object continues to exist in Azure,
# unmanaged. Terraform will propose to CREATE it again unless the config is also removed.
terraform -chdir=envs/dev state rm 'module.observability.azurerm_application_insights.this'

# Overwrite remote state with a local file. The nuclear option.
terraform -chdir=envs/dev state push ./repaired.tfstate
```

`terraform state push` deserves a warning in its own right. It replaces the remote state
wholesale, and Terraform will refuse unless the lineage matches and the serial is higher — which
people then override with `-force`. A `state push -force` with a stale file silently reverts
every change made since that file was pulled. **If you are reaching for `-force`, stop and get a
second pair of eyes.**

---

## Importing existing resources

### The modern way: `import {}` blocks (Terraform 1.5+)

```hcl
# envs/dev/imports.tf — temporary, deleted after the import is applied.
import {
  to = module.network.azurerm_resource_group.this
  id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aksplat-dev-weu"
}
```

```bash
terraform -chdir=envs/dev plan -generate-config-out=generated.tf   # optional: scaffold the HCL
terraform -chdir=envs/dev plan -out=tfplan                          # shows "1 to import"
terraform -chdir=envs/dev apply tfplan
```

This is strictly better than the CLI, for four reasons that all matter in a reviewed pipeline:

1. **It is plannable.** `terraform plan` shows exactly what will be imported *and* what changes
   Terraform intends to make to the imported resource afterwards. The CLI gives you none of
   that — you import, then run a plan and hope.
2. **It is reviewable.** The import appears as a diff in a pull request, runs through the same
   checkov/conftest gates, and is recorded in git history with the commit message explaining
   why.
3. **It is repeatable.** Anyone can re-run it; it is idempotent once applied.
4. **`-generate-config-out` writes the HCL for you**, which for a 40-attribute
   `azurerm_kubernetes_cluster` is the difference between ten minutes and an afternoon.

Delete `imports.tf` once applied. Leaving import blocks in place is harmless but noisy.

### The legacy way: `terraform import`

```bash
terraform -chdir=envs/dev import \
  'module.acr.azurerm_container_registry.this' \
  '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aksplat-dev-weu/providers/Microsoft.ContainerRegistry/registries/acraksplatdevweu'
```

Imperative, unreviewable, and it mutates state immediately with no plan step. Still occasionally
necessary — some resources do not support import blocks cleanly, and it is handy for a quick
one-off against dev. Treat it as a debugging tool, not a workflow.

### Finding Azure resource IDs

```bash
az resource list --resource-group rg-aksplat-dev-weu --query "[].{name:name,type:type,id:id}" -o json

# Role assignments and federated credentials have non-obvious ID formats:
az role assignment list --scope "<scope>" --query "[].id" -o tsv
# -> /subscriptions/.../providers/Microsoft.Authorization/roleAssignments/<assignment-guid>
```

---

## `moved {}` — refactoring without destroying

When a resource's **address in Terraform** changes but the underlying Azure object does not —
renaming a resource, wrapping resources in a module, switching `count` to `for_each` — Terraform
sees a removal and an addition. Without intervention it will **destroy and recreate** the
resource. On a Key Vault with purge protection, or an AKS cluster, that is a very bad afternoon.

`moved {}` blocks tell Terraform the two addresses are the same object:

```hcl
# Pulling a flat resource into a module.
moved {
  from = azurerm_log_analytics_workspace.this
  to   = module.observability.azurerm_log_analytics_workspace.this
}

# count -> for_each. Note the index type changes from number to string.
moved {
  from = module.network.azurerm_subnet.subnets[0]
  to   = module.network.azurerm_subnet.subnets["aks-system"]
}

# Renaming a module.
moved {
  from = module.monitoring
  to   = module.observability
}
```

`terraform plan` then reports:

```text
  # module.observability.azurerm_log_analytics_workspace.this has moved to a new address
  # (no changes)

Plan: 0 to add, 0 to change, 0 to destroy.
```

That `0 to destroy` is the entire point, and it is **visible in the PR plan comment** — which is
why `moved {}` is strictly better than `terraform state mv` for this job. The CLI equivalent
does the same thing invisibly, on someone's laptop, with no record.

Keep `moved {}` blocks for at least one release cycle so that anyone on an older state file gets
the benefit. They are inert once every state has moved, and can be deleted in a later cleanup
commit.

---

## `removed {}` — forgetting without destroying

Terraform 1.7+. Removes a resource from state **without destroying the real object**, declaratively.

```hcl
removed {
  from = module.observability.azurerm_application_insights.legacy

  lifecycle {
    destroy = false
  }
}
```

With `destroy = false`, Terraform drops the resource from state and leaves the Azure object
alone. With `destroy = true` (or omitted), it destroys it — which is just a normal deletion
expressed differently.

When this is the right tool:

- Handing a resource over to another team or another state file.
- Decommissioning a module while leaving the underlying resource alive during a transition.
- Dropping something that was imported by mistake.

Same argument as `moved {}`: a `removed {}` block is a reviewable diff and shows up in the plan,
whereas `terraform state rm` is an invisible act of surgery. Prefer the block.

> ⚠️ After a `removed {}` with `destroy = false`, the Azure resource is **unmanaged**. Nothing
> will patch it, nothing will tag it, nothing will notice if someone deletes it, and your cost
> reports will still show it. Record the handover somewhere a human will read.

---

## Recovering from a stuck lock

### The symptom

```text
│ Error: Error acquiring the state lock
│
│ Error message: state blob is already locked
│ Lock Info:
│   ID:        00000000-0000-0000-0000-000000000000
│   Path:      tfstate/dev/terraform.tfstate
│   Operation: OperationTypeApply
│   Who:       runner@fv-az1234-567
│   Version:   1.9.8
│   Created:   2026-01-14 09:41:22.11 +0000 UTC
```

### Before you do anything: is it actually stuck?

Breaking a live lock is how you corrupt a state file. Work through this in order.

1. **Is a CI job running right now?**
   ```bash
   gh run list --limit 15
   gh run list --workflow=terraform-apply.yml --limit 5
   ```
   If anything is `in_progress`, **wait**. The `Who` field in the lock info names the runner.
2. **Is a colleague running an apply?** Ask. The `Who` field gives you a hostname and username.
3. **How old is the lock?** Compare `Created` with now. A lock under ~15 minutes old during a
   prod apply is almost certainly live — an AKS cluster creation alone takes 10 minutes.
4. **Did a job get cancelled?** A cancelled GitHub Actions job is killed with SIGKILL after its
   grace period and does not always get to release the lease. This is the overwhelmingly common
   cause of a genuinely stuck lock.

**Safe to break:** the job that held it has definitively finished (completed, failed or
cancelled) and no other operation is running.

**Not safe to break:** you are impatient, or you are not sure. A broken lease during an in-flight
write produces a state file that does not match reality, and the next `apply` will do something
creative with your production cluster.

### Step 1 — `terraform force-unlock`

The correct first attempt. It releases the lease *and* deletes Terraform's `.tflock` metadata
blob, leaving the backend in a clean state.

```powershell
terraform -chdir=envs/dev force-unlock 00000000-0000-0000-0000-000000000000
```

```bash
terraform -chdir=envs/dev force-unlock 00000000-0000-0000-0000-000000000000
```

The ID is the `ID` field from the error message — which, for the azurerm backend, **is the blob
lease ID**. Terraform will ask for confirmation; read it.

### Step 2 — the Azure-specific path, when `force-unlock` cannot help

`force-unlock` needs the lock ID. If the `.tflock` blob was deleted, or the error does not
surface an ID, or `force-unlock` itself fails, break the lease directly at the storage layer:

```powershell
# Confirm there really is a lease, and what state it is in.
az storage blob show `
  --account-name sttfstateaksplatweu4f2a `
  --container-name tfstate `
  --name "dev/terraform.tfstate" `
  --auth-mode login `
  --query "properties.lease" -o json

# Break it. --lease-break-period 0 breaks immediately.
az storage blob lease break `
  --account-name sttfstateaksplatweu4f2a `
  --container-name tfstate `
  --blob-name "dev/terraform.tfstate" `
  --lease-break-period 0 `
  --auth-mode login

# Terraform's lock metadata blob may survive and confuse the next run. Remove it if present.
az storage blob delete `
  --account-name sttfstateaksplatweu4f2a `
  --container-name tfstate `
  --name "dev/terraform.tfstate.tflock" `
  --auth-mode login
```

```bash
az storage blob show \
  --account-name sttfstateaksplatweu4f2a --container-name tfstate \
  --name "dev/terraform.tfstate" --auth-mode login --query "properties.lease" -o json

az storage blob lease break \
  --account-name sttfstateaksplatweu4f2a --container-name tfstate \
  --blob-name "dev/terraform.tfstate" --lease-break-period 0 --auth-mode login

az storage blob delete \
  --account-name sttfstateaksplatweu4f2a --container-name tfstate \
  --name "dev/terraform.tfstate.tflock" --auth-mode login
```

> ⚠️ `az storage blob lease break` is a **storage-level** operation. It knows nothing about
> Terraform and performs none of Terraform's sanity checks. If the holder is mid-write, you have
> just permitted a concurrent writer. Use it only after `force-unlock` has failed and only after
> confirming the holder is dead.

### Step 3 — verify before you touch anything

```bash
terraform -chdir=envs/dev state pull > /tmp/verify.tfstate
jq '{version, terraform_version, serial, lineage, resources: (.resources | length)}' /tmp/verify.tfstate
terraform -chdir=envs/dev plan
```

A clean `plan` with no unexpected drift means the state survived. A plan that proposes to
recreate half the environment means the interrupted write damaged it — go to
[Recovering a corrupted or lost state file](#recovering-a-corrupted-or-lost-state-file).

### Preventing it

- `-lock-timeout=5m` everywhere, so transient contention self-resolves.
- `concurrency` groups in the workflows: plans use `cancel-in-progress: true` (safe — a plan
  writes nothing), applies use `cancel-in-progress: false` (**never cancel an apply**; that is
  exactly how you orphan a lease *and* leave infrastructure half-built). See
  [`terraform-plan.yml`](../.github/workflows/terraform-plan.yml).
- Separate state keys per environment, so contention is per-environment.

---

## Recovering a corrupted or lost state file

### Case 1 — a bad write, recover a previous version

```powershell
# 1. List versions, newest first, and identify the last good one by timestamp.
az storage blob list `
  --account-name sttfstateaksplatweu4f2a --container-name tfstate `
  --prefix "dev/terraform.tfstate" --include v --auth-mode login `
  --query "sort_by([].{version:versionId,current:isCurrentVersion,modified:properties.lastModified,bytes:properties.contentLength}, &modified)" -o table

# 2. Download the candidate and sanity-check it BEFORE restoring.
az storage blob download `
  --account-name sttfstateaksplatweu4f2a --container-name tfstate `
  --name "dev/terraform.tfstate" --version-id "2026-01-14T09:30:11.1234567Z" `
  --auth-mode login --file ./candidate.tfstate

jq '{serial, lineage, terraform_version, resources: (.resources|length)}' ./candidate.tfstate

# 3. Back up the current (broken) state so the recovery itself is reversible.
terraform -chdir=envs/dev state pull > ./broken.tfstate

# 4. Restore.
terraform -chdir=envs/dev state push ./candidate.tfstate

# 5. Verify.
terraform -chdir=envs/dev plan
```

Expect the restored plan to show *some* drift — any change applied after the restored version
will now be invisible to Terraform and will be re-proposed. Read that plan with real care. It is
the one plan where "looks about right" is not good enough.

A note on `lineage` and `serial`: `lineage` is a GUID identifying the state's history, and
`serial` increments on every write. `state push` refuses a file whose lineage differs or whose
serial is not higher, which protects you from pushing an unrelated state. If you are restoring an
older version of the *same* state, the serial will be lower and you will need `-force`. That is
one of the few legitimate uses of `-force` — and it is still worth a second pair of eyes.

### Case 2 — the state blob was deleted

Soft delete retains it for 30 days:

```bash
az storage blob undelete \
  --account-name sttfstateaksplatweu4f2a \
  --container-name tfstate \
  --name "dev/terraform.tfstate" \
  --auth-mode login
```

If the whole container went:

```bash
az storage container restore \
  --account-name sttfstateaksplatweu4f2a \
  --name tfstate \
  --deleted-version "<deleted-version-id>" \
  --auth-mode login
```

### Case 3 — state is gone for good

The infrastructure still exists; Terraform just cannot see it. Rebuild state by importing.

1. `terraform init -reconfigure -backend-config=backend.hcl` against an empty blob.
2. Enumerate what is actually there:
   ```bash
   az resource list --resource-group rg-aksplat-dev-weu --query "[].{name:name,type:type,id:id}" -o json > inventory.json
   ```
3. Write `import {}` blocks for each, lowest-dependency first (resource group, VNet, subnets,
   workspace, ACR, Key Vault, cluster, node pools, identities, role assignments).
4. `terraform plan` repeatedly until it reports `0 to add, 0 to destroy`. Non-zero changes mean
   your HCL and reality disagree; resolve each one deliberately.
5. Delete the import blocks.

For dev, this is usually not worth it: `terraform destroy` is impossible without state, so
delete the resource groups by hand and re-apply from scratch. Budget **half a day** for a full
prod state reconstruction, and treat the exercise as a strong argument for the versioning
settings above.

### Case 4 — the bootstrap state is lost

`bootstrap/` uses local state, so a lost laptop loses it. The resources (state storage account,
Entra app, federated credentials, role assignments) all still exist and all support import. Run
the same import procedure against `bootstrap/`. Nothing in the environments is affected — they
talk to the storage account directly and neither knows nor cares what manages it.

---

## State size and performance

| Environment | Resources | State size | `plan` (warm) |
|---|---|---|---|
| dev | ~41 | ~300–450 KB | 45–90 s |
| staging | ~48 | ~400–550 KB | 60–110 s |
| prod | ~55 | ~500–700 KB | 90–150 s |

Plan time is dominated by **refresh**, not by state parsing. Terraform issues at least one ARM
read per managed resource; ARM latency and throttling, not file size, set the pace.

Levers, in the order you should reach for them:

| Lever | Effect | Caveat |
|---|---|---|
| `-parallelism=N` (default 10) | More concurrent ARM calls | Raising it invites 429 throttling; lowering it to 5 sometimes makes a throttled plan *faster* overall |
| `-refresh=false` | Skips the refresh entirely; plan completes in seconds | Plans against possibly-stale state. Fine for a quick syntax sanity check, **never** for an apply you intend to trust |
| `-target=module.aks` | Refreshes a subgraph only | A targeted plan is an incomplete plan. Debugging only; never in CI |
| Split into layers | Smaller graphs | See [State isolation](#state-isolation) — not worth it at this size |

State becomes a genuine problem somewhere around 2,000+ resources, where plan times run into
many minutes and the file reaches tens of megabytes. At that point the fix is decomposition, not
tuning. We are two orders of magnitude away.

---

## Secrets in state

**Terraform state contains secrets in plaintext.** Not encrypted, not hashed, not redacted —
plain JSON. `sensitive = true` only suppresses CLI *output*; it changes nothing about what is
written to the file.

### What is actually in this platform's state

| Value | Where it comes from | Severity |
|---|---|---|
| Kubernetes admin/user `kube_config` blocks, including client certificates and the cluster CA key material | `azurerm_kubernetes_cluster` | **Critical** — direct cluster access |
| Any `azurerm_key_vault_secret` value the stack manages | Key Vault resources | **Critical** |
| `random_password` / `random_string` results | `random` provider | High |
| ACR admin credentials | Would appear if `admin_enabled = true` — **it is `false` everywhere**, so they do not | n/a |
| Managed identity client IDs, principal IDs, tenant ID, subscription ID | Everywhere | Low (identifiers, not credentials) |
| Full network topology: CIDRs, subnet names, NSG rules, private endpoint IPs | `network` module | Medium — excellent reconnaissance material |
| Resource IDs for every object in the environment | Everywhere | Medium |

`local_account_disabled = true` materially reduces the first row's impact: the static admin
kubeconfig is not issued at all, so there is less certificate material in state than on a
default cluster. It does not eliminate it.

### The mitigations actually in place

1. **RBAC-only data-plane access.** `Storage Blob Data Contributor` on the container, nothing
   else. Every access is an Entra identity and lands in the Entra sign-in log.
2. **`shared_access_key_enabled = false`.** No account key exists, so there is no key to leak in
   a CI secret, a `.env`, a Slack message or a Terraform file. This removes the single most
   common way state gets exfiltrated.
3. **Encryption at rest** with Microsoft-managed keys, plus
   `infrastructure_encryption_enabled = true`.
4. **TLS 1.2 minimum, no anonymous access, no public blobs.**
5. **Storage diagnostic logs → Log Analytics**, so `StorageBlobLogs` records every read of a
   state blob with the caller's identity.
6. **State is never committed.** `.gitignore` plus the gitleaks job in
   [`security.yml`](../.github/workflows/security.yml).
7. **Plan artifacts have a 5-day retention** and are never pasted verbatim into a PR comment —
   a plan file contains much of what state contains. See
   [`terraform-plan.yml`](../.github/workflows/terraform-plan.yml).

### Who can read state, and what they get

| Principal | Access | Effective capability |
|---|---|---|
| GitHub Actions CI service principal | `Storage Blob Data Contributor` on the container | Read and write all three environments' state |
| Platform operators (me) | Same | Same |
| An auditor (not granted today) | `Storage Blob Data Reader` would be appropriate | Read-only; `plan` works, `apply` fails |
| Everyone else | None | Nothing — no key, no anonymous access |

Be clear-eyed about the consequence: **anyone who can read prod state can read prod's secrets.**
Read access to the state container is equivalent to a high-privilege grant on the environment,
and should be reviewed with that in mind rather than filed under "storage permissions".

### What would make this materially better

- **Separate storage accounts per environment**, so dev operators cannot read prod state. Today
  one account with one container holds all three keys, and container-level RBAC does not
  distinguish between blobs. This is the most valuable single improvement available and is
  called out in [security.md](./security.md#what-i-would-add-next).
- **Customer-managed keys (CMK)** on the state account, so key revocation renders state
  unreadable.
- **Private endpoint** on the state account plus VNet-integrated runners.
- **Keep secrets out of state in the first place** — the strongest mitigation. This platform
  already does it where it matters: no secret *values* are declared in Terraform. Key Vault
  secrets are written out-of-band and read by pods through the CSI driver, so the secret never
  passes through Terraform at all. Every `azurerm_key_vault_secret` resource you add is a
  plaintext secret you have chosen to store in state.
- **Ephemeral resources and write-only arguments** (Terraform 1.10/1.11+) now allow some values
  to be used during apply without being persisted to state. Adopting them where the azurerm
  provider supports them is open follow-up work.

---

## Operational checklist

Before any state surgery:

- [ ] `terraform state pull > backup-$(date +%Y%m%d-%H%M).tfstate`
- [ ] Confirm which environment you are in — `terraform -chdir=...` or `pwd`, not memory
- [ ] Confirm no CI run is in flight: `gh run list --limit 10`
- [ ] Prefer a `moved {}` / `removed {}` / `import {}` block in a PR over a CLI command
- [ ] If it must be the CLI, have a second person watching for anything touching prod

Before breaking a lock:

- [ ] Identify the holder from the `Who` field
- [ ] Confirm the holding job has finished
- [ ] Try `terraform force-unlock <ID>` first
- [ ] Only then `az storage blob lease break`
- [ ] `terraform plan` afterwards and read it properly

Routine hygiene:

- [ ] Blob versioning enabled — verify quarterly, it is easy to lose in a storage refactor
- [ ] Soft delete retention ≥ 30 days on blobs and containers
- [ ] `shared_access_key_enabled = false` still false
- [ ] Review who holds `Storage Blob Data Contributor` on the container
- [ ] A lifecycle policy prunes state versions older than 90 days, so versioning does not grow
      unbounded

---

## See also

- [architecture.md](./architecture.md) — what the state describes
- [getting-started.md](./getting-started.md) — creating the backend for the first time
- [security.md](./security.md) — the full threat model, including state as an asset
- [ADR-0001: directory per environment](./decisions/0001-directory-per-environment.md) — why
  three state files instead of three workspaces
- [`terraform-plan.yml`](../.github/workflows/terraform-plan.yml) — how CI configures the backend

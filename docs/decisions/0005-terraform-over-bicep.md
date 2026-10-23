# 0005 — Terraform over Bicep/ARM for this platform

## Status

Accepted

## Context

Every resource in this platform could equally well be expressed in Bicep, Microsoft's first-party
Azure-native IaC language, which compiles down to ARM templates and is deployed by the Azure CLI or
Azure DevOps/GitHub Actions tasks with no separate state backend to manage at all. Bicep is a
legitimate, well-supported, improving choice, and it is worth being honest about where it is
genuinely better suited than what this repository uses.

**In Bicep's favour, stated plainly:**

- **No state file to manage.** ARM is itself the source of truth for what exists; there is no
  `terraform.tfstate` to back up, lock, recover from corruption, or migrate between backends. An
  entire category of this platform's own documentation —
  [state-management.md](../state-management.md), with its sections on blob leases, stuck-lock
  recovery and corrupted-state recovery — simply does not exist as a problem in Bicep.
- **First-party, same-day Azure support.** New ARM API properties and preview features land in
  Bicep immediately, because it is maintained by the same organization that ships the APIs. A
  Terraform provider (`azurerm`) is a third-party abstraction maintained by HashiCorp (with
  Microsoft contribution) that necessarily lags, occasionally in ways visible in this very
  repository — the `azurerm` v3→v4 argument renames referenced throughout
  [`policy/README.md`'s contract reference](../../policy/README.md#7-contract-reference) are exactly
  the kind of friction a provider abstraction layer introduces that a native tool does not.
- **No provider version pinning or lock file to reason about** — Bicep's "provider" is simply the
  ARM API version declared per resource.

None of that is a strawman; it is a fair accounting of what this repository gives up by choosing
Terraform.

## Decision

Use Terraform, for reasons that outweigh the above specifically for a **portfolio platform
demonstrating transferable DevOps skill**, which is a different optimization target than "the best
tool for an Azure-only team that will never touch another cloud."

1. **Skill transferability.** Terraform's HCL, state model, module system and plan/apply workflow
   are identical in shape whether the provider is `azurerm`, `aws`, `google`, or a dozen others. The
   patterns demonstrated here — directory-per-environment state isolation
   ([ADR-0001](./0001-directory-per-environment.md)), `moved`/`removed` block refactoring, remote
   state with native locking — are the same patterns a hiring team evaluating this repository would
   expect to see reused on their own (possibly multi-cloud, possibly non-Azure) estate. Bicep
   expertise, by design, does not transfer past Azure at all.
2. **A mature state and plan model.** `terraform plan` produces a concrete, inspectable diff of
   additions, changes and deletions *before* anything is touched, and that diff can be serialized to
   JSON and evaluated by a policy engine — which is exactly what this platform's Conftest gate does
   (see below). `az deployment what-if` exists for Bicep and has improved substantially, but it is a
   newer, less battle-tested feature than Terraform's plan model, and critically, it does not
   produce the same structured, stable JSON schema that policy-as-code tooling has standardized
   around.
3. **A mature module ecosystem and explicit versioning.** The Terraform Registry gives every module
   and provider an explicit, pinned version constraint, and this platform leans on that directly —
   `modules/*` in this repository, and third-party modules it could later adopt, are versioned the
   same way regardless of cloud. Bicep's module registry story (public/private registries,
   `br:` references) is real but younger and less standardized across the ecosystem.
4. **Policy-as-code tooling is Terraform-plan-JSON-centric.** Conftest, evaluating
   `terraform show -json tfplan`, is the entire basis of this platform's Layer 1 policy gate — see
   [policy/README.md](../../policy/README.md) and
   [architecture.md — design principle #6](../architecture.md#design-principles): "Policy is
   enforced on the plan, not on the HCL... Conftest evaluates `terraform show -json tfplan`, so it
   can see computed values and planned deletions that a static HCL scanner cannot." The equivalent
   Bicep story (evaluating an ARM what-if result or a compiled template with OPA) is far less
   established, has a less stable schema to write rules against, and would mean building and
   maintaining the plan-JSON tooling this platform gets for free with Terraform.

## Consequences

**What this buys:**

- Every pattern in this repository — state isolation, policy-on-plan, OIDC-federated CI
  authentication via the Terraform `azurerm`/`azuread` providers — is demonstrably reusable on a
  different cloud with the same mental model and much of the same CI scaffolding, which is the
  explicit point of a portfolio repository meant to show transferable skill rather than
  Azure-specific tooling fluency alone.
- The Conftest policy gate, arguably the most distinctive piece of engineering in this repository
  (see [policy/README.md](../../policy/README.md)), exists in its current form specifically because
  Terraform's plan-JSON output is a stable, well-understood target for OPA/Rego. Rebuilding that
  gate against Bicep's what-if output would be materially more work for a less mature result today.
- `moved {}` and `removed {}` blocks ([state-management.md](../state-management.md)) give an
  explicit, reviewable mechanism for refactoring resource addresses without a destroy/recreate —
  a capability Bicep is still catching up to.

**What this costs:**

- This platform now owns a state file, with everything that entails: the backend configuration in
  [state-management.md](../state-management.md), the blob-lease locking mechanism, the Entra-ID
  (not storage-key) authentication to the state container set up in
  [`bootstrap/github-oidc.tf`](../../bootstrap/github-oidc.tf), and a documented recovery procedure
  for a stuck lock or a corrupted state file. None of that exists as a category of problem in Bicep.
- The `azurerm` and `azuread` providers occasionally lag new Azure features by weeks to months
  relative to ARM/Bicep, and their own breaking changes (the v3→v4 argument renames this platform's
  Conftest rules explicitly guard against, per
  [policy/README.md §7](../../policy/README.md#7-contract-reference)) are a maintenance cost Bicep
  does not impose, because Bicep has no comparable "provider" abstraction to version at all.
- A team that is Azure-only, today and for the foreseeable future, and that has no plan-time policy
  requirement beyond what Azure Policy's `DeployIfNotExists`/`Deny` already covers, would reasonably
  choose Bicep instead and lose nothing that matters to them. This decision is made for this
  platform's stated goals — portfolio demonstration of transferable skill plus a plan-time policy
  gate — not as a universal claim that Terraform is strictly better than Bicep on Azure.

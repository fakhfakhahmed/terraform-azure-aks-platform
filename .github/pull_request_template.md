<!--
  terraform-azure-aks-platform - pull request template

  This template exists because infrastructure review is different from
  application review: the diff is not the change. The *plan* is the change.
  A three-line edit can replace a node pool and take a cluster offline, and a
  fifty-line refactor can be a true no-op. Fill the plan review checklist
  honestly - it is the part a reviewer actually relies on.

  Delete sections that genuinely do not apply, but say so rather than leaving
  them blank.
-->

## Summary

<!-- What does this change do, and why is it needed? Lead with the user- or
     operator-visible outcome, not the implementation. One paragraph. -->

**What:**

**Why:**

**Related issue(s):** <!-- Closes #123 / Relates to #456 / none -->

---

## Type of change

<!-- Tick everything that applies. -->

- [ ] New infrastructure (resources are **created**)
- [ ] Modification of existing infrastructure (resources are **updated in place**)
- [ ] Destructive change (resources are **replaced or destroyed**)
- [ ] Module refactor (no planned change - plan should be a no-op)
- [ ] CI/CD pipeline change (`.github/workflows/**`)
- [ ] Policy-as-code change (`policy/**`)
- [ ] Documentation only
- [ ] Dependency / provider version bump
- [ ] Bug fix
- [ ] Breaking change (requires coordination, a migration, or downtime)

---

## Environments affected

<!-- Tick every environment whose plan is non-empty after this change.
     A change under modules/** or policy/** affects ALL of them - the plan
     workflow fans out automatically, so check all three. -->

- [ ] `dev`
- [ ] `staging`
- [ ] `prod`
- [ ] `bootstrap` (state backend / OIDC identity - handle with care)
- [ ] None (docs, CI, or policy-only change with no plan impact)

**Rollout order intended:** <!-- e.g. dev -> soak 24h -> staging -> prod -->

---

## Terraform plan review checklist

<!-- Every box here maps to a way infrastructure PRs have historically gone
     wrong. If you cannot tick one, explain underneath it instead of leaving
     it unticked and silent. -->

- [ ] **Destroys reviewed.** I have read every `# ... will be destroyed` and
      `# ... must be replaced` line in the plan and each one is intended.
      <!-- Count them: ______ destroyed, ______ replaced. -->
- [ ] **No `-target` was used.** The plan in the PR comment is a full plan.
      Targeted applies leave state partially converged and hide the real diff.
- [ ] **No local state, no manual `terraform` runs against shared backends.**
      Everything in this PR goes through CI against the remote azurerm backend.
- [ ] **State-affecting operations are called out below.** `moved` blocks,
      `import` blocks, `terraform state mv/rm`, provider major upgrades,
      backend key changes - each is named explicitly in the Summary.
- [ ] **Naming and tagging conform.** New resources go through the `naming`
      module and inherit the standard tag set (owner, environment, cost centre,
      managed-by). No hand-rolled resource names.
- [ ] **Cost impact considered** and recorded in the Cost impact section below
      (SKU changes, node count, node size, retention periods, zone redundancy,
      public IPs, egress).
- [ ] **No secrets in the plan output.** I checked the posted plan comment for
      keys, connection strings, kubeconfigs and passwords. Any value that could
      leak is marked `sensitive = true` at its source.
- [ ] **`prevent_destroy` resources untouched.** Nothing with
      `lifecycle { prevent_destroy = true }` (state storage, Key Vault, ACR,
      production resource groups) appears in the destroy/replace set.
- [ ] **Policy gates are green.** Checkov, TFLint, Conftest/OPA and the Trivy
      config scan all pass. Any new suppression is justified inline with a
      comment and a reason, not a blanket skip.
- [ ] **Idempotency checked.** A second plan after this change applies would be
      empty (no perpetual diff introduced).
- [ ] **Module docs regenerated** if `modules/**` changed (the docs workflow
      pushes this automatically for same-repo PRs).

**State-affecting operations in this PR:**

<!-- e.g. "moved block relocating module.aks.azurerm_kubernetes_cluster.this
     after renaming the module; no resource is recreated." or "none" -->

---

## Security considerations

<!-- Answer briefly even when the answer is "no change". -->

- **Network exposure:** <!-- new public IP / NSG rule / public API server endpoint? -->
- **Identity & RBAC:** <!-- new role assignment? scope? is it least privilege? -->
- **Secrets handling:** <!-- Key Vault references, workload identity, no secrets in tfvars -->
- **Data protection:** <!-- encryption at rest, CMK, soft delete / purge protection -->
- **Audit & logging:** <!-- diagnostic settings wired to Log Analytics? -->
- **New Checkov / Conftest suppressions:** <!-- list each one with its justification, or "none" -->

---

## Cost impact

<!-- Be specific. "Slight increase" is not a review input; "+1 Standard_D4s_v5
     node in staging, ~EUR 110/month" is. -->

| Change | Resource / SKU | Estimated monthly delta |
| --- | --- | --- |
|  |  |  |

- [ ] This change **increases** recurring cost — delta estimated above
- [ ] This change **decreases** recurring cost
- [ ] This change is **cost neutral**
- [ ] One-off cost only (e.g. data migration egress)

**Notes:** <!-- autoscaling bounds, spot vs on-demand, log retention, reserved capacity -->

---

## Rollback plan

<!-- "Revert the PR" is only a valid answer when reverting is actually safe.
     It is NOT safe when the change destroys a stateful resource, changes a
     backend key, or performs a state move - say so and give the real plan. -->

- [ ] Reverting this PR and re-applying restores the previous state safely
- [ ] Rollback requires additional steps (described below)
- [ ] Rollback is **not** possible without data loss (explain, and justify why
      this is acceptable)

**Procedure:**

1.
2.

**Estimated time to restore service:**

---

## Plan output / screenshots

<!-- The plan is posted automatically as a sticky PR comment by
     .github/workflows/terraform-plan.yml, one per affected environment.
     Use this space only for things the plan cannot show: portal screenshots,
     Grafana panels, `kubectl` output, architecture diagrams, before/after. -->

<details>
<summary>Supporting evidence</summary>

</details>

---

## Reviewer checklist

<!-- For the reviewer, not the author. Do not tick these yourself. -->

- [ ] The plan output in the PR comment matches what the Summary claims
- [ ] Destroy / replace operations are genuinely intended and safe for the
      target environment
- [ ] Naming, tagging and module boundaries follow repository conventions
- [ ] Security posture is unchanged or improved; suppressions are justified
- [ ] Cost impact is understood and proportionate to the benefit
- [ ] The rollback plan is credible for the resources involved
- [ ] All required status checks are green (fmt, init, validate, tflint,
      checkov, plan, conftest)
- [ ] If `prod` is affected: I understand the apply is manual
      (`workflow_dispatch` only) and I am prepared to approve the deployment
      in the `prod` GitHub Environment at an agreed time

---

> **Reminder:** merging this PR does **not** deploy to production.
> `terraform-apply.yml` applies to `dev` automatically on merge; `staging` and
> `prod` require a manual `workflow_dispatch` plus approval in the
> corresponding GitHub Environment.

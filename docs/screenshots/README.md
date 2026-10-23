# Screenshots

Placeholders for the screenshots this repository should carry once it has actually been deployed
against a live Azure subscription — for the root README's architecture/screenshots section and for
the LinkedIn post introducing this project. **None of these exist yet.** Capture them in order,
after a real `terraform apply` and at least one PR through the full CI pipeline, then drop the image
files directly into this directory using the filenames below and reference them from the root
[README](../../README.md) (either under the existing "Architecture" section or a new "Screenshots"
section).

| Filename | What to capture | Why it's compelling |
|---|---|---|
| `pr-plan-comment.png` | A GitHub pull request showing the automated `terraform plan` comment posted by CI — the full add/change/destroy summary, ideally with at least one planned change visible in the diff. | This is the single screenshot that proves the pipeline, not just the Terraform, works: a reviewer can see exactly what a change does before approving it, with no local `terraform plan` required. It is the first thing a technical reviewer looks for in an IaC portfolio project. |
| `checkov-gate.png` | The Checkov security-gate check on a pull request — capture it both passing (green, on a clean PR) and, if possible, a second shot of it failing on a deliberately introduced violation with the specific finding visible. | Shows the policy-as-code story is real and enforced, not aspirational — a failing check with a named, specific rule (e.g. a missing `local_account_disabled`) is far more convincing than a green checkmark alone. Pairs with the Layer 1/Layer 2 story in [`policy/README.md`](../../policy/README.md). |
| `azure-portal-resource-group.png` | The deployed resource group for one environment (dev is fine) in the Azure Portal, with the resource list expanded enough to show the AKS cluster, VNet, NAT Gateway, Key Vault, ACR and Log Analytics workspace together — ideally the Portal's own resource-group "Resources" view or its topology/diagram view if available. | Proves the architecture diagram in [architecture.md](../architecture.md) corresponds to something real, not just a Mermaid diagram. A hiring manager skimming a portfolio repo trusts a live-portal screenshot more than any amount of documentation. |
| `kubectl-get-nodes.png` | Terminal output of `kubectl get nodes -o wide` against the live AKS cluster, captured right after a `kubelogin`-brokered Azure RBAC sign-in is visible in the same terminal scrollback (the browser device-code or interactive login prompt, or at least the `kubelogin convert-kubeconfig` step). | Demonstrates `local_account_disabled = true` and Azure RBAC for Kubernetes are not just Terraform arguments but an actual, working authentication flow — see [security.md — Azure RBAC for Kubernetes vs. local accounts](../security.md#azure-rbac-for-kubernetes-vs-local-accounts). |
| `drift-detection-issue.png` | A GitHub issue auto-filed by the scheduled drift-detection workflow, showing a real detected diff between live Azure state and the Terraform configuration (a manual portal change made deliberately for the demo is the easiest way to produce one safely in dev). | This is the screenshot most portfolio repositories cannot show, because most never run drift detection at all. It demonstrates the platform catches configuration drift continuously, not only at `apply` time — directly supporting the "Azure Policy is the continuous layer" argument in [security.md — CI security gates](../security.md#ci-security-gates). |

## Capturing these

- Take them against **dev**, not prod — nothing here needs prod-scale data, and dev is cheap to
  spin up and tear down for exactly this purpose (see [cost.md](../cost.md)).
- Redact or crop out the subscription ID, tenant ID and any personal GitHub notification content
  before publishing — none of those need to be visible for the screenshot to make its point.
- Once captured, add each image to this directory (`docs/screenshots/`) and link it from the root
  [README.md](../../README.md), either inline under the existing "Architecture" section or under a
  new "Screenshots" section — whichever reads better once the images actually exist.

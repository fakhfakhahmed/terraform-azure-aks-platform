# Policy as Code

Guardrails for `terraform-azure-aks-platform`. This directory holds **two independent
enforcement layers**, both preventive, deliberately overlapping, and deployed from the
same repository.

```
policy/
├── conftest/
│   ├── terraform.rego        # OPA/Rego rules evaluated against the Terraform plan JSON
│   └── terraform_test.rego   # unit tests for those rules (conftest verify / opa test)
├── azure-policy/
│   ├── require-tags.json              # custom definition: required tag set
│   ├── restrict-vm-skus.json          # custom definition: approved VM / node pool SKUs
│   ├── deny-aks-public-nodes.json     # custom definition: AKS baseline posture
│   └── assignment-example.json        # example policy assignment (ARM shaped)
└── README.md
```

---

## 1. Why two layers

| | Layer 1 — plan time | Layer 2 — platform |
|---|---|---|
| **Tooling** | conftest / OPA (this repo) + checkov | Azure Policy |
| **Where it runs** | GitHub Actions, on the pull request | Azure Resource Manager, on every write |
| **What it sees** | the Terraform plan for *this* change | every ARM request, from any source |
| **When it fires** | before anything is created | at create/update time |
| **Feedback loop** | seconds, inline on the PR | minutes, as a deployment error or a compliance finding |
| **Cost** | zero — no Azure subscription touched | zero marginal, built into ARM |
| **Blind spot** | anything not created by this Terraform | anything that is not an ARM-modelled property |

### Layer 1 — preventive at plan time (`policy/conftest`)

`terraform show -json tfplan` renders the whole diff as structured JSON. OPA evaluates
the rules in `terraform.rego` against that document and conftest exits non-zero on any
`deny`. The developer sees the failure **on the pull request, before an apply ever
happens** — no subscription is touched, no resource is created and rolled back, no
partial apply has to be cleaned up by hand.

This is the fastest and cheapest place to catch a mistake, and it is the only place
where the error message can name the exact Terraform address
(`module.aks.azurerm_kubernetes_cluster.this`) and the exact argument to change. That
is why every message in `terraform.rego` carries the address *and* the remediation.

Checkov runs alongside conftest in the same job. The two are complementary, not
redundant: checkov brings a large, maintained library of generic CIS/NIST-aligned
checks that nobody on this team has to write or update, while the Rego rules encode
the parts that are specific to **this** platform — our tag contract, our naming
convention, our documented dev exception. Generic scanners cannot know that
`cost_center` is mandatory here.

### Layer 2 — preventive at the platform (`policy/azure-policy`)

Azure Policy is evaluated by Azure Resource Manager itself. It does not care how the
request arrived: the portal, `az cli`, a Bicep deployment, an ARM template, the Azure
SDK, a pipeline in another repository, or a human with Contributor and a deadline. A
`Deny` effect rejects the request at the API boundary.

### Why you want both

Conftest only sees **what Terraform plans**. It is blind to:

- resources created by hand in the portal during an incident and never imported;
- another team's pipeline deploying into the same subscription;
- an apply run from a laptop with `-target` or with the policy step skipped;
- drift introduced by an Azure service that mutates a resource after creation.

Azure Policy catches all of those, but it has blind spots of its own: it cannot reason
about the shape of your Terraform code, it cannot give feedback before the apply, and
its `Deny` surfaces as an opaque ARM error halfway through a run that has already
created six other resources — leaving state and reality out of sync.

Each layer covers the other's gap. The overlap is a feature, not duplication:
`deny-aks-public-nodes.json` is the platform-side mirror of conftest rules 2, 3 and 9
on purpose.

---

## 2. Implemented conftest rules

Package `main`, Rego v1 syntax (`import rego.v1`), evaluated against the plan JSON.

All rules are scoped by `created_or_updated(rc)`, which only considers resource changes
that are **managed** (not `data` sources) and whose actions include `create` or
`update`. A pure `delete` removes risk; a `no-op` means the PR does not touch the
resource. Failing a PR over a pre-existing, untouched resource is the single fastest
way to get a policy gate disabled — that is the detective layer's job (Azure Policy
compliance state), not the gate's.

### Blocking rules (`deny` — CI fails)

| # | Rule | Resource / argument | Rationale |
|---|------|---------------------|-----------|
| D1 | No anonymous blob access | `azurerm_storage_account.allow_nested_items_to_be_public` | Account-level kill switch for public containers. Without it, anyone with data-plane rights can turn the account into an open bucket. |
| D2 | Workload Identity required | `azurerm_kubernetes_cluster.workload_identity_enabled` | The alternative is every pod on a node sharing the kubelet identity — a ready-made lateral-movement primitive. |
| D3 | OIDC issuer required | `azurerm_kubernetes_cluster.oidc_issuer_enabled` | Workload Identity federation is built on this issuer; `workload_identity_enabled` without it is rejected by the API. Asserted separately so the message is precise. |
| D4 | Local admin accounts disabled | `azurerm_kubernetes_cluster.local_account_disabled` | The admin client certificate bypasses Entra ID entirely: no MFA, no conditional access, no per-user audit, and no revocation short of rotating the cluster CA. |
| D5 | Required tags present and non-blank | `tags` on every taggable `azurerm_*` resource | `environment`, `project`, `owner`, `managed_by`, `cost_center`. Drives chargeback, incident ownership and drift triage. Blank values are treated as missing. |
| D6 | ACR admin user disabled | `azurerm_container_registry.admin_enabled` | A single shared push credential that cannot be scoped or attributed, and that reliably ends up in an `imagePullSecret` and then in git. |
| D7 | No internet → SSH/RDP (standalone rule) | `azurerm_network_security_rule` | Inbound + Allow + internet source + a destination port spec covering 22 or 3389. |
| D8 | No internet → SSH/RDP (inline block) | `azurerm_network_security_group.security_rule[*]` | Same logic for the inline form of the rule, which generic scanners frequently miss. |
| D9 | Key Vault purge protection | `azurerm_key_vault.purge_protection_enabled` | Without it, a single compromised Contributor can delete **and** purge a vault, destroying the key material that encrypts downstream data. **Exempt when `environment = dev`** — see §5. |
| D10 | TLS 1.2 floor | `azurerm_storage_account.min_tls_version` | TLS 1.0/1.1 are deprecated and fail every compliance baseline. `TLS1_3` is also accepted. |
| D11 | HTTPS only | `azurerm_storage_account.https_traffic_only_enabled` | No credentials or payloads in the clear. Doubles as an azurerm v3→v4 migration guard (the argument was `enable_https_traffic_only` in v3). |
| D12 | No public IPs on node pools | `azurerm_kubernetes_cluster_node_pool.node_public_ip_enabled` | A node with a public IP puts the kubelet, the container runtime and every `hostNetwork` pod on the internet behind nothing but an NSG. |
| D13 | No public IPs on the default pool | `azurerm_kubernetes_cluster.default_node_pool[*].node_public_ip_enabled` | Same control, applied to the inline default pool. |

### Advisory rules (`warn` — reported, CI still passes)

| # | Rule | Condition | Rationale |
|---|------|-----------|-----------|
| W1 | Storage reachable from the internet | `public_network_access_enabled = true` | Sometimes legitimate (static sites, public artifact mirrors, remote state read by hosted runners). Warn so the choice is visible in the PR and can be paired with `network_rules`. |
| W2 | AKS on the Free SKU tier | `sku_tier = "Free"` and `environment != dev` | Free has no control-plane SLA and a lower API-server scale ceiling. Fine for dev, wrong for anything with an on-call rotation. |
| W3 | ACR not Premium with private networking | `sku != "Premium"` and (ACR public access off **or** the plan declares a private endpoint) | Private endpoints, CMK, geo-replication, content trust and scoped tokens are Premium-only. Basic/Standard fails at apply time. |
| W4 | Public AKS API server | `private_cluster_enabled != true` and `environment != dev` | Survivable when paired with `authorized_ip_ranges`, which is why it is advisory — but a private cluster is the target state for staging and prod. |
| W5 | Key Vault on access policies | neither `rbac_authorization_enabled` nor `enable_rbac_authorization` is true | Access policies are vault-scoped, not role-scoped: no PIM, no deny assignments, not visible in the Azure RBAC graph. Both argument spellings are accepted because azurerm renamed it mid-4.x. |

### Design notes

- **Fail closed on booleans.** `attr_bool` treats absent and `null` as `false`. For a
  security control, "never configured" and "explicitly disabled" carry identical risk.
- **The port-range helper is the centrepiece.** `port_spec_covers/2` handles all three
  shapes Azure accepts — `"22"`, `"*"` and `"20-30"` — and `destination_port_specs/1`
  reads both the singular `destination_port_range` and the plural
  `destination_port_ranges`. Source matching covers `source_address_prefix` and
  `source_address_prefixes[]`, and accepts `*`, `0.0.0.0/0`, `::/0`, the `Internet`
  service tag and `Any`, case-insensitively. Getting this wrong in either direction is
  expensive: too loose ships an SSH hole, too strict fails every port-443 ingress rule.
- **Untaggable resources are skipped explicitly.** `untaggable_types` is a documented
  list of types with no `tags` property in ARM (`azurerm_role_assignment`,
  `azurerm_federated_identity_credential`, `azurerm_subnet`,
  `azurerm_network_security_rule`, …). It is backed by a schema-driven safety net,
  `schema_has_tags`, that skips any resource whose plan projection has no `tags` key at
  all. Note that `azurerm_private_dns_zone_virtual_network_link` and
  `azurerm_kubernetes_cluster_node_pool` **are** taggable and are deliberately absent
  from the list — a common false assumption. Non-`azurerm_` providers (`random_*`,
  `tls_*`, `time_*`) are skipped wholesale.

---

## 3. Running it locally

### Install conftest on Windows

```powershell
winget install --id OpenPolicyAgent.Conftest -e
# or
choco install conftest
# or
scoop install conftest
```

macOS / Linux:

```bash
brew install conftest
# or
curl -sSL https://github.com/open-policy-agent/conftest/releases/latest/download/conftest_Linux_x86_64.tar.gz | tar xz conftest && sudo mv conftest /usr/local/bin/
```

### Evaluate a plan

PowerShell, from an environment directory (`envs/dev`, `envs/staging`, `envs/prod`):

```powershell
cd envs/dev
terraform init
terraform plan -out=tfplan
terraform show -json tfplan > tfplan.json

conftest test --policy ../../policy/conftest tfplan.json
```

bash / zsh:

```bash
cd envs/dev
terraform init
terraform plan -out=tfplan
terraform show -json tfplan > tfplan.json

conftest test --policy ../../policy/conftest tfplan.json
```

Useful flags:

```bash
# Treat warnings as failures too (what you want in a pre-merge gate on prod).
conftest test --policy ../../policy/conftest --fail-on-warn tfplan.json

# Machine-readable output for a PR comment or a job summary.
conftest test --policy ../../policy/conftest --output json tfplan.json

# Show the full trace of a failing rule while developing it.
conftest test --policy ../../policy/conftest --trace tfplan.json
```

### Run the unit tests

```powershell
conftest verify --policy policy/conftest
```

```bash
conftest verify --policy policy/conftest
```

Or with a bare OPA binary, which gives nicer per-test output:

```bash
opa test policy/conftest -v
```

### Docker fallback (no local install)

PowerShell:

```powershell
docker run --rm -v "${PWD}:/project" openpolicyagent/conftest test --policy policy/conftest envs/dev/tfplan.json
docker run --rm -v "${PWD}:/project" openpolicyagent/conftest verify --policy policy/conftest
```

bash:

```bash
docker run --rm -v "$PWD:/project" openpolicyagent/conftest test --policy policy/conftest envs/dev/tfplan.json
docker run --rm -v "$PWD:/project" openpolicyagent/conftest verify --policy policy/conftest
```

The image sets its working directory to `/project`, so paths are relative to the repo
root once mounted.

### Formatting and linting the Rego

```bash
opa fmt --write policy/conftest
opa check --strict policy/conftest
regal lint policy/conftest    # optional, if regal is installed
```

### In CI

`.github/workflows/terraform-plan.yml` runs, per environment, after `terraform plan`:

```yaml
- name: Render plan as JSON
  run: terraform show -json tfplan > tfplan.json
  working-directory: envs/${{ matrix.environment }}

- name: Policy check (conftest)
  run: conftest test --policy policy/conftest envs/${{ matrix.environment }}/tfplan.json
```

The job fails on any `deny`. `warn` findings are printed and left for human judgement
in review.

---

## 4. Deploying the Azure Policy definitions

Definitions and assignments live at **management group** scope in production. A
subscription-scoped assignment only protects the subscription it is attached to; a
management-group assignment is inherited by every current *and future* subscription
beneath it, which is the only version that survives the next subscription somebody
creates without telling you.

```bash
MG_ID="00000000-0000-0000-0000-000000000000"   # Platform management group

# --- create / update the definitions -------------------------------------
az policy definition create \
  --name afk-require-platform-tags \
  --display-name "Require the platform tag set on all indexed resources" \
  --mode Indexed \
  --management-group "$MG_ID" \
  --rules   @policy/azure-policy/require-tags.json#properties.policyRule \
  --params  @policy/azure-policy/require-tags.json#properties.parameters

az policy definition create \
  --name afk-restrict-compute-skus \
  --display-name "Restrict virtual machine and AKS node pool SKUs to an approved list" \
  --mode Indexed \
  --management-group "$MG_ID" \
  --rules   @policy/azure-policy/restrict-vm-skus.json#properties.policyRule \
  --params  @policy/azure-policy/restrict-vm-skus.json#properties.parameters

az policy definition create \
  --name afk-deny-aks-insecure-cluster-profile \
  --display-name "AKS clusters must have private nodes, an OIDC issuer and no local accounts" \
  --mode Indexed \
  --management-group "$MG_ID" \
  --rules   @policy/azure-policy/deny-aks-public-nodes.json#properties.policyRule \
  --params  @policy/azure-policy/deny-aks-public-nodes.json#properties.parameters
```

> `az policy definition create` expects the **policy rule** and the **parameters** as
> separate arguments, not the whole definition object. If your `az` version does not
> support the `#properties.policyRule` JSON-pointer suffix, split the file first:
> `jq '.properties.policyRule' policy/azure-policy/require-tags.json > /tmp/rule.json`.

```bash
# --- assign ---------------------------------------------------------------
az policy assignment create \
  --name afk-prod-require-platform-tags \
  --display-name "afk :: require platform tag set (prod)" \
  --policy "/providers/Microsoft.Management/managementGroups/$MG_ID/providers/Microsoft.Authorization/policyDefinitions/afk-require-platform-tags" \
  --scope  "/providers/Microsoft.Management/managementGroups/$MG_ID" \
  --params '{"effect":{"value":"Deny"},"tagNames":{"value":["environment","project","owner","managed_by","cost_center"]}}' \
  --mi-system-assigned \
  --location westeurope \
  --enforcement-mode Default
```

`assignment-example.json` is the same assignment expressed as an ARM resource
(`Microsoft.Authorization/policyAssignments`, `apiVersion 2024-04-01`) so it can be
dropped into a deployment template or translated to
`azurerm_management_group_policy_assignment`. A few things in it are deliberate:

- **`identity: { "type": "SystemAssigned" }`** — a managed identity is only *required*
  for `DeployIfNotExists` and `Modify` effects, which need permission to write the
  remediating resource. It is included here so the assignment can be upgraded to a
  `Modify` effect (auto-stamping missing tags from the resource group) without having
  to recreate it. An assignment with an identity **must** also declare a `location`.
- **`enforcementMode: "Default"`** — the policy effect is applied. Use
  `"DoNotEnforce"` for a what-if run: compliance is still evaluated and reported, but
  nothing is blocked. That is the right first step when onboarding an existing
  subscription, paired with `effect: "Audit"`.
- **`nonComplianceMessages`** — the message an engineer sees when the deployment is
  rejected. A good one names the missing control *and* links back to this README.
  Without it, the user gets an opaque `RequestDisallowedByPolicy` and files a ticket.
- **`notScopes`** — Azure-managed resource groups (`NetworkWatcherRG`,
  `AzureBackupRG_*`) are created by Azure services with tags you do not control.

### Rollout sequence

1. Assign with `effect: Audit` + `enforcementMode: DoNotEnforce`.
2. Read `az policy state summarize` and fix the existing estate.
3. Flip `enforcementMode` to `Default`, keep `effect: Audit`.
4. Flip `effect` to `Deny`.

Skipping to step 4 on a brownfield subscription breaks everybody's deployments on a
Monday morning and gets the assignment deleted by someone with Owner by lunchtime.

---

## 5. Documented exceptions

**Every exception carries a written justification. An unjustified skip is a smell** —
it means either the rule is wrong (fix the rule) or the resource is wrong (fix the
resource). A silent `# nosec`-style bypass with no explanation is how a policy set
rots into decoration.

There are exactly two standing exceptions, both encoded in the rules themselves rather
than as per-resource suppressions, so they are visible in code review:

### E1 — Key Vault purge protection is not required in `dev` (D9)

Purge protection is **irreversible**: once enabled on a vault it can never be turned
off, and the vault name stays globally reserved for the whole soft-delete retention
window (up to 90 days) after deletion. In dev, vaults are created and destroyed on
every feature branch, so enabling it would permanently burn the deterministic name our
naming convention produces (`afk-dev-weu-platform-kv`) and block the next
`terraform apply` with a name-in-use error.

- **Scope:** resources whose `environment` tag is exactly `dev`.
- **Residual risk:** the dev subscription holds no production key material. Soft delete
  still applies — Azure made it mandatory and non-disableable, and azurerm v4 removed
  the `soft_delete_enabled` argument entirely — so an accidental delete in dev is still
  recoverable within `soft_delete_retention_days`.
- **Accepted by:** platform engineering. Revisit if dev ever stores real secrets.

### E2 — AKS `sku_tier = "Free"` is warn-only, and silent in `dev` (W2)

The Free tier has no control-plane SLA (a 99.5% availability *target*, no financial
backing) and a lower API-server scale ceiling.

- **Why warn and not deny:** the tier is a cost decision, not a security one, and a
  short-lived staging cluster for a spike is a legitimate use. Denying it would push
  people to bypass the gate entirely.
- **Scope of silence:** `environment = dev` only. In staging and prod the warning is
  raised and the reviewer must see a justification in the PR description.

The same principle applies to W1 (public storage), W3 (ACR SKU), W4 (public API server)
and W5 (Key Vault access policies): they are advisory because there is a real, narrow
set of cases where the non-default answer is correct — and in every one of those cases
the PR description must say which case it is.

### Azure Policy exemptions

At the platform layer the equivalent mechanism is a
`Microsoft.Authorization/policyExemptions` resource. Ours must carry:

- a `displayName` naming the control being exempted,
- a `description` with the justification,
- an `expiresOn` date — **no permanent exemptions**,
- `exemptionCategory: "Waiver"` (accepted risk) or `"Mitigated"` (handled another way).

They are declared in `envs/<env>/governance.tf` so they go through pull-request review
like everything else.

---

## 6. Adding a new rule

1. **Write the rule** in `policy/conftest/terraform.rego`.
   - `deny` if it is a genuine security or contract violation; `warn` if the right
     answer is sometimes "no". Keeping the deny set small is what stops it from being
     ignored.
   - The message must contain `rc.address` and the exact remediation — the argument
     name and the value to set. Assume the reader has never seen the rule before.
   - Use `attr_bool` / `attr_string` rather than reaching into `change.after` directly,
     so absent and `null` are handled consistently.
   - Comment the *why*, not the *what*. The rule says what it checks; only a comment
     can say why the control matters.
2. **Write the test** in `policy/conftest/terraform_test.rego`, named
   `test_<thing>_<expectation>`. At minimum one fixture that trips the rule and one
   that does not. Assert on `count(deny)` / `count(warn)`, not on message text.
   Reuse the `mock_*` fixture builders; add a new one if the resource type is new.
3. **Check the compliant baseline.** `test_compliant_platform_passes` asserts
   `count(deny) == 0` across one of every resource type. If your new rule is too broad,
   that test goes red — which is exactly what it is there for. Do not "fix" it by
   loosening the fixture.
4. **Run the tests.**
   ```bash
   conftest verify --policy policy/conftest
   opa fmt --write policy/conftest
   opa check --strict policy/conftest
   ```
5. **Consider the platform layer.** If the control can be expressed as an ARM alias,
   add a matching Azure Policy definition under `policy/azure-policy/` so it is also
   enforced for changes that never go through this repository. Note the pairing in both
   files, as `deny-aks-public-nodes.json` does.
6. **Open the PR.** Include a plan excerpt showing the rule firing, and if the rule is
   likely to break existing environments, ship it as `warn` first and promote it to
   `deny` in a follow-up once the estate is clean.

---

## 7. Contract reference

Values the rules depend on. Changing any of them means changing `terraform.rego`,
`require-tags.json` and the environment root modules together.

| Item | Value |
|---|---|
| Required tags | `environment`, `project`, `owner`, `managed_by`, `cost_center` |
| `managed_by` | always `terraform` |
| `project` | always `terraform-azure-aks-platform` |
| Environments | `dev`, `staging`, `prod` (directory-per-env under `envs/`) |
| Naming convention | `{prefix}-{env}-{region_short}-{workload}-{type}`, prefix `afk` — e.g. `afk-prod-weu-platform-aks` |
| Terraform | `>= 1.9` |
| Provider | `azurerm ~> 4.0` |

**azurerm v4 argument names used by the rules** — v3 code will not set these, which is
why several rules double as migration guards:

| v3 | v4 (used here) |
|---|---|
| `enable_https_traffic_only` | `https_traffic_only_enabled` |
| `enable_node_public_ip` | `node_public_ip_enabled` |
| `allow_blob_public_access` | `allow_nested_items_to_be_public` |
| `soft_delete_enabled` | *removed — soft delete is mandatory; only `soft_delete_retention_days` remains* |

---

Maintained by **Ahmed Fakhfakh** ([@fakhfakhahmed](https://github.com/fakhfakhahmed)) ·
[fakhfakhahmed/terraform-azure-aks-platform](https://github.com/fakhfakhahmed/terraform-azure-aks-platform)

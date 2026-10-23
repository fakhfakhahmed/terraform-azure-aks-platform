# Security

The threat model for `terraform-azure-aks-platform`, what it defends against, and — just as
important — what is deliberately relaxed in dev and why. If you only read one section, read
[What's relaxed in dev, and why](#whats-relaxed-in-dev-and-why): every portfolio reviewer and every
auditor eventually asks "did you know about this?", and the honest answer here is yes.

**Contents**

- [OIDC: secretless CI/CD](#oidc-secretless-cicd)
- [Federated credential subject pinning](#federated-credential-subject-pinning)
- [Workload Identity: secretless pods](#workload-identity-secretless-pods)
- [Private cluster design](#private-cluster-design)
- [Key Vault via the CSI driver](#key-vault-via-the-csi-driver)
- [Azure RBAC for Kubernetes vs. local accounts](#azure-rbac-for-kubernetes-vs-local-accounts)
- [Network policy](#network-policy)
- [CI security gates](#ci-security-gates)
- [What's relaxed in dev, and why](#whats-relaxed-in-dev-and-why)

---

## OIDC: secretless CI/CD

GitHub Actions never holds an Azure client secret. A workflow job requests a short-lived OIDC ID
token from GitHub, presents it to Entra ID as a client assertion, and Entra issues an Azure access
token only if the token's `iss`, `sub` and `aud` claims exactly match a federated identity
credential declared in [`bootstrap/github-oidc.tf`](../bootstrap/github-oidc.tf). No credential
exists to leak, rotate, or expire unexpectedly at 2am.

The full exchange, claim by claim, is diagrammed in
[architecture.md section 2](./architecture.md#2-github-oidc-to-azure-authentication-flow). The
rationale for choosing this over a service-principal secret — including the alternative
considered and rejected — is in
[ADR-0002](./decisions/0002-oidc-over-service-principal-secrets.md).

### Federated credential subject pinning

The `sub` claim is the actual security boundary, and it is matched exactly and case-sensitively —
there is no wildcard or prefix form. `bootstrap/github-oidc.tf` creates five federated
credentials: one for the default branch (`ref:refs/heads/main`), one for pull requests
(`pull_request`), and one per GitHub Environment (`environment:dev`, `environment:staging`,
`environment:prod`).

The `environment:` subjects matter most, because GitHub will not mint a token carrying that
subject until the job has passed that environment's protection rules — required reviewers, wait
timers, allowed branches. That means **the approval gate is enforced at token issuance, in
GitHub's infrastructure**, not by an `if:` condition in workflow YAML that anyone with write
access could edit around. A job cannot obtain a prod-capable Azure token without clearing the prod
approval gate, full stop.

The `pull_request` subject is scoped deliberately narrowly: GitHub does not issue it for
pull requests from forks, so an external contributor opening a PR cannot obtain any Azure token at
all. It is intended for `terraform plan` only — never grant a role beyond read/plan access to the
identity that uses this credential, since any job triggered by `pull_request` on a non-fork branch
can assume it.

---

## Workload Identity: secretless pods

The same federation primitive, one layer down. A Kubernetes ServiceAccount is bound, via a
`azurerm_federated_identity_credential` whose issuer is the AKS cluster's own OIDC issuer URL, to
an Azure user-assigned managed identity. A pod using that ServiceAccount — carrying the
`azure.workload.identity/use: "true"` label on its **pod template**, not the Deployment's own
metadata — gets a projected, auto-rotated service account token injected by AKS's mutating
admission webhook, and exchanges it for an Azure access token the same way a CI job does.

The full mechanism, the two concrete failure modes, and the sample manifests are covered in
[architecture.md section 3](./architecture.md#3-workload-identity-token-exchange) and
[`kubernetes/README.md`](../kubernetes/README.md). The design rationale versus storing secrets in
Key Vault with a static credential, or using the deprecated AAD Pod Identity, is in
[ADR-0004](./decisions/0004-workload-identity-over-secrets.md).

The practical consequence for an incident responder: there is no `imagePullSecret`, no Key
Vault connection string, and no client secret anywhere in this cluster's workload namespaces to
rotate after a compromise. The blast radius of a stolen pod filesystem is whatever that pod's
federated identity is authorised to do — scoped per workload by `modules/identity`, not shared
across the whole node.

---

## Private cluster design

Prod runs AKS with `private_cluster_enabled = true`: the API server has no public IP, is reachable
only through a private endpoint inside `snet-private-endpoints`, and `kubectl` from outside the
VNet (or a peered network) simply cannot reach it. Combined with `local_account_disabled = true`,
the only way to administer the prod cluster is through Azure RBAC for Kubernetes over a network
path that terminates inside the VNet — a jumpbox, a VPN, or a CI runner with network line of
sight.

Dev and staging run the API server **publicly reachable**, gated instead by
`api_server_access_profile.authorized_ip_ranges` — an allow-list of source CIDRs (the developer's
current egress IP, the CI runner's published ranges) rather than a private endpoint. This is a
real, intentional reduction in isolation; see
[What's relaxed in dev, and why](#whats-relaxed-in-dev-and-why) for the justification and why
staging does not get the same exception as dev despite also being non-private.

---

## Key Vault via the CSI driver

Pods never receive a Key Vault secret through a Kubernetes `Secret` object by default. The
Secrets Store CSI driver, running as the AKS `key_vault_secrets_provider` add-on with
`secret_rotation_enabled`, fetches the objects listed in a `SecretProviderClass` and mounts them as
files at `/mnt/secrets-store` inside the pod — read-only, never written to etcd, re-read and
updated in place on the add-on's rotation poll without a pod restart.

A Kubernetes `Secret` is created from a vault value **only** when a `SecretProviderClass` opts in
with an explicit `secretObjects` block, as documented (and deliberately unused by the sample
workload) in
[`kubernetes/secrets-store/secretproviderclass.yaml`](../kubernetes/secrets-store/secretproviderclass.yaml).
That path exists for the narrow case of a container that can only read an environment variable,
not a file, and it is a conscious trade — the value then does live in etcd (base64, not
encrypted, unless the cluster has Secrets encryption-at-rest configured separately) and rotation
stops being transparent to a running container, since an env var is resolved once at process
start. Prefer the file mount; use `secretObjects` only when you have written down why the file
mount will not work for that specific workload.

Key Vault itself is deployed with `rbac_authorization_enabled = true` (never the legacy
vault-scoped access-policy model) so that "who can read which secret" is visible in the same Azure
RBAC graph as every other resource, supports Privileged Identity Management, and is enforced by
`conftest` rule W5 (see [CI security gates](#ci-security-gates) below).

---

## Azure RBAC for Kubernetes vs. local accounts

`local_account_disabled = true` on every environment's AKS cluster, with no exception. This
removes the cluster's static admin client certificate entirely — there is no `kubeconfig` anyone
can download once and use forever, with no MFA, no conditional access policy, no per-user audit
trail, and no revocation mechanism short of rotating the cluster's certificate authority.

With local accounts disabled, every `kubectl` command authenticates as the caller's own Entra ID
identity (interactively via `kubelogin`, or as a federated CI identity — see
[OIDC above](#oidc-secretless-cicd)) and is authorised by Azure RBAC role assignments scoped to
the cluster or a specific namespace. This means:

- access can be granted and revoked through the same Entra ID group membership and PIM workflow as
  every other Azure resource, instead of a parallel Kubernetes-native RBAC story;
- every `kubectl` action an administrator takes is attributable to a named human or workload
  identity in the Azure Activity Log, not to "the admin cert";
- a leaked `kubeconfig` file is useless without the holder also being able to complete an
  interactive Entra sign-in (or presenting a valid federated credential), because the file itself
  carries no bearer credential.

This is enforced in CI by `conftest` rule D4 (`local_account_disabled`) — it is a blocking `deny`,
not advisory, in every environment including dev. Unlike the other relaxations in this document,
there is no dev exception for local accounts: an admin certificate is a standing credential
regardless of environment, and dev being lower-value data is not a reason to hand out a bearer
credential that bypasses the directory entirely.

---

## Network policy

Staging and prod run `network_policy = "cilium"` (Azure CNI Powered by Cilium) for pod-to-pod
traffic enforcement: an eBPF dataplane with identity-based policy and richer observability than
the default. Dev runs `network_policy = "azure"` instead — Azure's own iptables-based
implementation.

This is the one place where dev does not exercise the same dataplane as prod, and it is recorded
as a deliberate, uncomfortable trade rather than an oversight: Cilium's dataplane has specific
node SKU/kernel requirements that interact awkwardly with the burstable `Standard_B2s` node used
to keep dev cheap, and NetworkPolicy correctness for a change is expected to be validated in
staging — which does run Cilium — before it reaches prod, never in dev. See
[architecture.md — Network policy](./architecture.md#network-policy-cilium-in-stagingprod-azure-in-dev)
for the full reasoning; this document does not repeat or contradict it. If you are authoring or
testing a `NetworkPolicy` object, test it in staging — dev will tell you it works regardless.

---

## CI security gates

Two independent, deliberately overlapping enforcement layers run against this codebase, plus a
third at the Azure platform layer. Full detail, the complete rule list and exception process live
in [`policy/README.md`](../policy/README.md) — this section is the summary and the "why three
layers" framing.

| Layer | Tool | Scope | What it uniquely catches |
|---|---|---|---|
| Static HCL | **Checkov** | Terraform source, before `plan` | A large, maintained library of generic CIS/NIST-aligned checks nobody on this team has to author — misconfigurations visible from the HCL alone, including in modules never actually exercised by the current `.tfvars`. |
| Plan JSON | **Conftest / OPA** | `terraform show -json tfplan`, after `plan`, before `apply` | Rules specific to this platform's own contract (required tags, naming convention, the documented dev purge-protection exception) evaluated against **computed** values — things like a planned deletion of a prod resource that only exist in the plan, not the raw HCL. Runs in the same CI job as Checkov, on the pull request, before any Azure resource is touched. |
| Platform (continuous) | **Azure Policy** | Every ARM write, from any source, forever | Everything that does not go through this Terraform at all: a change made by hand in the portal during an incident, a drift-inducing Azure-side mutation, another team's pipeline in the same subscription. Enforced at the ARM API boundary regardless of how the request arrived. |

Checkov and Conftest catch different things because they see different representations of the
same change — static HCL cannot see a computed value or a planned deletion, and a plan is blind to
anything not created by this Terraform run. Azure Policy closes the gap both leave: it cannot give
feedback before an apply and its `Deny` surfaces as an opaque ARM error mid-deployment, but it is
the only layer that is awake continuously, independent of which pipeline (or human) is making the
change. Each layer's blind spot is the next layer's reason to exist — see
[`policy/README.md` §1](../policy/README.md#1-why-two-layers) for the detailed comparison table
and [§5](../policy/README.md#5-documented-exceptions) for the two standing, written exceptions
(Key Vault purge protection and the AKS `Free` SKU tier, both dev-scoped).

---

## What's relaxed in dev, and why

Every relaxation below is a deliberate cost/velocity trade for a throwaway environment, not an
oversight — each one is also enforced or exempted explicitly in code (`policy/conftest`,
`envs/dev/*.tfvars`), never left to configuration drift. None of them apply to staging or prod.

| Relaxed in dev | Justification |
|---|---|
| **No private endpoints** (ACR, Key Vault reachable over their public data-plane endpoint) | Private endpoints require the private-DNS-zone and VNet-link machinery, and buy isolation dev does not need to prove — dev holds no production data. Staging deliberately does *not* get this exception; it stays public too, matching dev, with the private topology validated for real only once, in prod. See [architecture.md — Environment topology differences](./architecture.md#environment-topology-differences). |
| **`network_policy = "azure"` instead of Cilium** | Node SKU/kernel interaction with the burstable `Standard_B2s` dev node; NetworkPolicy correctness is validated in staging (which runs Cilium) before prod, never in dev. See [Network policy](#network-policy) above. |
| **AKS `Free` SKU tier** | No control-plane SLA and a lower API-server request ceiling, which is the point: dev hits control-plane throttling first, in an environment where it is an annoyance, rather than prod discovering it during an incident. Saves roughly €70/month — see [cost.md](./cost.md) — but the operational reason comes first. |
| **No Key Vault purge protection** | Purge protection is irreversible once enabled, and dev vaults are created and destroyed routinely (every feature branch, nightly teardown). Enabling it would permanently burn the deterministic vault name on the first destroy and block the next `apply` with a name-in-use error. Dev holds no real key material, and soft delete — mandatory, non-disableable in azurerm v4 — still protects against an accidental single delete. This is `conftest` exception E1; see [`policy/README.md` §5](../policy/README.md#e1--key-vault-purge-protection-is-not-required-in-dev-d9). |
| **Broader `authorized_ip_ranges` on the (public) API server** | Dev engineers work from changing home/office IPs without a VPN; a private cluster or a tight allow-list would mean re-running `terraform apply` every time someone's ISP reassigns an address. Acceptable because dev holds no production data and the cluster still requires Entra ID + Azure RBAC authentication regardless of source IP — the allow-list is defence in depth, not the only control. |
| **No `prevent_destroy` on stateful resources** | Dev is designed to be destroyed — see [cost.md — Teardown](./cost.md#teardown) and the `make destroy-dev` workflow. A `prevent_destroy` lifecycle block exists specifically to make a resource hard to delete by accident; that protection is backwards for an environment whose entire purpose is cheap, frequent destroy/recreate cycles. Staging and prod set it on Key Vault, ACR and Log Analytics (see [architecture.md — Environment topology differences](./architecture.md#environment-topology-differences)). |

Every one of these has a concrete migration path back to the prod posture if dev's purpose ever
changes (for example, if dev started holding real secrets) — see
[architecture.md — Known gaps and deferred work](./architecture.md#known-gaps-and-deferred-work)
for the ones that are structural rather than a `.tfvars` flip.

---

## See also

- [architecture.md](./architecture.md) — the full system design these controls sit inside
- [cost.md](./cost.md) — what the relaxations above are trading against, in euros
- [policy/README.md](../policy/README.md) — the complete rule reference and exception process
- [kubernetes/README.md](../kubernetes/README.md) — the Workload Identity sample end to end
- [ADR-0002](./decisions/0002-oidc-over-service-principal-secrets.md),
  [ADR-0004](./decisions/0004-workload-identity-over-secrets.md) — the two secretless-auth decisions

# 0004 — Azure AD Workload Identity over stored Key Vault secrets or AAD Pod Identity

## Status

Accepted

## Context

Pods need to authenticate to Azure services — in this platform, primarily Key Vault, via the
Secrets Store CSI driver. Three approaches were on the table:

1. **A stored credential** — a service principal client secret (or a Key Vault access key)
   embedded in a Kubernetes `Secret`, an environment variable, or a mounted file, with pods reading
   it directly.
2. **AAD Pod Identity** — the predecessor in-cluster project that intercepted the node's Instance
   Metadata Service (IMDS) endpoint to hand pods a managed-identity token, matched by pod label to
   an `AzureIdentityBinding`. Deprecated by Microsoft in favour of Workload Identity federation,
   with removal from AKS add-on support.
3. **Azure AD Workload Identity** — OIDC federation between a Kubernetes ServiceAccount and an
   Azure user-assigned managed identity, using the AKS cluster's own OIDC issuer as the trust
   anchor. No secret exists at any point in the flow.

[Design principle #2](../architecture.md#design-principles) states plainly: "no long-lived secrets
anywhere in the delivery path." The same principle that rules out a service-principal secret for CI
([ADR-0002](./0002-oidc-over-service-principal-secrets.md)) applies with equal force one layer down,
inside the cluster.

## Decision

Use Azure AD Workload Identity (`workload_identity_enabled = true` and `oidc_issuer_enabled = true`
on the AKS cluster, with `azurerm_federated_identity_credential` per workload in `modules/identity`)
for every pod that needs an Azure credential. The full mechanism — the federated credential's
`subject` matching `system:serviceaccount:<namespace>:<serviceaccount>`, the mutating admission
webhook injecting a projected, auto-rotated token at pod admission, and the resulting
`client_assertion` exchange against Entra ID — is diagrammed step by step in
[architecture.md section 3](../architecture.md#3-workload-identity-token-exchange).

**Against a stored credential:** rejected for the same reasons a CI service-principal secret was
rejected in [ADR-0002](./0002-oidc-over-service-principal-secrets.md) — it is a bearer credential
that, once created, exists indefinitely until someone remembers to rotate it, and its presence in a
Kubernetes `Secret` means it is readable by anyone with `get` on secrets in that namespace,
including via a misconfigured RBAC `ClusterRole` or a compromised sidecar. [security.md — Key Vault
via the CSI driver](../security.md#key-vault-via-the-csi-driver) covers why even the *CSI-mounted*
file path is preferred over the native-Secret sync option for the same underlying reason.

**Against AAD Pod Identity:** rejected because it is deprecated. Beyond the lifecycle risk, its
architecture required a cluster-wide, privileged component (NMI) intercepting IMDS traffic on every
node — a bigger attack surface, and a binding model (`AzureIdentityBinding` matched by pod label) that
had a well-documented identity-confusion window during pod startup, where a pod could briefly
receive the wrong identity's token on a node transitioning between bindings. Workload Identity
removes that class of problem structurally: the federated credential binds to a specific
ServiceAccount identity string, verified cryptographically against the cluster's own OIDC issuer,
with no node-level interception component at all.

## Consequences

**What this buys:**

- No Azure credential of any kind exists inside the cluster at rest — not in a `Secret`, not in a
  ConfigMap, not in an environment variable baked into an image. The projected token Workload
  Identity issues is scoped to one hour and rotated automatically by the kubelet; there is nothing
  to rotate by hand and nothing long-lived to leak from a `kubectl describe pod` or a container
  filesystem dump.
- Identity is scoped per workload, not per node. `modules/identity` creates one managed identity per
  entry in its workload map, each with its own federated credential and its own Key Vault role
  assignment — a compromised pod's blast radius is exactly what that pod's identity was granted
  ([security.md — Workload Identity: secretless pods](../security.md#workload-identity-secretless-pods)),
  not the shared kubelet identity every pod on a node would otherwise inherit.
- The mechanism is symmetric with the CI authentication path in
  [ADR-0002](./0002-oidc-over-service-principal-secrets.md) — both are OIDC federation against a
  JWKS-serving issuer, verified by Entra ID, with no shared secret at any layer. An engineer who
  understands one understands the other; `architecture.md` deliberately presents them as sections 2
  and 3 of the same story.
- No cluster-wide privileged component is required beyond the standard AKS mutating webhook that
  ships with `workload_identity_enabled = true` — no NMI DaemonSet, no IMDS interception, no
  additional attack surface per node.

**What this costs:**

- The failure mode is a string-matching problem, not a missing-permission problem, and the error
  message does not say which string is wrong. `AADSTS70021` is produced identically whether the
  namespace, the ServiceAccount name, or the issuer URL is the mismatch — see
  [architecture.md — The two failure modes you will actually hit](../architecture.md#the-two-failure-modes-you-will-actually-hit)
  and [getting-started.md — Troubleshooting](../getting-started.md#aadsts70021-no-matching-federated-identity-record-found).
  This platform mitigates it with explicit comments in every manifest that carries a piece of that
  string (see [`kubernetes/README.md`](../../kubernetes/README.md)), but it remains a sharper edge
  than "the secret is wrong, rotate it."
- The ordering dependency is real and not expressible as a plain Terraform reference in one place:
  the federated credential's `issuer` is the cluster's `oidc_issuer_url`, which does not exist until
  the cluster does, so `modules/identity` must run after `modules/aks` —
  [architecture.md — Ordering constraints that are real](../architecture.md#ordering-constraints-that-are-real).
  Combined with Entra role-assignment propagation delay (30–60 seconds), a pod that starts
  immediately after `terraform apply` can transiently fail with a 403 from Key Vault — not a bug,
  but a real operational wrinkle that the sample manifests work around with a generous
  `initialDelaySeconds` rather than Terraform solving it directly.
- Workload Identity is an AKS/Entra-specific mechanism. A workload that needs to run unmodified on a
  non-Azure Kubernetes distribution cannot rely on the same federation and would need an abstraction
  layer (or a different per-cloud credential story) if portability became a requirement — not a
  concern for this platform's stated scope, but worth naming as a boundary of the decision.

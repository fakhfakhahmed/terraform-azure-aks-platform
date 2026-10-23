# Cost

What this platform actually costs to run, per environment, and how to stop paying for it the
moment you are done.

> ### ⚠️ Run `make destroy-dev` when you are done experimenting
>
> Dev costs roughly **€190–200/month if left running 24/7** — almost entirely VM node hours and
> Log Analytics ingestion, neither of which has a free tier. There is no idle-shutdown mechanism
> in this repository: a cluster you forget about keeps billing exactly as if you were using it.
> If you are not actively working against dev right now, tear it down:
>
> ```bash
> make destroy-dev
> ```
>
> See [Teardown](#teardown) at the bottom of this document for the staging/prod equivalents and
> the Key Vault purge-protection caveat.

**All figures below are indicative, for the `westeurope` region, at on-demand (pay-as-you-go)
rates, as of late 2025.** They will drift with Azure price changes, actual usage (data processed,
log volume, node autoscaling) and region. **Verify current numbers with the
[Azure Pricing Calculator](https://azure.microsoft.com/pricing/calculator/) before relying on
them for a real budget.** These numbers exist to make the trade-offs in
[architecture.md](./architecture.md) and [security.md](./security.md) concrete, not to be an
invoice.

**Contents**

- [Monthly cost by environment](#monthly-cost-by-environment)
- [Why NAT Gateway is costed in dev too](#why-nat-gateway-is-costed-in-dev-too)
- [Free-tier and cost-saving options](#free-tier-and-cost-saving-options)
- [Teardown](#teardown)

---

## Monthly cost by environment

Figures assume the node-pool **minimum** count from
[architecture.md — Environment topology differences](./architecture.md#environment-topology-differences)
running continuously; user-pool autoscaling means the real number moves with load, not below this
floor. "AKS control plane" and "AKS Standard tier SLA" are listed separately because they are
billed separately: the control plane itself is **always free**, regardless of SKU tier — the
`Standard` tier charges for the uptime SLA, not for compute.

### Dev (`10.10.0.0/16`)

| Resource | Spec | Approx. €/month |
|---|---|---|
| AKS control plane | `Free` SKU tier | €0 |
| System node pool | 1 × `Standard_B2s` | ≈ €24 |
| User node pool | 1–2 × `Standard_D2s_v5` (min 1) | ≈ €70 |
| NAT Gateway | 1 static public IP + data processing | ≈ €36 (€31 fixed + ≈€5 processing) |
| Load Balancer | Standard, inbound only | ≈ €18 |
| Azure Container Registry | `Basic` | ≈ €4 |
| Key Vault | standard tier, low operation volume | < €1 |
| Log Analytics | pay-as-you-go ingestion, 30-day retention, light demo traffic | ≈ €12 |
| Application Insights | workspace-based, bundled into the Log Analytics ingestion above | included above |
| Private endpoints | none (dev has none — see [architecture.md](./architecture.md#environment-topology-differences)) | €0 |
| **Approx. total** | | **≈ €165/month** (rounds up toward **€190–200** under heavier demo traffic or a second user-pool node) |

### Staging (`10.20.0.0/16`)

| Resource | Spec | Approx. €/month |
|---|---|---|
| AKS control plane | `Standard` SKU tier (compute) | €0 |
| AKS Standard tier SLA | uptime-SLA fee | ≈ €70 |
| System node pool | 2 × `Standard_D2s_v5` | ≈ €140 |
| User node pool | 2–4 × `Standard_D4s_v5` (min 2) | ≈ €280 |
| NAT Gateway | 1 static public IP + data processing | ≈ €41 |
| Load Balancer | Standard, inbound only | ≈ €18 |
| Azure Container Registry | `Standard` | ≈ €16 |
| Key Vault | standard tier, purge protection on | < €1 |
| Log Analytics | 30-day retention, cluster + ACR + KV diagnostics | ≈ €20 |
| Application Insights | workspace-based | included above |
| Private endpoints | none (staging mirrors dev's public topology by design) | €0 |
| **Approx. total** | | **≈ €585/month** |

### Prod (`10.30.0.0/16`)

| Resource | Spec | Approx. €/month |
|---|---|---|
| AKS control plane | `Standard` SKU tier (compute), **private cluster** | €0 |
| AKS Standard tier SLA | uptime-SLA fee | ≈ €70 |
| System node pool | 3 × `Standard_D4s_v5`, zones 1/2/3 | ≈ €420 |
| User node pool | 3–10 × `Standard_D4s_v5` (min 3) | ≈ €420 |
| NAT Gateway | 1 static public IP + data processing | ≈ €51 |
| Load Balancer | Standard, inbound only | ≈ €18 |
| Azure Container Registry | `Premium` (private endpoint + geo-replication capable) | ≈ €46 |
| Key Vault | standard tier, purge protection on | < €1 |
| Log Analytics | 90-day retention, higher diagnostic volume | ≈ €40 |
| Application Insights | workspace-based | included above |
| Private endpoints | ACR + Key Vault, 2 × private endpoint + private DNS | ≈ €15 |
| **Approx. total** | | **≈ €1,080/month** |

The jump from staging to prod is almost entirely node count and SKU (3 system + minimum 3 user
`Standard_D4s_v5`, vs. staging's smaller pools) plus `Premium` ACR and private endpoints — not
anything exotic. Scaling the user pool to its ceiling (10 nodes) under load adds roughly
€980/month on top of the prod figure above; the cluster autoscaler is what keeps that cost tied to
actual demand rather than paid for continuously.

---

## Why NAT Gateway is costed in dev too

Every environment, including dev, provisions a NAT Gateway (≈ €31/month fixed, plus
≈ €0.042/GB processed) rather than the zero-cost default load-balancer outbound SNAT. This is not
an oversight — it is the one piece of prod's networking behaviour that dev is deliberately not
allowed to skip. See
[architecture.md — Why NAT Gateway rather than load-balancer outbound SNAT](./architecture.md#why-nat-gateway-rather-than-load-balancer-outbound-snat):
a platform where dev's egress semantics (SNAT port ceiling, source IP stability) differ from
prod's is a platform that lies to you about how it will behave under load. €31/month buys parity
instead of a surprise the first time dev needs to talk to a rate-limited or allow-listed partner
API.

---

## Free-tier and cost-saving options

- **The AKS control plane is free regardless of SKU tier.** What `Standard` actually buys is an
  uptime SLA and a higher API-server request ceiling (≈ €70/month) — cost in this platform is
  overwhelmingly driven by **node VM hours**, not the control plane. Running `Free` in dev (see
  [architecture.md](./architecture.md#environment-topology-differences)) saves that €70/month and
  deliberately surfaces API-server throttling in dev first, where it is an annoyance rather than a
  prod incident.
- **Burstable B-series nodes in dev.** `Standard_B2s` for the dev system pool is roughly a third
  the cost of the `Standard_D2s_v5` staging uses for the same role, because B-series nodes are
  CPU-credit-based and dev's system-pool workload (CoreDNS, the CSI drivers, `konnectivity`) barely
  uses any CPU most of the time.
- **Scale the user pool to its floor, or to zero, between sessions.** The cluster autoscaler
  (`min_count`/`max_count` per environment) will scale user-pool nodes back up on demand; there is
  no cost benefit to leaving spare capacity running outside active testing.
- **`Basic` ACR in dev, `Premium` only where private networking or geo-replication is actually
  used.** Private endpoints, customer-managed keys, content trust and geo-replication are
  `Premium`-only — paying for them in dev, where none of those features is exercised, buys
  nothing. See `conftest` rule W3 in [policy/README.md](../policy/README.md).
- **Shorter Log Analytics retention in dev/staging (30 days) vs. prod (90 days).** Retention is
  billed per GB-month retained beyond the free 31-day minimum; cutting it to the minimum useful
  window in non-prod is a direct, linear saving with no functional cost to a short-lived
  environment.
- **No private endpoints outside prod.** Each private endpoint plus its private DNS zone link adds
  a small fixed monthly cost (≈ €7.50/endpoint) and real operational complexity (DNS resolution,
  NSG rules permitting the private-endpoint subnet). Dev and staging get no isolation benefit from
  them that the public-network-with-RBAC-and-firewall model doesn't already provide at this scale
  — see [security.md — What's relaxed in dev, and why](./security.md#whats-relaxed-in-dev-and-why).
- **Destroy everything that isn't prod when you're not using it.** This is the single largest
  lever available and the one most people skip. See [Teardown](#teardown) below.

---

## Teardown

> ### ⚠️ Run `make destroy-dev` when you are done experimenting
>
> This is worth repeating at the bottom of the document, because it is the thing people forget:
> **nothing in this platform shuts itself off.** A dev cluster left running over a weekend costs
> the same per hour as one you are actively using. If you took anything away from this page, make
> it this command:
>
> ```bash
> make destroy-dev
> ```

| Environment | Destroy workflow | Notes |
|---|---|---|
| dev | Allowed, no approval gate | Designed to be destroyed and rebuilt routinely — see `make destroy-dev` and [getting-started.md Step 12](./getting-started.md#step-12--tear-it-down). |
| staging | Allowed, 1 reviewer | Same mechanics as dev; the approval gate exists to stop an accidental destroy, not to block a deliberate one. |
| prod | **Blocked** in CI | The destroy workflow refuses to run against prod at all (see [architecture.md — Environment topology differences](./architecture.md#environment-topology-differences)). A prod teardown is a deliberate, manual, out-of-band operation, not a pipeline button. |

### The Key Vault purge-protection caveat (staging / prod)

Staging and prod enable `purge_protection_enabled = true` on their Key Vault — see
[architecture.md](./architecture.md#environment-topology-differences) and
[security.md](./security.md#key-vault-via-the-csi-driver). Purge protection is **irreversible**
once set, and it changes what `terraform destroy` actually does to that vault:

- the vault is deleted (soft-deleted, in Azure's terms) but **not purged**;
- it stays in a recoverable, billed-at-zero-marginal-cost-but-reserved state for the remainder of
  the soft-delete retention window (up to 90 days);
- **its name stays globally reserved for that entire window.** A subsequent `terraform apply`
  that tries to create a vault with the same deterministic name (this platform's naming
  convention always produces the same name for the same environment, e.g.
  `afk-staging-weu-platform-kv`) fails with `VaultAlreadyExists` / "the vault name is already in
  use" until the window elapses or you explicitly recover and reuse the soft-deleted vault.

This does **not** mean a destroyed staging or prod environment keeps costing meaningful money —
Key Vault's own retained-but-deleted state carries no material charge. It means **the name is
blocked**, which is the actual operational surprise: a team that destroys and immediately tries to
rebuild staging hits `VaultAlreadyExists` on the very next `apply`. Recover the soft-deleted vault
(`az keyvault recover` or `az keyvault purge`, where permitted) instead of waiting out the window,
or choose a different environment/project tag if a true from-scratch rebuild is required. See
[getting-started.md — `VaultAlreadyExists`](./getting-started.md#vaultalreadyexists--the-vault-name-is-already-in-use)
for the exact recovery commands.

Dev deliberately **does not** enable purge protection, specifically to avoid this trap on an
environment that is destroyed routinely — see `conftest` exception E1 in
[policy/README.md](../policy/README.md#e1--key-vault-purge-protection-is-not-required-in-dev-d9).

---

## See also

- [getting-started.md](./getting-started.md) — the full apply/destroy walkthrough
- [architecture.md](./architecture.md) — why NAT Gateway, why these node SKUs, why these tiers
- [security.md](./security.md) — the security side of the same dev/staging/prod trade-offs

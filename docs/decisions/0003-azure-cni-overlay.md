# 0003 — Azure CNI Overlay over kubenet and over classic Azure CNI

## Status

Accepted

## Context

AKS offers three network plugin models for pod networking, and the choice drives the entire IP
address plan documented in
[architecture.md — IP address plan](../architecture.md#ip-address-plan):

1. **kubenet** — pods get IPs from a cluster-internal CIDR, routed via UDRs that Azure manages on
   the node subnet's route table; it is in long-term maintenance and is being retired by Microsoft.
2. **Classic (non-overlay) Azure CNI** — every pod gets a real, VNet-routable IP address from the
   node subnet. Simple to reason about, but the node subnet must be sized for `nodes × max_pods`,
   not for nodes — a `/24` node subnet supports only `floor(256 / (max_pods + 1))` nodes, which at
   a realistic `max_pods = 30` is 8 nodes.
3. **Azure CNI Overlay** — pods get IPs from a separate, cluster-internal overlay CIDR
   (`10.244.0.0/16` in this platform) that is never routed into the VNet. Traffic leaving a node is
   source-NAT-ed to the node's own VNet IP. Node subnets only need to be sized for nodes.

This platform's node subnets are provisioned as `/20`s — 4,091 usable addresses — against a hard
ceiling of 13 nodes in prod today. That sizing choice, and the entire reasoning for leaving that
much headroom, is laid out in
[architecture.md — Why /20 for node subnets when overlay only needs one IP per node?](../architecture.md#why-20-for-node-subnets-when-overlay-only-needs-one-ip-per-node)
and is **not** repeated here — this ADR explains the plugin-model decision; the specific CIDR
arithmetic lives in architecture.md as the single source of truth for those numbers.

## Decision

Use Azure CNI Overlay (`network_plugin = "azure"`, `network_plugin_mode = "overlay"`) in every
environment.

**Against kubenet:** rejected outright. It requires UDRs that cap a cluster at 400 nodes, adds
routing complexity that would complicate any future hub-and-spoke migration (see
[architecture.md — Rejected: hub-and-spoke with Azure Firewall](../architecture.md#rejected-hub-and-spoke-with-azure-firewall)),
and Microsoft's own guidance is to not choose it for new clusters. There is no scenario in this
platform's requirements where kubenet is the correct answer today.

**Against classic Azure CNI:** rejected because of the subnet-sizing consequence, not because of
any functional gap. Classic CNI's VNet-routable pod IPs are a real advantage when something outside
the cluster needs to address a pod directly (Private Link to a pod IP, a non-Kubernetes-aware
network appliance doing pod-level inspection) — this platform has no such requirement today. What
it does have is three environments' worth of node subnets that would each need to be sized for
`nodes × (max_pods + 1)` under classic CNI. At the `max_pods = 30` default, a `/20` would support
only 132 nodes — still enough headroom for this platform's ceilings, but the arithmetic gets
materially tighter the smaller the subnet or the higher `max_pods` is pushed, and getting it wrong
after the fact means re-IP-ing a live VNet, which is not a `terraform apply` — it is a maintenance
window and, likely, a cluster rebuild.

Overlay was chosen specifically so that node-subnet sizing is decoupled from pod density, and so
that the pod and service CIDRs (`10.244.0.0/16` and `172.16.0.0/16`) can be identical across all
three environments without any collision risk — they never appear on the wire outside the cluster.
See [architecture.md — Cluster-internal address spaces](../architecture.md#cluster-internal-address-spaces).

## Consequences

**What this buys:**

- Node subnets are sized once, for nodes, and the headroom already reserved (a `/20` supports up to
  132 nodes even under a future migration to classic CNI at `max_pods = 30`) absorbs both organic
  cluster growth and a possible future plugin-model migration without re-IP-ing — see
  [architecture.md](../architecture.md#why-20-for-node-subnets-when-overlay-only-needs-one-ip-per-node)
  for the full arithmetic.
- The same pod and service CIDRs are reused verbatim across dev, staging and prod, which keeps the
  IP address plan simple: only the VNet's second octet varies between environments (10.10/10.20/10.30),
  everything else — including the overlay ranges — is copy-identical.
- Egress behaviour matches [ADR](../architecture.md#why-nat-gateway-rather-than-load-balancer-outbound-snat)'s
  NAT Gateway design cleanly: a pod's traffic is already source-NAT-ed to the node's VNet IP by the
  overlay dataplane before it ever reaches the NAT Gateway, so there is one consistent SNAT model
  from pod to internet, not two different ones depending on whether the destination is in the VNet
  or outside it.

**What this costs:**

- Pod IPs are not directly addressable from outside the cluster. Nothing in the VNet, and nothing
  peered to it, can route to `10.244.0.0/16` — any requirement for pod-level Private Link or
  external pod-IP addressing would require migrating off overlay, which is exactly the scenario the
  reserved subnet headroom is sized for but has not been exercised.
- NSGs on the node subnets cannot express pod-to-pod policy, because pod IPs never appear on those
  subnets' wire traffic — that responsibility is pushed entirely to the in-cluster network policy
  engine (Cilium in staging/prod, Azure's own implementation in dev; see
  [architecture.md — Network policy](../architecture.md#network-policy-cilium-in-stagingprod-azure-in-dev)).
  A reader expecting to find pod isolation rules in the VNet's NSGs will not find them there, and
  that absence has to be understood as intentional rather than missing.
- Identical pod CIDRs across environments — safe under overlay — becomes the specific, documented
  debt item that would need to be unwound first if this platform ever migrated to classic CNI; see
  [architecture.md — Known gaps and deferred work](../architecture.md#known-gaps-and-deferred-work).

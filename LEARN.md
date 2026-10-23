# LEARN.md

Study notes for this repository, written so that whoever built it — or anyone reviewing it in an
interview — can explain every decision, not just point at the code. If [README.md](README.md) is
the showcase, this is the "why," at the level of detail a senior engineer is expected to defend.

**Contents**

- [1. Terraform fundamentals used here](#1-terraform-fundamentals-used-here)
- [2. Module design principles](#2-module-design-principles)
- [3. Azure fundamentals used here](#3-azure-fundamentals-used-here)
- [4. The OIDC flow, step by step](#4-the-oidc-flow-step-by-step)
- [5. The Workload Identity flow, step by step](#5-the-workload-identity-flow-step-by-step)
- [6. CI/CD for IaC](#6-cicd-for-iac)
- [7. Interview questions you can now answer](#7-interview-questions-you-can-now-answer)
- [8. Common failure modes](#8-common-failure-modes)

---

## 1. Terraform fundamentals used here

### State, and why remote state matters

Terraform state is a JSON document mapping every resource in your configuration to the real
object Azure created for it — IDs, computed attributes, the lot. It is the only place Terraform
records "this is what I believe exists." Three problems make local state (a `terraform.tfstate`
file on one laptop) unworkable for a team:

1. **Collaboration.** Two engineers running `apply` against the same infrastructure from two
   different local state files will each make decisions based on a stale picture of reality and
   can corrupt each other's work.
2. **Locking.** Remote state backends can acquire an exclusive lock for the duration of an
   operation, so a second `plan` or `apply` against the same state blocks instead of racing. This
   repository's backend (an Azure Storage blob container) uses a **blob lease** for this — the
   same mechanism a `COPY ... FOR UPDATE` row lock solves in a database, just at the file level.
3. **Source of truth for drift.** State is what a `plan` diffs *reality* against. Without a
   shared, authoritative state file, "did someone change this by hand in the portal?" is
   unanswerable.

See [docs/state-management.md](docs/state-management.md) for how this repository's backend is
built and how to recover it if the state blob is ever corrupted.

### The plan/apply lifecycle

`terraform plan` does three things: refresh (read the current state of tracked resources from
the provider API), diff (compare desired configuration against that refreshed state), and render
a human-readable change set — resources to create, update in place, replace (destroy + create),
or destroy. `terraform apply` executes that change set, in dependency order, and writes the
result back to state. The critical property this repository leans on hard: **`plan` is
read-only**. It touches no infrastructure. That is what makes it safe to run on every pull
request — see [section 6](#6-cicd-for-iac).

### Providers

A provider is a plugin that translates HCL resource blocks into API calls against a specific
system — `azurerm` for Azure Resource Manager, `random` for the `random_string` suffix on the
state storage account name, `time` where a resource needs a deliberate delay. Each provider
declares which API version(s) and argument shapes it supports, and that contract moves between
major versions — which is why `.terraform.lock.hcl` matters (below).

### The dependency graph

Terraform does not execute resources top-to-bottom as written. It builds a directed acyclic graph
from **references**: if `azurerm_role_assignment.x` reads `azurerm_key_vault.y.id`, Terraform
knows `y` must exist before `x` is created, and schedules accordingly — including parallelising
unrelated branches of the graph. This is why [docs/architecture.md](docs/architecture.md#module-composition)
can say "modules never call each other, composition happens in the environment root module, and
the dependency graph is readable from a single file": every arrow in that file's module-wiring
diagram is a Terraform reference, and the graph is exactly those arrows.

### `count` vs `for_each` — and why this repo exclusively uses `for_each`

Both let a single resource block produce multiple instances, but they address those instances
differently, and that difference matters once anything is ever removed from the middle of a
list.

- `count` addresses instances by **index**: `azurerm_thing.x[0]`, `azurerm_thing.x[1]`,
  `azurerm_thing.x[2]`. Remove the first element from the input list, and everything shifts down
  one slot. Terraform doesn't see "item 2 was removed" — it sees "item 1 changed, item 2 changed,
  item 3 was destroyed," and may plan to destroy and recreate resources that didn't actually
  change, purely because their index moved.
- `for_each` addresses instances by a **stable key** from a map or set of strings:
  `azurerm_thing.x["github-environment-prod"]`. Remove one key from the map, and exactly that one
  instance is destroyed. Every other instance's address is untouched, because the address was
  never derived from position.

Concretely in this repo: `bootstrap/github-oidc.tf` builds `federated_credentials` as a map keyed
by name (`"github-environment-prod"`, `"github-pull-request"`, …) specifically so that adding or
removing a GitHub Environment touches exactly one state address. With `count` over a list,
removing the *first* environment from that list would have reshuffled every other federated
credential's index and produced a plan that destroys and recreates credentials that never
actually changed — in the worst case, briefly removing a production-capable OIDC trust
relationship it didn't need to touch at all.

### Locals vs variables

A `variable` is an input — something the caller of a module or root module supplies, with a type
and (optionally) a default. A `local` is a named expression computed *inside* the current module
from variables, other locals, resource attributes, or data sources — never set from outside. The
rule of thumb used throughout this repository: if a caller should ever be able to override it, it
is a `variable`; if it is derived and the derivation itself is the point (the region abbreviation
lookup in `bootstrap/main.tf`, the tag map merge, the federated-credential map above), it is a
`local`.

### `depends_on` — and why it is used sparingly

Terraform infers almost all ordering from attribute references (above). `depends_on` is an
escape hatch for the remaining case: a dependency that is real at runtime but invisible in any
attribute — for example, a resource that must exist before another one for a reason the provider
schema doesn't expose (an IAM propagation, an API that silently requires a sibling resource to
be fully provisioned first). The pitfall: `depends_on` hides the *actual* reason for the
ordering from anyone reading the code later, because it names a resource, not a reason. This
repository avoids it everywhere an attribute reference can express the same constraint instead —
see [docs/architecture.md, "Ordering constraints that are real"](docs/architecture.md#ordering-constraints-that-are-real),
where both of the two genuine cross-module ordering constraints (`identity` after `aks`,
`keyvault` role assignments after `identity`) are expressed as normal attribute references
(`module.aks.oidc_issuer_url`, the managed identity's `principal_id`), not `depends_on`. If you
ever reach for `depends_on`, the first question to ask is "can I reference an attribute instead?"

### `lifecycle` blocks

- **`prevent_destroy = true`** — fails `plan`/`apply` outright if the resource would be
  destroyed. Used on prod's Key Vault, ACR, Log Analytics workspace, and on the state backend's
  own resource group and storage account in `bootstrap/main.tf` — resources where destruction is
  either irreversible or catastrophic for every other environment.
- **`ignore_changes`** — tells Terraform to stop diffing specific arguments after creation, for
  values that legitimately drift outside Terraform's control (or, as in
  `random_string.state_suffix`, arguments that must never be allowed to trigger a regeneration,
  because regenerating that suffix would rename the state storage account and orphan every
  environment's state file).
- **`create_before_destroy = true`** — for a resource that must never have zero healthy
  instances during a replace, Terraform creates the replacement before destroying the original,
  inverting its default destroy-then-create order. Relevant anywhere a resource is referenced
  by name from outside Terraform's own graph (a DNS record, a load balancer backend pool) where
  a brief absence would be an outage.

### Data sources vs resources

A `resource` block is something Terraform creates, updates, and destroys — it owns the resource's
lifecycle. A `data` source is read-only: it looks up something that already exists (an existing
subscription, the calling identity's own object ID via `azurerm_client_config`) and exposes its
attributes for other resources to reference. `bootstrap/main.tf` uses
`data "azurerm_client_config" "current"` to find out who is running `apply`, purely to grant that
identity data-plane access to the new storage account — it does not create or manage that
identity.

### `.terraform.lock.hcl`, and why it's committed

`terraform init` resolves each provider's version constraint to a specific version and records
that version plus the cryptographic checksums of every platform's provider binary in
`.terraform.lock.hcl`. Committing it means every engineer and every CI run gets the *exact* same
provider build, not just a build that satisfies the same version constraint — which matters
because provider patch releases do occasionally change behaviour. Without the lock file
committed, one teammate's laptop and CI could silently resolve different patch versions of
`azurerm` and disagree about what a plan should look like. Upgrading providers is then a
*deliberate* act (`terraform init -upgrade`), not something that happens by accident on whoever
runs `init` next. See also [failure mode 6](#8-common-failure-modes).

---

## 2. Module design principles

**Single responsibility.** Each module under `modules/` owns one coherent slice of
infrastructure — networking, the registry, the cluster, identity, the vault, observability — and
nothing else. `modules/aks` does not also create the Key Vault role assignment a pod needs; that
belongs to `modules/keyvault`, wired from the environment root.

**Explicit composition at the root, never module-to-module.** This is one of this repository's
hard rules (see [docs/architecture.md, Design principle 4](docs/architecture.md#design-principles)):
*modules never call each other.* All wiring — "the AKS module's subnet ID comes from the network
module's output" — happens in `envs/<env>/main.tf`, in plain Terraform references between module
blocks. The payoff is legibility: to understand the entire dependency graph for an environment,
you read one file, not six nested module trees. The cost is that the environment root modules do
carry real wiring logic rather than being pure "fill in some tfvars" shells — that's a deliberate
trade, not an oversight.

**Narrow interfaces.** A module's `variables.tf` should expose exactly the knobs that legitimately
differ between dev, staging, and prod — and nothing a reader would mistake for one of those. A
`variable` that only ever takes one value across every caller is, functionally, a constant
pretending to be configurable surface area; it adds to the cognitive load of using the module
without adding flexibility. (This is the same principle `terraform_unused_declarations` in
`.tflint.hcl` enforces mechanically for genuinely-unused inputs.)

**Outputs are the only contract.** Nothing outside a module should ever need to know what
resource types it creates internally, what it names them, or how its internal locals are
structured. A consumer reads `module.aks.oidc_issuer_url` and `module.aks.kubelet_identity_object_id`
and needs nothing else — the module is free to refactor its internals, rename resources, or
restructure its locals, as long as those outputs keep meaning the same thing. This is exactly how
`modules/identity` can consume `module.aks.oidc_issuer_url` without knowing or caring that it's
reading an attribute of an `azurerm_kubernetes_cluster` resource at all.

---

## 3. Azure fundamentals used here

### Subscriptions vs resource groups vs management groups

A **subscription** is the billing and quota boundary — one subscription, one invoice, one set of
regional quotas. A **resource group** is a logical container inside a subscription, mostly for
lifecycle grouping (things that get deleted together) and RBAC scoping; it has no cost or quota
of its own. A **management group** sits *above* subscriptions, letting policy and RBAC be
inherited by every subscription underneath it — including ones created later. This repository is
explicitly single-subscription (see [docs/architecture.md, "Scope and goals"](docs/architecture.md#scope-and-goals)):
each environment gets its own resource group, but there's no management-group scaffolding, because
that's a multi-team, multi-subscription concern this project isn't trying to solve. The
[`policy/azure-policy/`](policy/README.md) definitions are still written to be deployed at
management-group scope in a real tenant, because a subscription-scoped assignment only protects
the one subscription it's attached to — it doesn't follow a subscription created tomorrow.

### Entra ID vs Azure RBAC — identity plane vs authorisation plane

These answer two different questions. **Entra ID** (formerly Azure AD) answers "who is this?" —
it authenticates users, service principals, and managed identities, and is where you'd configure
MFA and conditional access. **Azure RBAC** answers "what is this identity allowed to do, and
where?" — role assignments like `Contributor` or `AcrPull`, scoped to a subscription, resource
group, or resource. An identity can be perfectly authenticated by Entra ID and still be refused
every operation because it has no RBAC role at the relevant scope — which is exactly the shape of
the "subscription Owner gets a 403 on blob storage" failure mode below: Owner is a *control-plane*
role; blob read/write is a separate *data-plane* permission that has to be granted explicitly.

### Managed identities — system-assigned vs user-assigned

A **system-assigned** identity is created and destroyed with its parent resource: delete the VM,
the identity disappears, and nothing else can ever reference it. A **user-assigned** identity is
a standalone Azure resource with its own lifecycle, which can be created ahead of time, attached
to more than one resource, and survives the deletion of whatever it was attached to.

This repository uses **user-assigned** identities for Workload Identity, in `modules/identity`,
for three concrete reasons: (1) the identity's lifecycle needs to be independent of any one pod
or Deployment, which are themselves ephemeral and have no Azure resource lifecycle of their own
to hang an identity off; (2) it can be pre-provisioned and its federated credential wired up
*before* the workload that will use it ever runs, rather than only coming into existence the
moment that workload first starts; (3) the same identity is reusable — several ServiceAccounts
(or the same ServiceAccount across a rolling restart) can authenticate as the same Azure
identity without recreating anything.

### Federated identity credentials — one primitive, two issuers

This is the detail that makes sections 4 and 5 the same mechanism wearing different clothes. A
**federated identity credential** on an Entra application or managed identity declares: "trust a
token whose `issuer`, `subject`, and `audience` match these exact values — no password, no
certificate required." The GitHub Actions flow and the Kubernetes Workload Identity flow are both,
underneath, this same primitive: the only thing that differs is *who issues the token being
trusted* — GitHub's OIDC token service in one case, the AKS cluster's own OIDC issuer in the
other. Once you see that it's one mechanism, both flows stop looking like separate things to
memorise.

### AKS architecture — control plane, node pools, system/user split

Azure manages the AKS **control plane** (API server, scheduler, `etcd`-equivalent state store) as
a platform service — you don't see or patch its VMs. You manage the **node pools**, which are the
worker VMs that actually run pods. This repository splits node pools into a **system pool**,
tainted `CriticalAddonsOnly=true:NoSchedule` so only cluster add-ons (CoreDNS, `metrics-server`,
the CSI drivers) land on it, and a **user pool** for application workloads. The reasoning —
stopping a runaway application pod from evicting CoreDNS and causing a cluster-wide DNS outage
that looks like a network failure — is laid out in full in
[docs/architecture.md, "Why a system/user node-pool split"](docs/architecture.md#network-design-rationale).

### Azure CNI Overlay vs kubenet vs classic Azure CNI

Three different ways pod IP addresses relate to the VNet:

- **kubenet** — pods get IPs from a cluster-internal range, routed via Azure UDRs. Simple, but
  capped at 400 nodes by the UDR limit, and in long-term maintenance mode — not a sound choice
  for a new cluster today.
- **Classic Azure CNI** — every pod gets a real, VNet-routable IP, allocated from the **node
  subnet itself**. This is powerful (pods are directly addressable from the VNet, Private Link
  can target a pod) but expensive in address space: the subnet has to be sized for
  `nodes × max_pods`, not just `nodes`.
- **Azure CNI Overlay** (chosen here) — nodes get real VNet IPs; pods get IPs from a separate
  overlay CIDR (`10.244.0.0/16`) that never touches the VNet and is NAT-ed to the node's IP on
  egress. Node subnets only need to be sized for *nodes*, which is why this repo's `/20` node
  subnets comfortably support the full migration path to classic CNI later without ever needing
  to be re-IP'd — see [docs/architecture.md, IP address plan](docs/architecture.md#ip-address-plan)
  and [ADR-0003](docs/decisions/0003-azure-cni-overlay.md) for the full trade-off table and the
  explicit rejection of kubenet.

---

## 4. The OIDC flow, step by step

Full sequence diagram: [docs/architecture.md §2](docs/architecture.md#2-github-oidc-to-azure-authentication-flow).
Here it is again in plain language, because the sequence diagram shows *what* happens and this is
about *why each step has to happen in that order*.

1. **The workflow asks for a token it is entitled to ask for.** A GitHub Actions job with
   `permissions: id-token: write` can request a short-lived OIDC ID token from GitHub's own token
   service, scoped to the audience `api://AzureADTokenExchange`. Without that permission line,
   this step simply isn't available to the job — there's no credential to steal because there's
   no credential, full stop.
2. **GitHub signs a JWT describing exactly what's running.** The token's `sub` claim encodes the
   repository *and* the trigger context — `repo:org/repo:ref:refs/heads/main`,
   `repo:org/repo:pull_request`, or `repo:org/repo:environment:prod`. This is GitHub vouching for
   a fact about its own infrastructure: "this specific job, in this specific context, is running
   right now."
3. **The job presents that JWT to Entra ID as a client assertion**, not a password — the OAuth
   `client_credentials` grant with `client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer`.
4. **Entra ID verifies the signature** against GitHub's published JWKS (fetched from the `iss`
   claim's well-known endpoint), confirming the token really was issued by GitHub and hasn't been
   tampered with.
5. **Entra ID looks for a federated identity credential** on the target application whose
   `issuer`, `subject`, and `audience` all equal the token's claims — exactly, case-sensitively,
   no wildcards. This is the trust decision, and it's made entirely by matching three strings
   against values that were declared ahead of time in `bootstrap/github-oidc.tf`.
6. **If and only if all three match**, Entra ID issues a short-lived Azure access token (around
   an hour) for `https://management.azure.com`. Any mismatch — wrong repo, wrong branch, wrong
   environment name, wrong casing — returns `AADSTS70021` and nothing else happens.
7. **The job uses that token to run `terraform plan`/`apply`**, authorised by whatever Azure RBAC
   roles are assigned to the identity (Contributor, and — deliberately, separately — User Access
   Administrator, because this platform needs to create role assignments of its own, like
   `AcrPull`).
8. **State reads and writes go through the same mechanism** against the storage account
   (`ARM_USE_AZUREAD=true`, `Storage Blob Data Contributor`), acquiring a blob lease for the
   duration of the operation.

The one sentence that matters most: **the approval gate and the credential are the same thing.**
A job that declares `environment: prod` in its YAML cannot obtain a `sub: ...:environment:prod`
token until GitHub's own environment protection rules (required reviewers, in this case) let the
job proceed — so there is no way to bypass the reviewer requirement by editing the workflow file,
because the credential simply doesn't exist until the gate is satisfied.

---

## 5. The Workload Identity flow, step by step

Full sequence diagram: [docs/architecture.md §3](docs/architecture.md#3-workload-identity-token-exchange).
Same underlying mechanism as section 4, one layer down, with the AKS cluster itself acting as the
token issuer instead of GitHub.

**Build time (once, by `terraform apply`):**

1. Terraform creates a user-assigned managed identity (`modules/identity`).
2. Terraform reads the AKS cluster's `oidc_issuer_url` — a public endpoint that serves only the
   cluster's JWKS (public keys), nothing sensitive, which is exactly why it's safe for it to be
   public.
3. Terraform creates a federated identity credential on that managed identity, declaring: trust a
   token whose `issuer` is this cluster's OIDC issuer URL, whose `subject` is exactly
   `system:serviceaccount:<namespace>:<serviceaccount-name>`, and whose `audience` is
   `api://AzureADTokenExchange`.
4. The Kubernetes ServiceAccount is annotated with the managed identity's client ID.
5. A role assignment (e.g. `Key Vault Secrets User`) is granted to the managed identity's
   principal ID.

**Run time (every pod start):**

6. A pod using that ServiceAccount carries the label `azure.workload.identity/use: "true"` — and
   critically, this label must be on the **pod template**, not the Deployment's own metadata. The
   mutating admission webhook only inspects the Pod object it's asked to admit.
7. The webhook injects `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_FEDERATED_TOKEN_FILE`
   environment variables and projects a short-lived (one hour, auto-rotated) ServiceAccount token
   into the pod's filesystem. That token's `iss`/`sub`/`aud` are the cluster's OIDC issuer, the
   `system:serviceaccount:...` string, and `api://AzureADTokenExchange` — the exact values the
   federated credential was told to expect.
8. The application (or, in this repo's sample, the Secrets Store CSI driver) reads that token
   file and presents it to Entra ID as a client assertion — the identical exchange as step 3 in
   section 4, just with a different token issuer.
9. Entra ID fetches the cluster's public JWKS from the OIDC issuer URL to verify the signature,
   finds the matching federated credential, and issues a short-lived Azure access token.
10. That token is used against Key Vault (or Storage, or anything else the identity holds a role
    on), authorised entirely by Azure RBAC — no Kubernetes `Secret` object, no `imagePullSecret`,
    no credential ever written to disk anywhere in the chain.

**The one string that has to match exactly:** the `subject` set in Terraform
(`system:serviceaccount:<ns>:<sa>`) and the ServiceAccount's actual namespace and name as deployed.
A typo or a ServiceAccount accidentally created in `default` instead of the intended namespace
produces the identical `AADSTS70021` as a mismatched GitHub subject — see
[failure modes](#8-common-failure-modes) and
[docs/architecture.md, "The two failure modes you will actually hit"](docs/architecture.md#the-two-failure-modes-you-will-actually-hit).

---

## 6. CI/CD for IaC

**Why `plan` runs on every pull request.** `terraform plan` is read-only — it costs nothing,
touches no infrastructure, and finishes in seconds to a couple of minutes. Running it on every PR
turns "what will this change do to Azure?" from a question you answer by applying and seeing,
into a question the PR itself answers, as a reviewable diff, before a single resource is touched.
Checkov (static HCL) and Conftest (plan JSON) both gate the PR at this point too — see
[section 6, "why policy runs on the plan"](#why-policy-as-code-runs-on-the-plan-json-conftest-not-only-on-raw-hcl-checkov)
below.

**Why `apply` requires an environment approval.** `apply` is not read-only — it creates, updates,
and destroys real resources, for real money, with real blast radius. Gating it behind a GitHub
Environment's required-reviewer rule means no single compromised or careless credential can
change production unilaterally — and because of the OIDC subject pinning in
[section 4](#4-the-oidc-flow-step-by-step), that approval requirement isn't just a workflow `if:`
condition someone could quietly delete; the prod-scoped Azure token literally cannot be minted
until GitHub admits the job into the protected environment.

**Configuration drift, and how `.github/workflows/drift-detection.yml` catches it.** Drift is any
divergence between what Terraform's state says should exist and what actually exists in
Azure — caused by a manual portal change, another pipeline touching the same resources, or an
Azure platform service mutating something after creation. Left undetected, drift means the *next*
`terraform apply` from this repository produces a confusing, unreviewed, and sometimes dangerous
diff, because Terraform is reconciling against a state that no longer matches reality. The drift
workflow runs a scheduled `terraform plan` against live state on a cron, with no `apply` attached,
and fails the job (or opens an issue) if the plan is non-empty — turning an invisible, slowly
accumulating problem into a visible one on a predictable cadence, well before anyone is forced to
discover it mid-incident.

**Why policy-as-code runs on the plan JSON (Conftest), not only on raw HCL (Checkov).** These
catch genuinely different classes of problems, and that's by design, not redundancy:

- **Checkov** scans the HCL source statically. It's fast, needs no Azure access and no plan, and
  ships a large, maintained library of generic CIS/NIST-aligned checks nobody on this team has to
  write or keep current. Its blind spot: it can't see *computed* values — anything that only
  exists after Terraform resolves variables, data sources, and module outputs — and it can't see
  what a change actually *does* (is this value changing from `true` to `false`? is this resource
  being destroyed?), only what the source says.
- **Conftest** evaluates `terraform show -json tfplan` — the fully resolved plan, after every
  variable, data source, and module reference has been computed, showing exactly which resources
  are being created, updated, or destroyed and with what final argument values. This is the only
  place a rule can say, precisely, "this specific resource, in this plan, is turning off purge
  protection" — and it's where this platform's own rules live (the required tag set, the naming
  convention, the dev-only Key Vault purge-protection exception), because a generic scanner has no
  way to know what `cost_center` means to this specific team.

Running both in the same job means static issues are caught even on a change too small to produce
an interesting plan, and plan-level issues are caught even when the HCL in isolation looks
perfectly fine. See [policy/README.md](policy/README.md) for the full rule catalogue and the
reasoning behind every documented exception.

---

## 7. Interview questions you can now answer

**Q: How do you manage Terraform state for a team?**
A: Remote state in a backend that supports locking — here, an Azure Storage blob container with
native blob-lease locking, so a second `plan` or `apply` against the same environment blocks
instead of racing. Access is via Entra ID RBAC (`Storage Blob Data Contributor`/`Owner`), not a
shared storage account key, so access can be granted, audited, and revoked per identity. State is
one file **per environment**, not one shared file, so a mistake in dev's state can't corrupt
prod's.

**Q: How do you prevent someone from applying to prod from their laptop?**
A: Two independent layers. First, the prod-scoped Azure credential is obtainable only via a
GitHub OIDC federated identity credential whose subject requires the job to be running inside the
`prod` GitHub Environment — and GitHub only admits a job into a protected environment after its
required reviewers approve, so there's no token to steal or forge from a laptop. Second, as
defence in depth, `make apply-prod` exists only as a documented, logged break-glass path that
demands a typed confirmation and loudly tells the operator they're bypassing the review trail.

**Q: What is configuration drift, and how do you detect it?**
A: Drift is any gap between what Terraform's state believes exists and what's actually in Azure —
from a manual change, another pipeline, or a platform-side mutation. It's detected with a
scheduled `terraform plan` (no `apply`) against live state; a non-empty plan on that schedule
means something changed outside Terraform's control, and the job fails or opens an issue so it's
caught on a cadence rather than discovered mid-incident.

**Q: Why OIDC instead of a service principal secret?**
A: A service principal secret is a long-lived bearer credential — anyone who obtains it can
authenticate as that identity from anywhere, it eventually expires and breaks pipelines
unexpectedly, and a leak is often invisible in audit logs (it just looks like a normal
authenticated login). OIDC federation replaces it with a short-lived token GitHub mints that
describes the exact job running, which Entra ID trusts only if its issuer, subject, and audience
match a credential declared in advance. There is nothing durable to leak, rotate, or revoke — the
"credential" is a runtime assertion, not a stored secret.

**Q: How do pods authenticate to Azure without secrets?**
A: Workload Identity — the same federation primitive as the CI flow, one layer down. A Kubernetes
ServiceAccount is bound to a user-assigned managed identity via a federated identity credential
whose issuer is the AKS cluster's own OIDC issuer. A mutating webhook projects a short-lived,
auto-rotated ServiceAccount token into any pod labelled for Workload Identity use; the pod
presents that token to Entra ID and gets back an Azure access token. No Kubernetes `Secret`
object and no `imagePullSecret` ever exist.

**Q: `count` vs `for_each`, and why does it matter for state?**
A: `count` addresses resource instances by index; remove an item from the middle of the input
list and every instance after it shifts address, so Terraform plans to destroy and recreate
resources that never actually changed, purely because their position did. `for_each` addresses
instances by a stable key from a map or set, so removing one entry affects only that entry's
state address. This repository uses `for_each` everywhere a collection of similar resources is
created — the GitHub federated credentials being the clearest example — specifically so adding or
removing one entry never perturbs any other instance's state address.

**Q: How do you refactor a resource without destroying it?**
A: `terraform state mv` renames a resource's address in state without touching the real
infrastructure, for a manual one-off refactor. For a change you want captured in code and
reviewed, a `moved` block declares the same intent declaratively — "this address used to be X, it
is now Y, do not plan a destroy/create for it" — and survives in version control as a record of
the refactor, unlike a one-time CLI command.

**Q: How do you structure Terraform for multiple environments?**
A: Directory-per-environment: `envs/dev`, `envs/staging`, `envs/prod`, each a separate root module
with its own state file, its own backend configuration, and its own `.tfvars`, all calling the
*same* shared modules under `modules/`. The environments differ only by configuration values, not
by code path — the one structural exception being `lifecycle { prevent_destroy = true }` on
specific prod resources. This keeps the blast radius of any one environment's state, credentials,
and approval gate completely separate from the others.

**Q: What's the difference between a module and a root module?**
A: A root module is the configuration Terraform is invoked against directly — here, each
`envs/<env>/` directory, which owns a state file and a backend. A (child) module is a reusable
unit called from a root module (or from another module) via a `module` block; it has no state file
of its own and no independent existence outside whatever is calling it. In this repository every
`modules/*` directory is a child module, and the only root modules are `bootstrap/` and the three
`envs/<env>/` directories.

**Q: How do you avoid secrets in Terraform state?**
A: You mostly don't — fully. State can and does contain sensitive attribute values for some
resource types, so the real controls are: encrypt the backend at rest (this repo's state storage
account has infrastructure-level double encryption on), restrict who can read it via Azure RBAC
data-plane roles rather than a shared key, enable blob versioning and soft delete for recoverable
audit history, and — where possible — avoid ever passing a secret as a plain resource argument in
the first place by referencing it from Key Vault at the point of use instead of writing it into
Terraform configuration or outputs.

**Q: What's a private AKS cluster, and when do you need one?**
A: A private cluster exposes its API server only via a private endpoint inside your VNet, with no
public IP and no public DNS record resolving to a reachable address — `kubectl` can only reach it
from inside the network (or something peered/VPN'd into it). This repository enables it only in
prod, because it closes off API-server exposure to the public internet entirely, at the cost of
needing private connectivity (a jumpbox, VPN, or peered network) for every operator who needs
`kubectl` access, including CI runners. Dev and staging stay public, accepted as a dev convenience
and validated in staging before the private-cluster path is relied on in prod.

**Q: How does the cluster autoscaler interact with node pools?**
A: Each node pool that opts in declares a `min_count` and `max_count`; the autoscaler watches for
unschedulable pods (resource requests that don't fit on any current node) and scales the pool up
within that range, or scales down nodes that are underutilised and whose pods can be rescheduled
elsewhere, subject to pod disruption budgets. This repo's user pool autoscales (3–10 nodes in
prod); the system pool is fixed-size, since its workload (cluster add-ons) is predictable and
doesn't benefit from elastic scaling.

**Q: How do you roll out a Kubernetes version upgrade safely?**
A: Upgrade the control plane first, then node pools one at a time rather than all at once, relying
on AKS's node surge/drain behaviour (a configurable surge count of extra nodes created before
existing ones are cordoned and drained) to avoid a capacity dip. Validate in a lower environment
first — staging before prod — and watch for deprecated API usage ahead of the upgrade, since a
minor version bump can remove APIs that workloads still depend on.

**Q: What's the blast radius of a bad `terraform apply`, and how do you limit it?**
A: Without isolation, it's "everything Terraform manages" — one mistake in one environment can
touch every environment's resources if they share state. This repository limits it structurally:
one state file per environment, one set of credentials per environment (via per-environment OIDC
subjects), one approval gate per environment, and `prevent_destroy` on prod's genuinely
irreplaceable resources. A bad apply in dev cannot touch staging or prod state, because they are
not the same state file and not reachable with the same credential.

**Q: How do you handle Terraform provider version upgrades safely?**
A: Pin a version constraint in `required_providers` (this repo uses `~> 4.0`), commit
`.terraform.lock.hcl` so every run — local or CI — resolves to the identical provider build, and
upgrade deliberately with `terraform init -upgrade` as its own reviewed change, ideally run
through `plan` on a non-prod environment first to catch any behavioural change the new version
introduces before it reaches prod.

**Q: Why Premium SKU for Key Vault/ACR in prod but not dev?**
A: Premium unlocks capabilities dev doesn't need and prod does: for Key Vault, HSM-backed keys;
for ACR, private endpoints, customer-managed keys, geo-replication, content trust, and scoped
repository tokens. Dev runs Basic/Standard because it's cost-sensitive and short-lived — paying
for Premium's network isolation and replication features on an environment that gets destroyed
nightly buys nothing. Staging and prod step up specifically where those features (especially
private networking) start to matter for a realistic security posture.

---

## 8. Common failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `terraform apply`/`plan` hangs or errors "state is locked" | A previous `apply` was interrupted (CI job killed, laptop lost network) while still holding the blob lease | Confirm no other `apply` is genuinely in flight, then `terraform force-unlock <lock-id>`. Never force-unlock while a real operation might still be running — that's how two applies corrupt the same state. |
| `Error: subscription_id is a required provider property` (or similar) right after upgrading `azurerm` | azurerm v4 removed the implicit inference of subscription ID from the Azure CLI's logged-in context that v3 provided; the provider block must set it explicitly now | Add `subscription_id = "..."` (or `ARM_SUBSCRIPTION_ID`) explicitly to the provider configuration — don't rely on `az login` context alone. |
| `apply` fails with a SKU/quota error for a VM size or region | The subscription's quota for that VM family in that region is below what the node pool needs, or the SKU isn't offered in that region at all | Check the Quotas blade in the Azure portal, request a quota increase, or change `location`/`vm_size` in the environment's `.tfvars` to a SKU the subscription and region both support. |
| Pod goes `ImagePullBackOff` with a 401 immediately after `apply` completes, even though `AcrPull` was just assigned | Entra ID role assignment replication lag — the RBAC change hasn't propagated to the data plane yet | Wait roughly 30–60 seconds and let the pod retry (or delete it to force a retry) before assuming the role assignment or kubelet identity is misconfigured. |
| Recreating a Key Vault with the same name fails, or a previously-deleted vault's name is "already in use" | Purge protection is enabled and is irreversible once turned on — a deleted vault stays recoverable (and its name reserved) for the full soft-delete retention window, with no way to force-purge it early | Wait out the retention period, or deploy under a new name. This is exactly why purge protection is deliberately left **off** in dev, where vaults are created and destroyed routinely. |
| A teammate's local `plan` shows unexpected changes that CI's `plan` doesn't (or vice versa) | Provider version drift — their local provider cache resolved a different patch version than CI's, usually because `.terraform.lock.hcl` wasn't committed or was out of date | Commit `.terraform.lock.hcl`, and run `terraform init -upgrade` only as a deliberate, separate, reviewed change — never let it happen implicitly on whoever runs `init` next. |

---

See also: [README.md](README.md) for the showcase view, [docs/architecture.md](docs/architecture.md)
for the full topology and sequence diagrams, and [policy/README.md](policy/README.md) for the
complete policy-as-code rule catalogue.

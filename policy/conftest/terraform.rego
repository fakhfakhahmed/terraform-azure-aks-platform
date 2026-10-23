# =============================================================================
# terraform-azure-aks-platform :: preventive policy-as-code (plan-time)
# =============================================================================
#
# WHAT THIS EVALUATES
# -------------------
# The input to these rules is the JSON rendering of a Terraform plan:
#
#     terraform plan -out=tfplan
#     terraform show -json tfplan > tfplan.json
#     conftest test --policy policy/conftest tfplan.json
#
# Terraform 1.x emits a document shaped like:
#
#     {
#       "format_version": "1.2",
#       "terraform_version": "1.9.x",
#       "planned_values": { "root_module": { ... } },   # the desired end state
#       "resource_changes": [                            # the per-resource diff
#         {
#           "address": "module.aks.azurerm_kubernetes_cluster.this",
#           "mode": "managed" | "data",
#           "type": "azurerm_kubernetes_cluster",
#           "name": "this",
#           "change": {
#             "actions": ["create"] | ["update"] | ["delete"] | ["no-op"]
#                        | ["delete","create"]  (replace)
#             "before": {...} | null,
#             "after": {...} | null,
#             "after_unknown": { "id": true, ... }        # computed at apply
#           }
#         }
#       ],
#       "configuration": { ... }                         # the HCL, de-sugared
#     }
#
# We work almost exclusively from `resource_changes` because it is the only
# section that tells us *what is about to happen*. `planned_values` describes
# the whole end state including resources that are not changing, and
# `configuration` still contains unresolved expressions - neither is a good
# basis for a gate that must be precise about the blast radius of a PR.
#
# CONVENTIONS
# -----------
#   * `deny` -> blocking. CI fails, the PR cannot merge.
#   * `warn` -> advisory. Surfaces in the conftest output, exit code stays 0.
#   * Every message starts with the resource address so the engineer can jump
#     straight to the offending resource, and ends with the remediation.
#   * Unset / null / absent booleans are collapsed to `false` (fail closed).
#     See `attr_bool` for the reasoning.
#
# Rego v1 syntax (`if` / `contains` / `in`) - requires OPA >= 0.60, which is
# what conftest >= 0.46 embeds. `import rego.v1` makes the file forward
# compatible with OPA 1.x where this syntax is mandatory.
# =============================================================================

package main

import rego.v1

# -----------------------------------------------------------------------------
# Repository contract - the single source of truth for the tagging standard.
# Keep this list in sync with `locals.common_tags` in envs/*/main.tf and with
# policy/azure-policy/require-tags.json.
# -----------------------------------------------------------------------------

# Tags every managed, taggable Azure resource must carry.
required_tags := [
	"environment", # dev | staging | prod
	"project", # always "terraform-azure-aks-platform"
	"owner", # team or individual accountable for the resource
	"managed_by", # always "terraform" - proves nothing was hand-crafted
	"cost_center", # chargeback / showback dimension
]

# TLS floor for data-plane endpoints. TLS1_3 is accepted so the rule does not
# become a blocker the day azurerm exposes it; anything below TLS1_2 is denied.
accepted_tls_versions := {"TLS1_2", "TLS1_3"}

# Ports that must never be reachable from the public internet. These are the
# interactive management planes - the exact thing opportunistic scanners sweep
# for. Legitimate access goes through Bastion / Just-In-Time / a private link.
management_ports := {22, 3389}

# Source address prefixes that effectively mean "the whole internet".
# `Internet` is an Azure Service Tag; `*` and `0.0.0.0/0` are the IPv4 any
# forms; `::/0` is the IPv6 equivalent; `Any` is accepted by ARM as a synonym.
internet_source_prefixes := {"*", "0.0.0.0/0", "::/0", "internet", "any"}

# Azure resource types that genuinely have NO `tags` property in ARM. Tagging
# rules must skip these or they produce unfixable findings, which is the
# fastest way to get a policy gate disabled by an annoyed team.
#
# NOTE: `azurerm_private_dns_zone_virtual_network_link` IS taggable and is
# deliberately NOT in this list - it is a common false assumption.
# `azurerm_kubernetes_cluster_node_pool` is also taggable (node pool tags are
# propagated to the underlying VMSS) and is likewise absent here.
untaggable_types := {
	# RBAC and identity plumbing - ARM models these as pure link objects.
	"azurerm_role_assignment",
	"azurerm_role_definition",
	"azurerm_federated_identity_credential",
	"azurerm_key_vault_access_policy",
	# Child resources that live inside a tagged parent and inherit its
	# cost/ownership attribution (subnet -> vnet, rule -> nsg, route -> rt).
	"azurerm_subnet",
	"azurerm_network_security_rule",
	"azurerm_route",
	"azurerm_virtual_network_peering",
	"azurerm_subnet_network_security_group_association",
	"azurerm_subnet_route_table_association",
	"azurerm_container_registry_scope_map",
	"azurerm_container_registry_token",
	"azurerm_log_analytics_workspace_table",
	# Control-plane / observability wiring - no tags property.
	"azurerm_monitor_diagnostic_setting",
	"azurerm_monitor_data_collection_rule_association",
	"azurerm_management_lock",
	# Governance objects.
	"azurerm_policy_definition",
	"azurerm_subscription_policy_assignment",
	"azurerm_resource_group_policy_assignment",
}

# =============================================================================
# Generic helpers
# =============================================================================

# All resource changes in the plan, defaulting to an empty list so that an
# empty or malformed document yields "no findings" rather than an eval error.
resource_changes := as_array(object.get(input, "resource_changes", []))

# Coerce a possibly-absent / possibly-null plan attribute to an array.
# Terraform renders an unset list argument as JSON `null`, not `[]`, so a bare
# `some x in rc.change.after.destination_port_ranges` would blow up.
as_array(x) := x if {
	is_array(x)
}

as_array(x) := [] if {
	not is_array(x)
}

# Same idea for objects.
as_object(x) := x if {
	is_object(x)
}

as_object(x) := {} if {
	not is_object(x)
}

# The post-apply attribute map for a resource. `after` is null for deletes,
# which is why every caller goes through this helper instead of reaching into
# `rc.change.after` directly.
after_object(rc) := as_object(object.get(rc.change, "after", {}))

# The map of attributes Terraform could not resolve at plan time.
after_unknown_object(rc) := as_object(object.get(rc.change, "after_unknown", {}))

# Read a boolean attribute, treating absent / null as `false`.
#
# WHY FAIL CLOSED: the azurerm provider renders an optional boolean that the
# practitioner never set as JSON `null` (or omits it entirely for older schema
# versions). For every security control we assert on, "not configured" and
# "explicitly disabled" have identical risk, so collapsing both to `false` is
# the correct - and safer - interpretation. The cost is that a value which is
# genuinely unknown at plan time (because it is derived from another resource)
# would be reported; in practice none of these flags are ever computed.
attr_bool(obj, key) := value if {
	value := obj[key]
	is_boolean(value)
}

attr_bool(obj, key) := false if {
	not is_boolean(object.get(obj, key, null))
}

# Read a string attribute, treating absent / null as the empty string.
attr_string(obj, key) := value if {
	value := obj[key]
	is_string(value)
}

attr_string(obj, key) := "" if {
	not is_string(object.get(obj, key, null))
}

# -----------------------------------------------------------------------------
# Change-set filtering
# -----------------------------------------------------------------------------

# True when this resource change is something we are allowed to have an opinion
# about.
#
# Two filters, both deliberate:
#
#   1. `mode == "managed"` - data sources (`mode == "data"`) describe resources
#      Terraform is only *reading*. They frequently belong to another team or
#      another subscription, we cannot remediate them, and flagging them would
#      make the gate unactionable.
#
#   2. actions contain "create" or "update" - we only gate what this plan is
#      about to bring into existence or mutate. A pure `delete` removes risk,
#      and `no-op` means the resource already exists exactly as-is; failing a
#      PR for a pre-existing resource that it does not touch turns every
#      unrelated change into a blocked PR and is the classic reason policy
#      gates get bypassed. A replace is rendered as ["delete","create"] and is
#      correctly caught here because it contains "create".
#
# Pre-existing violations are the job of the *detective* layer (Azure Policy
# compliance state), not of the PR gate.
created_or_updated(rc) if {
	rc.mode == "managed"
	some action in rc.change.actions
	action in {"create", "update"}
}

# Convenience: iterate only the changes of a given resource type.
changed_resources_of_type(resource_type) := [rc |
	some rc in resource_changes
	created_or_updated(rc)
	rc.type == resource_type
]

# -----------------------------------------------------------------------------
# Tag helpers
# -----------------------------------------------------------------------------

# The resource's tag map, normalised to an object.
resource_tags(rc) := tags if {
	tags := object.get(after_object(rc), "tags", null)
	is_object(tags)
}

resource_tags(rc) := {} if {
	not is_object(object.get(after_object(rc), "tags", null))
}

# A tag "counts" only when it is present AND carries a non-blank string value.
# `environment = ""` is not compliance, it is a typo that defeats chargeback.
has_tag_value(tags, name) if {
	value := tags[name]
	is_string(value)
	trim_space(value) != ""
}

# Normalised environment of a resource, derived from its own `environment`
# tag. Returns "" when the tag is missing - in which case the untagged-resource
# rule will already have fired, so environment-conditional rules degrade to
# their strict branch rather than silently passing.
environment_of(rc) := lower(trim_space(attr_string(resource_tags(rc), "environment")))

is_dev(rc) if {
	environment_of(rc) == "dev"
}

# True when the provider schema actually exposes a `tags` argument for this
# resource. `terraform show -json` emits every *known* attribute in
# `change.after` (null when unset) and every computed-at-apply attribute in
# `change.after_unknown`. If `tags` appears in neither, the resource type has
# no tags argument at all and must be skipped.
#
# This is a schema-driven safety net *in addition to* the hand-maintained
# `untaggable_types` list: the list gives fast, documented, intentional skips;
# this check stops a resource type nobody thought of from producing a finding
# that cannot be fixed.
schema_has_tags(rc) if {
	"tags" in object.keys(after_object(rc))
}

schema_has_tags(rc) if {
	"tags" in object.keys(after_unknown_object(rc))
}

# A resource is in scope for tag enforcement when it is an azurerm resource
# (random_*, tls_*, time_*, null_resource and friends have no concept of Azure
# tags), is not on the documented untaggable list, and its schema has `tags`.
taggable(rc) if {
	startswith(rc.type, "azurerm_")
	not rc.type in untaggable_types
	schema_has_tags(rc)
}

# -----------------------------------------------------------------------------
# NSG port-range membership - the centrepiece helper
# -----------------------------------------------------------------------------
#
# Azure expresses destination ports in three shapes and an NSG rule may use
# either the singular `destination_port_range` OR the plural
# `destination_port_ranges` (never both). Each element is one of:
#
#     "22"      a single port
#     "*"       every port, 0-65535
#     "20-30"   an inclusive range
#
# A rule "exposes" a port when ANY of its specifications covers it. Getting
# this wrong in either direction is expensive: too loose and an SSH hole ships,
# too strict and every port-443 ingress rule fails the build.

# Case 1: the wildcard. `*` is Azure's "all ports" and covers everything.
port_spec_covers(spec, _) if {
	spec == "*"
}

# Case 2: a single numeric port. The regex guard means `to_number` is never
# handed a non-numeric string, so a malformed spec yields "undefined" (no
# match) instead of an evaluation error.
port_spec_covers(spec, port) if {
	regex.match(`^[0-9]+$`, spec)
	to_number(spec) == port
}

# Case 3: an inclusive "low-high" range. Both bounds are validated as integers
# before comparison; the comparison is inclusive on both ends, matching Azure.
port_spec_covers(spec, port) if {
	parts := split(spec, "-")
	count(parts) == 2
	regex.match(`^[0-9]+$`, parts[0])
	regex.match(`^[0-9]+$`, parts[1])
	to_number(parts[0]) <= port
	port <= to_number(parts[1])
}

# Every destination port specification declared on a rule object, from both the
# singular and the plural argument, as a single set.
destination_port_specs(rule) := specs if {
	singular := {s |
		s := object.get(rule, "destination_port_range", null)
		is_string(s)
	}

	plural := {s |
		some s in as_array(object.get(rule, "destination_port_ranges", null))
		is_string(s)
	}

	specs := singular | plural
}

# True when the rule's source is the public internet, in either the singular
# `source_address_prefix` or the plural `source_address_prefixes` form.
# Comparison is lower-cased because ARM accepts "Internet", "internet" and
# "INTERNET" interchangeably.
source_is_internet(rule) if {
	prefix := object.get(rule, "source_address_prefix", null)
	is_internet_prefix(prefix)
}

source_is_internet(rule) if {
	some prefix in as_array(object.get(rule, "source_address_prefixes", null))
	is_internet_prefix(prefix)
}

is_internet_prefix(prefix) if {
	is_string(prefix)
	lower(trim_space(prefix)) in internet_source_prefixes
}

# The set of management ports a given NSG rule object exposes to the internet.
# Undefined (rather than empty) when the rule is not an internet-sourced
# inbound Allow, so callers short-circuit cleanly.
exposed_management_ports(rule) := ports if {
	object.get(rule, "direction", "") == "Inbound"
	object.get(rule, "access", "") == "Allow"
	source_is_internet(rule)

	ports := {port |
		some port in management_ports
		some spec in destination_port_specs(rule)
		port_spec_covers(spec, port)
	}
}

# True when at least one `azurerm_private_endpoint` is being created or updated
# in this plan. Used as a heuristic signal that the platform is being built
# with private networking, which has SKU implications for ACR.
plan_declares_private_endpoint if {
	count(changed_resources_of_type("azurerm_private_endpoint")) > 0
}

# =============================================================================
# DENY rules - blocking. These fail CI.
# =============================================================================

# -----------------------------------------------------------------------------
# 1. Storage: anonymous (public) blob/container access must be impossible.
#
# azurerm v4 argument: `allow_nested_items_to_be_public` (renamed from the v2
# era `allow_blob_public_access`). When true, a container can be flipped to
# public by anyone with data-plane rights and the account silently becomes an
# open bucket. Turning it off at the account level makes that unreachable.
# -----------------------------------------------------------------------------
deny contains msg if {
	some rc in resource_changes
	created_or_updated(rc)
	rc.type == "azurerm_storage_account"
	attr_bool(after_object(rc), "allow_nested_items_to_be_public")

	msg := sprintf(
		"%s: storage account allows anonymous public access to blobs/containers. Set `allow_nested_items_to_be_public = false` and serve content through a SAS, a private endpoint, or Azure CDN with managed identity.",
		[rc.address],
	)
}

# -----------------------------------------------------------------------------
# 2. AKS must use Workload Identity, which requires the OIDC issuer.
#
# Workload Identity federates a Kubernetes ServiceAccount token to an Entra ID
# application via the cluster's OIDC issuer. `workload_identity_enabled = true`
# without `oidc_issuer_enabled = true` is rejected by the API, so we assert
# both and say so in the message - it saves the next engineer a round trip.
#
# The alternative (aad-pod-identity / kubelet identity) hands every pod on the
# node the node's identity. That is a lateral-movement primitive.
# -----------------------------------------------------------------------------
deny contains msg if {
	some rc in resource_changes
	created_or_updated(rc)
	rc.type == "azurerm_kubernetes_cluster"
	after := after_object(rc)
	not attr_bool(after, "workload_identity_enabled")

	msg := sprintf(
		"%s: AKS cluster does not enable Workload Identity. Set `workload_identity_enabled = true` (and `oidc_issuer_enabled = true`, which it depends on) so pods obtain Entra ID tokens through a federated ServiceAccount instead of sharing the kubelet identity.",
		[rc.address],
	)
}

deny contains msg if {
	some rc in resource_changes
	created_or_updated(rc)
	rc.type == "azurerm_kubernetes_cluster"
	after := after_object(rc)
	not attr_bool(after, "oidc_issuer_enabled")

	msg := sprintf(
		"%s: AKS cluster does not expose an OIDC issuer. Set `oidc_issuer_enabled = true`; Workload Identity federation is built on this issuer and cannot function without it.",
		[rc.address],
	)
}

# -----------------------------------------------------------------------------
# 3. AKS local (certificate-based) admin accounts must be disabled.
#
# The cluster-admin client certificate returned by `az aks get-credentials
# --admin` bypasses Entra ID entirely: no MFA, no conditional access, no
# per-user audit trail, and it cannot be revoked without rotating the cluster
# CA. Disabling it forces every human and pipeline through Entra ID + RBAC.
# -----------------------------------------------------------------------------
deny contains msg if {
	some rc in resource_changes
	created_or_updated(rc)
	rc.type == "azurerm_kubernetes_cluster"
	not attr_bool(after_object(rc), "local_account_disabled")

	msg := sprintf(
		"%s: AKS cluster keeps local admin accounts enabled. Set `local_account_disabled = true` and grant access via `azure_active_directory_role_based_access_control` so authentication is auditable, MFA-capable and revocable.",
		[rc.address],
	)
}

# -----------------------------------------------------------------------------
# 4. Every taggable managed resource carries the full required tag set.
#
# Tags drive cost allocation, ownership routing for incidents, and the
# "is this Terraform-managed?" question during drift triage. A resource missing
# `owner` is a resource nobody will claim at 3am.
# -----------------------------------------------------------------------------
deny contains msg if {
	some rc in resource_changes
	created_or_updated(rc)
	taggable(rc)

	tags := resource_tags(rc)
	missing := sort([name |
		some name in required_tags
		not has_tag_value(tags, name)
	])

	count(missing) > 0

	msg := sprintf(
		"%s: missing or blank required tag(s) %v. Every taggable resource must carry %v - pass `tags = local.common_tags` from the environment root module (managed_by must be \"terraform\", project must be \"terraform-azure-aks-platform\").",
		[rc.address, missing, required_tags],
	)
}

# -----------------------------------------------------------------------------
# 5. ACR admin user must be disabled.
#
# The admin account is a single shared username/password with push rights to
# every repository in the registry. It cannot be scoped, cannot be attributed
# to a person, and is the credential that ends up pasted into a Kubernetes
# imagePullSecret and then into a git repo. Use AcrPull/AcrPush role
# assignments against a managed identity instead.
# -----------------------------------------------------------------------------
deny contains msg if {
	some rc in resource_changes
	created_or_updated(rc)
	rc.type == "azurerm_container_registry"
	attr_bool(after_object(rc), "admin_enabled")

	msg := sprintf(
		"%s: container registry has the shared admin user enabled. Set `admin_enabled = false` and grant `AcrPull` to the AKS kubelet identity and `AcrPush` to the CI workload identity instead.",
		[rc.address],
	)
}

# -----------------------------------------------------------------------------
# 6. No inbound internet access to SSH (22) or RDP (3389).
#
# Covered in both shapes the azurerm provider supports:
#   a) standalone `azurerm_network_security_rule` resources
#   b) inline `security_rule` blocks on `azurerm_network_security_group`
# -----------------------------------------------------------------------------
deny contains msg if {
	some rc in resource_changes
	created_or_updated(rc)
	rc.type == "azurerm_network_security_rule"

	after := after_object(rc)
	some port in exposed_management_ports(after)

	msg := sprintf(
		"%s: NSG rule %q allows inbound traffic from the internet to management port %d. Restrict `source_address_prefix(es)` to a corporate CIDR or a Service Tag, or front the access with Azure Bastion / a private endpoint.",
		[rc.address, attr_string(after, "name"), port],
	)
}

deny contains msg if {
	some rc in resource_changes
	created_or_updated(rc)
	rc.type == "azurerm_network_security_group"

	some rule in as_array(object.get(after_object(rc), "security_rule", null))
	some port in exposed_management_ports(rule)

	msg := sprintf(
		"%s: inline security_rule %q allows inbound traffic from the internet to management port %d. Restrict `source_address_prefix(es)` to a corporate CIDR or a Service Tag, or front the access with Azure Bastion / a private endpoint.",
		[rc.address, attr_string(rule, "name"), port],
	)
}

# -----------------------------------------------------------------------------
# 7. Key Vault purge protection - required everywhere except dev.
#
# Purge protection blocks the permanent deletion of a soft-deleted vault (and
# of its keys/secrets) for the duration of the retention window. Without it, a
# compromised or mistaken principal with Contributor can delete a vault *and*
# purge it, destroying the key material that encrypts downstream data - an
# unrecoverable event.
#
# DOCUMENTED EXCEPTION - `environment = dev`:
#   Purge protection is irreversible: once enabled on a vault it can never be
#   turned off, and the vault name stays reserved for the full retention
#   period (up to 90 days) after deletion. In dev, vaults are created and
#   destroyed on every feature branch, so enabling it would permanently burn
#   the deterministic name produced by our naming convention
#   (afk-dev-weu-platform-kv) and block the next `terraform apply`. The dev
#   subscription holds no production key material, so the residual risk is
#   accepted. Soft delete still applies (see note below), so an accidental
#   delete in dev is still recoverable within the retention window.
#
# NOTE on soft delete: azurerm v4 removed the `soft_delete_enabled` argument
# entirely because Azure made soft delete mandatory and non-disableable on all
# vaults. The only knob left is `soft_delete_retention_days` (7-90). There is
# therefore nothing to assert about soft delete itself - purge protection is
# the whole control surface.
# -----------------------------------------------------------------------------
deny contains msg if {
	some rc in resource_changes
	created_or_updated(rc)
	rc.type == "azurerm_key_vault"
	not attr_bool(after_object(rc), "purge_protection_enabled")
	not is_dev(rc)

	msg := sprintf(
		"%s: Key Vault in environment %q has purge protection disabled. Set `purge_protection_enabled = true` so a soft-deleted vault cannot be permanently purged before `soft_delete_retention_days` elapses. Only `environment = dev` is exempt (documented in policy/README.md).",
		[rc.address, environment_of(rc)],
	)
}

# -----------------------------------------------------------------------------
# 8. Storage transport security: TLS 1.2 floor and HTTPS-only.
#
# azurerm v4 renamed `enable_https_traffic_only` -> `https_traffic_only_enabled`
# as part of the provider-wide "boolean arguments end in _enabled" cleanup.
# Code written against azurerm v3 will silently fail to set the new argument,
# so this rule doubles as a migration guard.
# -----------------------------------------------------------------------------
deny contains msg if {
	some rc in resource_changes
	created_or_updated(rc)
	rc.type == "azurerm_storage_account"

	tls := attr_string(after_object(rc), "min_tls_version")
	not tls in accepted_tls_versions

	msg := sprintf(
		"%s: storage account negotiates TLS below the 1.2 floor (min_tls_version = %q). Set `min_tls_version = \"TLS1_2\"`; TLS 1.0/1.1 are deprecated and fail most compliance baselines.",
		[rc.address, tls],
	)
}

deny contains msg if {
	some rc in resource_changes
	created_or_updated(rc)
	rc.type == "azurerm_storage_account"
	not attr_bool(after_object(rc), "https_traffic_only_enabled")

	msg := sprintf(
		"%s: storage account accepts plaintext HTTP. Set `https_traffic_only_enabled = true` (azurerm v4 name; this was `enable_https_traffic_only` in v3) so credentials and payloads are never sent in the clear.",
		[rc.address],
	)
}

# -----------------------------------------------------------------------------
# 9. AKS nodes must not get public IPs.
#
# A node with a public IP puts the kubelet, the container runtime and every
# hostNetwork pod directly on the internet, protected only by an NSG. Egress
# belongs behind a NAT Gateway, an Azure Firewall, or the AKS-managed outbound
# load balancer. Checked on both the standalone node pool resource and the
# cluster's inline `default_node_pool` block.
#
# azurerm v4 argument: `node_public_ip_enabled` (v3 called it
# `enable_node_public_ip`).
# -----------------------------------------------------------------------------
deny contains msg if {
	some rc in resource_changes
	created_or_updated(rc)
	rc.type == "azurerm_kubernetes_cluster_node_pool"
	attr_bool(after_object(rc), "node_public_ip_enabled")

	msg := sprintf(
		"%s: AKS node pool assigns public IPs to its nodes. Set `node_public_ip_enabled = false` and route egress through a NAT Gateway or Azure Firewall.",
		[rc.address],
	)
}

deny contains msg if {
	some rc in resource_changes
	created_or_updated(rc)
	rc.type == "azurerm_kubernetes_cluster"

	some pool in as_array(object.get(after_object(rc), "default_node_pool", null))
	attr_bool(pool, "node_public_ip_enabled")

	msg := sprintf(
		"%s: the AKS default_node_pool %q assigns public IPs to its nodes. Set `node_public_ip_enabled = false` inside the `default_node_pool` block and route egress through a NAT Gateway or Azure Firewall.",
		[rc.address, attr_string(pool, "name")],
	)
}

# =============================================================================
# WARN rules - advisory. Reported, but CI still passes.
#
# These encode "you probably want this, and if you don't, say why in the PR"
# rather than "this is unsafe". Keeping them separate from deny is what stops
# the deny set from being diluted into background noise.
# =============================================================================

# -----------------------------------------------------------------------------
# W1. Storage account reachable from the public internet.
#
# Deliberately a warn and not a deny: some accounts legitimately need public
# reachability (static website hosting, a public artifact mirror, Terraform
# remote state accessed from GitHub-hosted runners that have no private
# connectivity). The expectation is a `network_rules` block or a private
# endpoint; the warn makes the choice visible in the PR.
# -----------------------------------------------------------------------------
warn contains msg if {
	some rc in resource_changes
	created_or_updated(rc)
	rc.type == "azurerm_storage_account"
	attr_bool(after_object(rc), "public_network_access_enabled")

	msg := sprintf(
		"%s: storage account is reachable from the public internet (`public_network_access_enabled = true`). Prefer `public_network_access_enabled = false` with a private endpoint; if public access is required, pair it with a `network_rules` block that defaults to Deny and justify it in the PR description.",
		[rc.address],
	)
}

# -----------------------------------------------------------------------------
# W2. AKS on the Free SKU tier outside dev.
#
# The Free tier has no control-plane SLA (only a 99.5% availability target) and
# a lower API-server scale ceiling. Fine for dev, wrong for anything a customer
# or an on-call engineer depends on.
# -----------------------------------------------------------------------------
warn contains msg if {
	some rc in resource_changes
	created_or_updated(rc)
	rc.type == "azurerm_kubernetes_cluster"
	attr_string(after_object(rc), "sku_tier") == "Free"
	not is_dev(rc)

	msg := sprintf(
		"%s: AKS cluster in environment %q uses `sku_tier = \"Free\"`, which carries no control-plane SLA. Use \"Standard\" for staging/prod (or \"Premium\" with long-term support). Warn-only in dev by design.",
		[rc.address, environment_of(rc)],
	)
}

# -----------------------------------------------------------------------------
# W3. ACR not on Premium while the plan is clearly building private networking.
#
# Private endpoints, customer-managed keys, geo-replication, content trust and
# repository-scoped tokens are all Premium-only. A Basic/Standard registry in a
# plan that also provisions private endpoints - or that has already switched
# the registry off the public internet - is almost always an oversight that
# surfaces as an apply-time API error.
# -----------------------------------------------------------------------------
warn contains msg if {
	some rc in resource_changes
	created_or_updated(rc)
	rc.type == "azurerm_container_registry"

	sku := attr_string(after_object(rc), "sku")
	sku != "Premium"
	private_networking_expected(rc)

	msg := sprintf(
		"%s: container registry uses `sku = %q` but this plan expects private connectivity. Private endpoints, customer-managed keys and geo-replication require `sku = \"Premium\"`; Basic/Standard will fail at apply time.",
		[rc.address, sku],
	)
}

# Signal 1: the registry itself has already been taken off the public internet.
private_networking_expected(rc) if {
	not attr_bool(after_object(rc), "public_network_access_enabled")
}

# Signal 2: the plan provisions at least one private endpoint.
private_networking_expected(_) if {
	plan_declares_private_endpoint
}

# -----------------------------------------------------------------------------
# W4. AKS API server reachable from the public internet outside dev.
#
# A public API server is survivable when paired with
# `api_server_access_profile.authorized_ip_ranges`, which is why this is a warn
# and not a deny - but a private cluster is the target state for staging/prod.
# -----------------------------------------------------------------------------
warn contains msg if {
	some rc in resource_changes
	created_or_updated(rc)
	rc.type == "azurerm_kubernetes_cluster"
	not attr_bool(after_object(rc), "private_cluster_enabled")
	not is_dev(rc)

	msg := sprintf(
		"%s: AKS cluster in environment %q exposes a public API server. Prefer `private_cluster_enabled = true`; if public access is required, restrict `api_server_access_profile.authorized_ip_ranges` to the runner and operator egress CIDRs.",
		[rc.address, environment_of(rc)],
	)
}

# -----------------------------------------------------------------------------
# W5. Key Vault still using access policies instead of Azure RBAC.
#
# Access policies are vault-scoped, not role-scoped, do not support PIM or
# deny-assignments, and cannot be audited alongside the rest of the Azure RBAC
# graph. azurerm renamed this argument mid-v4 (`enable_rbac_authorization` ->
# `rbac_authorization_enabled`), so we read whichever one the installed
# provider version rendered into the plan.
# -----------------------------------------------------------------------------
warn contains msg if {
	some rc in resource_changes
	created_or_updated(rc)
	rc.type == "azurerm_key_vault"
	not key_vault_rbac_enabled(rc)

	msg := sprintf(
		"%s: Key Vault uses legacy access policies. Set `rbac_authorization_enabled = true` (older azurerm 4.x builds spell it `enable_rbac_authorization`) and grant data-plane access with role assignments so permissions are PIM-eligible and auditable.",
		[rc.address],
	)
}

key_vault_rbac_enabled(rc) if {
	attr_bool(after_object(rc), "rbac_authorization_enabled")
}

key_vault_rbac_enabled(rc) if {
	attr_bool(after_object(rc), "enable_rbac_authorization")
}

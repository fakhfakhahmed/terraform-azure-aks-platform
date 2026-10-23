# =============================================================================
# Unit tests for policy/conftest/terraform.rego
# =============================================================================
#
#   conftest verify --policy policy/conftest
#
# or, with a bare OPA binary:
#
#   opa test policy/conftest -v
#
# Every test builds the smallest plan-JSON document that exercises exactly one
# rule, then asserts on the *count* of findings rather than on message text.
# Counting is what catches the two failure modes that matter:
#
#   * a rule that silently stopped matching (count drops to 0), and
#   * a rule that over-matches and starts flagging compliant resources
#     (count on a "good" fixture rises above 0).
#
# Asserting `count(deny) == 0` on the compliant fixtures makes every fixture a
# regression test for every *other* rule too - add a new deny rule that is too
# broad and these tests go red immediately.
# =============================================================================

package main

import rego.v1

# -----------------------------------------------------------------------------
# Fixture helpers
# -----------------------------------------------------------------------------

# Shallow merge: keys present in `overrides` replace those in `base` outright.
#
# We deliberately do NOT use a bare `object.union`, because object.union merges
# nested objects recursively - which would make it impossible to write a
# fixture that *removes* a tag (the base tag would be merged straight back in).
merge(base, overrides) := object.union(
	object.remove(base, object.keys(overrides)),
	overrides,
)

# A plan document containing the supplied resource changes.
mock_plan(changes) := {
	"format_version": "1.2",
	"terraform_version": "1.9.8",
	"resource_changes": changes,
}

# A single `create` resource change for a managed resource.
mock_change(resource_type, address, after) := {
	"address": address,
	"mode": "managed",
	"type": resource_type,
	"name": "this",
	"provider_name": "registry.terraform.io/hashicorp/azurerm",
	"change": {
		"actions": ["create"],
		"before": null,
		"after": after,
		"after_unknown": {"id": true},
	},
}

# The canonical compliant tag set from the repository contract.
base_tags := {
	"environment": "prod",
	"project": "terraform-azure-aks-platform",
	"owner": "ahmed.fakhfakh",
	"managed_by": "terraform",
	"cost_center": "cc-platform-1042",
}

# --- AKS cluster ------------------------------------------------------------

aks_defaults := {
	"name": "afk-prod-weu-platform-aks",
	"workload_identity_enabled": true,
	"oidc_issuer_enabled": true,
	"local_account_disabled": true,
	"private_cluster_enabled": true,
	"sku_tier": "Standard",
	"default_node_pool": [{
		"name": "system",
		"vm_size": "Standard_D4ds_v5",
		"node_public_ip_enabled": false,
	}],
	"tags": base_tags,
}

mock_aks(overrides) := mock_change(
	"azurerm_kubernetes_cluster",
	"module.aks.azurerm_kubernetes_cluster.this",
	merge(aks_defaults, overrides),
)

# --- AKS node pool ----------------------------------------------------------

node_pool_defaults := {
	"name": "workload",
	"vm_size": "Standard_D4ds_v5",
	"node_public_ip_enabled": false,
	"tags": base_tags,
}

mock_node_pool(overrides) := mock_change(
	"azurerm_kubernetes_cluster_node_pool",
	"module.aks.azurerm_kubernetes_cluster_node_pool.workload",
	merge(node_pool_defaults, overrides),
)

# --- Container registry -----------------------------------------------------

acr_defaults := {
	"name": "afkprodweuplatformacr",
	"sku": "Premium",
	"admin_enabled": false,
	"public_network_access_enabled": false,
	"tags": base_tags,
}

mock_acr(overrides) := mock_change(
	"azurerm_container_registry",
	"module.acr.azurerm_container_registry.this",
	merge(acr_defaults, overrides),
)

# --- Storage account --------------------------------------------------------

storage_defaults := {
	"name": "afkprodweutfstate",
	"allow_nested_items_to_be_public": false,
	"public_network_access_enabled": false,
	"min_tls_version": "TLS1_2",
	"https_traffic_only_enabled": true,
	"tags": base_tags,
}

mock_storage(overrides) := mock_change(
	"azurerm_storage_account",
	"module.observability.azurerm_storage_account.this",
	merge(storage_defaults, overrides),
)

# --- Key Vault --------------------------------------------------------------
#
# Purge protection is OFF in the defaults on purpose: the dev-vs-prod exception
# is exactly what the two Key Vault tests below pin down.
key_vault_defaults := {
	"name": "afk-prod-weu-platform-kv",
	"purge_protection_enabled": false,
	"soft_delete_retention_days": 90,
	"rbac_authorization_enabled": true,
	"tags": base_tags,
}

mock_key_vault(overrides) := mock_change(
	"azurerm_key_vault",
	"module.keyvault.azurerm_key_vault.this",
	merge(key_vault_defaults, overrides),
)

# --- Network security rule --------------------------------------------------

nsg_rule_defaults := {
	"name": "allow-mgmt",
	"direction": "Inbound",
	"access": "Allow",
	"protocol": "Tcp",
	"priority": 100,
	"source_address_prefix": "*",
	"source_port_range": "*",
	"destination_address_prefix": "*",
	"destination_port_range": "22",
}

mock_nsg_rule(overrides) := mock_change(
	"azurerm_network_security_rule",
	"module.network.azurerm_network_security_rule.mgmt",
	merge(nsg_rule_defaults, overrides),
)

mock_nsg_group(security_rules) := mock_change(
	"azurerm_network_security_group",
	"module.network.azurerm_network_security_group.nodes",
	{
		"name": "afk-prod-weu-platform-nsg",
		"security_rule": security_rules,
		"tags": base_tags,
	},
)

# =============================================================================
# Baseline: the compliant platform produces no findings at all.
# =============================================================================

test_compliant_platform_passes if {
	plan := mock_plan([
		mock_aks({}),
		mock_node_pool({}),
		mock_acr({}),
		mock_storage({}),
		mock_key_vault({"purge_protection_enabled": true}),
		mock_nsg_rule({"source_address_prefix": "10.0.0.0/8"}),
	])

	count(deny) == 0 with input as plan
}

test_compliant_platform_raises_no_warnings if {
	plan := mock_plan([
		mock_aks({}),
		mock_acr({}),
		mock_storage({}),
		mock_key_vault({"purge_protection_enabled": true}),
	])

	count(warn) == 0 with input as plan
}

# =============================================================================
# AKS identity and authentication posture.
# =============================================================================

test_aks_without_workload_identity_denied if {
	results := deny with input as mock_plan([mock_aks({"workload_identity_enabled": false})])
	count(results) == 1
}

test_aks_without_oidc_issuer_denied if {
	# Disabling the issuer takes Workload Identity down with it, so BOTH rules
	# fire. Two findings is the correct, intentional outcome.
	results := deny with input as mock_plan([mock_aks({
		"workload_identity_enabled": false,
		"oidc_issuer_enabled": false,
	})])

	count(results) == 2
}

test_aks_with_null_workload_identity_denied if {
	# A null (never-configured) boolean must be treated as "disabled" - this
	# pins the fail-closed behaviour of attr_bool.
	results := deny with input as mock_plan([mock_aks({"workload_identity_enabled": null})])
	count(results) == 1
}

test_aks_with_local_accounts_enabled_denied if {
	results := deny with input as mock_plan([mock_aks({"local_account_disabled": false})])
	count(results) == 1
}

# =============================================================================
# Container registry.
# =============================================================================

test_acr_admin_user_enabled_denied if {
	results := deny with input as mock_plan([mock_acr({"admin_enabled": true})])
	count(results) == 1
}

test_acr_admin_user_disabled_allowed if {
	results := deny with input as mock_plan([mock_acr({"admin_enabled": false})])
	count(results) == 0
}

# =============================================================================
# Storage account.
# =============================================================================

test_storage_public_blob_access_denied if {
	results := deny with input as mock_plan([mock_storage({"allow_nested_items_to_be_public": true})])
	count(results) == 1
}

test_storage_below_tls_1_2_denied if {
	results := deny with input as mock_plan([mock_storage({"min_tls_version": "TLS1_0"})])
	count(results) == 1
}

test_storage_plaintext_http_denied if {
	results := deny with input as mock_plan([mock_storage({"https_traffic_only_enabled": false})])
	count(results) == 1
}

test_storage_public_network_access_warns_but_does_not_deny if {
	plan := mock_plan([mock_storage({"public_network_access_enabled": true})])

	count(deny) == 0 with input as plan
	count(warn) == 1 with input as plan
}

# =============================================================================
# Tagging.
# =============================================================================

test_missing_required_tag_denied if {
	tags := object.remove(base_tags, {"cost_center"})
	results := deny with input as mock_plan([mock_storage({"tags": tags})])
	count(results) == 1
}

test_blank_required_tag_denied if {
	tags := merge(base_tags, {"owner": "   "})
	results := deny with input as mock_plan([mock_storage({"tags": tags})])
	count(results) == 1
}

test_all_required_tags_present_allowed if {
	results := deny with input as mock_plan([mock_storage({"tags": base_tags})])
	count(results) == 0
}

test_untaggable_resource_type_ignored if {
	# azurerm_role_assignment has no `tags` property in ARM at all; flagging it
	# would produce an unfixable finding.
	change := mock_change(
		"azurerm_role_assignment",
		"module.identity.azurerm_role_assignment.acr_pull",
		{
			"scope": "/subscriptions/0000/resourceGroups/afk-prod-weu-platform-rg",
			"role_definition_name": "AcrPull",
		},
	)

	results := deny with input as mock_plan([change])
	count(results) == 0
}

test_resource_without_tags_in_schema_ignored if {
	# azurerm_storage_container is NOT on the hand-maintained untaggable list;
	# it is skipped purely because its plan projection has no `tags` key. This
	# exercises the schema_has_tags safety net.
	change := mock_change(
		"azurerm_storage_container",
		"module.observability.azurerm_storage_container.state",
		{"name": "tfstate", "container_access_type": "private"},
	)

	results := deny with input as mock_plan([change])
	count(results) == 0
}

test_non_azurerm_resource_ignored if {
	change := mock_change("random_string", "random_string.suffix", {"length": 6})
	results := deny with input as mock_plan([change])
	count(results) == 0
}

# =============================================================================
# Network security rules - the port-range membership logic.
# =============================================================================

test_nsg_ssh_open_to_any_denied if {
	results := deny with input as mock_plan([mock_nsg_rule({
		"source_address_prefix": "*",
		"destination_port_range": "22",
	})])

	count(results) == 1
}

test_nsg_rdp_from_internet_service_tag_denied if {
	results := deny with input as mock_plan([mock_nsg_rule({
		"source_address_prefix": "Internet",
		"destination_port_range": "3389",
	})])

	count(results) == 1
}

test_nsg_https_from_internet_allowed if {
	# Port 443 open to the world is the whole point of an ingress controller.
	results := deny with input as mock_plan([mock_nsg_rule({
		"source_address_prefix": "Internet",
		"destination_port_range": "443",
	})])

	count(results) == 0
}

test_nsg_port_range_20_30_covering_ssh_denied if {
	results := deny with input as mock_plan([mock_nsg_rule({
		"source_address_prefix": "0.0.0.0/0",
		"destination_port_range": "20-30",
	})])

	count(results) == 1
}

test_nsg_port_range_not_covering_ssh_allowed if {
	results := deny with input as mock_plan([mock_nsg_rule({
		"source_address_prefix": "0.0.0.0/0",
		"destination_port_range": "23-30",
	})])

	count(results) == 0
}

test_nsg_wildcard_port_exposes_both_management_ports if {
	# "*" covers 22 and 3389, so the rule reports one finding per port.
	results := deny with input as mock_plan([mock_nsg_rule({
		"source_address_prefix": "*",
		"destination_port_range": "*",
	})])

	count(results) == 2
}

test_nsg_plural_destination_port_ranges_denied if {
	# Azure accepts either the singular or the plural argument, never both, so
	# the fixture drops the singular forms entirely. This exercises the plural
	# branch of BOTH `source_is_internet` and `destination_port_specs`.
	rule := object.remove(nsg_rule_defaults, {"destination_port_range", "source_address_prefix"})

	change := mock_change(
		"azurerm_network_security_rule",
		"module.network.azurerm_network_security_rule.mgmt",
		merge(rule, {
			"source_address_prefixes": ["203.0.113.0/24", "0.0.0.0/0"],
			"destination_port_ranges": ["80", "443", "3389"],
		}),
	)

	results := deny with input as mock_plan([change])
	count(results) == 1
}

test_nsg_private_source_on_ssh_allowed if {
	results := deny with input as mock_plan([mock_nsg_rule({
		"source_address_prefix": "10.42.0.0/16",
		"destination_port_range": "22",
	})])

	count(results) == 0
}

test_nsg_outbound_rule_ignored if {
	results := deny with input as mock_plan([mock_nsg_rule({
		"direction": "Outbound",
		"source_address_prefix": "*",
		"destination_port_range": "22",
	})])

	count(results) == 0
}

test_nsg_deny_action_rule_ignored if {
	results := deny with input as mock_plan([mock_nsg_rule({
		"access": "Deny",
		"source_address_prefix": "*",
		"destination_port_range": "22",
	})])

	count(results) == 0
}

test_nsg_inline_security_rule_denied if {
	plan := mock_plan([mock_nsg_group([
		{
			"name": "allow-https",
			"direction": "Inbound",
			"access": "Allow",
			"source_address_prefix": "Internet",
			"destination_port_range": "443",
		},
		{
			"name": "allow-rdp",
			"direction": "Inbound",
			"access": "Allow",
			"source_address_prefix": "Internet",
			"destination_port_range": "3380-3400",
		},
	])])

	results := deny with input as plan
	count(results) == 1
}

test_port_spec_covers_helper if {
	port_spec_covers("22", 22)
	port_spec_covers("*", 22)
	port_spec_covers("*", 3389)
	port_spec_covers("20-30", 22)
	port_spec_covers("3389-3389", 3389)

	not port_spec_covers("443", 22)
	not port_spec_covers("23-30", 22)
	not port_spec_covers("", 22)
	not port_spec_covers("not-a-port", 22)
}

# =============================================================================
# Key Vault - the documented dev exception.
# =============================================================================

test_key_vault_without_purge_protection_in_dev_allowed if {
	tags := merge(base_tags, {"environment": "dev"})
	results := deny with input as mock_plan([mock_key_vault({"tags": tags})])
	count(results) == 0
}

test_key_vault_without_purge_protection_in_prod_denied if {
	tags := merge(base_tags, {"environment": "prod"})
	results := deny with input as mock_plan([mock_key_vault({"tags": tags})])
	count(results) == 1
}

test_key_vault_with_purge_protection_in_prod_allowed if {
	results := deny with input as mock_plan([mock_key_vault({"purge_protection_enabled": true})])
	count(results) == 0
}

# =============================================================================
# Node public IPs.
# =============================================================================

test_node_pool_public_ip_denied if {
	results := deny with input as mock_plan([mock_node_pool({"node_public_ip_enabled": true})])
	count(results) == 1
}

test_aks_default_node_pool_public_ip_denied if {
	results := deny with input as mock_plan([mock_aks({"default_node_pool": [{
		"name": "system",
		"vm_size": "Standard_D4ds_v5",
		"node_public_ip_enabled": true,
	}]})])

	count(results) == 1
}

# =============================================================================
# Change-set filtering: only managed create/update is in scope.
# =============================================================================

test_delete_action_ignored if {
	change := merge(
		mock_aks({}),
		{"change": {
			"actions": ["delete"],
			"before": merge(aks_defaults, {"workload_identity_enabled": false}),
			"after": null,
			"after_unknown": {},
		}},
	)

	results := deny with input as mock_plan([change])
	count(results) == 0
}

test_no_op_action_ignored if {
	change := merge(
		mock_aks({}),
		{"change": {
			"actions": ["no-op"],
			"before": merge(aks_defaults, {"workload_identity_enabled": false}),
			"after": merge(aks_defaults, {"workload_identity_enabled": false}),
			"after_unknown": {},
		}},
	)

	results := deny with input as mock_plan([change])
	count(results) == 0
}

test_data_source_mode_ignored if {
	# A data source we only read - almost certainly owned by another team and
	# not remediable from this repository.
	change := merge(
		mock_aks({
			"workload_identity_enabled": false,
			"oidc_issuer_enabled": false,
			"local_account_disabled": false,
			"tags": {},
		}),
		{"mode": "data"},
	)

	results := deny with input as mock_plan([change])
	count(results) == 0
}

test_replace_action_is_evaluated if {
	# Terraform renders a replace as ["delete","create"]; it creates a new
	# resource and must therefore be gated.
	change := merge(
		mock_aks({}),
		{"change": {
			"actions": ["delete", "create"],
			"before": aks_defaults,
			"after": merge(aks_defaults, {"local_account_disabled": false}),
			"after_unknown": {},
		}},
	)

	results := deny with input as mock_plan([change])
	count(results) == 1
}

# =============================================================================
# Advisory rules.
# =============================================================================

test_aks_free_sku_outside_dev_warns if {
	plan := mock_plan([mock_aks({"sku_tier": "Free"})])

	count(warn) == 1 with input as plan
	count(deny) == 0 with input as plan
}

test_aks_free_sku_in_dev_allowed if {
	tags := merge(base_tags, {"environment": "dev"})
	plan := mock_plan([mock_aks({"sku_tier": "Free", "tags": tags})])

	count(warn) == 0 with input as plan
	count(deny) == 0 with input as plan
}

test_acr_non_premium_with_private_networking_warns if {
	plan := mock_plan([mock_acr({
		"sku": "Standard",
		"public_network_access_enabled": false,
	})])

	count(warn) == 1 with input as plan
	count(deny) == 0 with input as plan
}

test_acr_non_premium_without_private_networking_allowed if {
	plan := mock_plan([mock_acr({
		"sku": "Standard",
		"public_network_access_enabled": true,
	})])

	count(warn) == 0 with input as plan
}

test_aks_public_api_server_outside_dev_warns if {
	plan := mock_plan([mock_aks({"private_cluster_enabled": false})])

	count(warn) == 1 with input as plan
	count(deny) == 0 with input as plan
}

test_key_vault_access_policies_warns if {
	plan := mock_plan([mock_key_vault({
		"purge_protection_enabled": true,
		"rbac_authorization_enabled": false,
	})])

	count(warn) == 1 with input as plan
	count(deny) == 0 with input as plan
}

test_key_vault_legacy_rbac_argument_name_accepted if {
	# Older azurerm 4.x builds render `enable_rbac_authorization`; the helper
	# must accept either spelling so the warn does not misfire.
	after := object.remove(
		merge(key_vault_defaults, {
			"purge_protection_enabled": true,
			"enable_rbac_authorization": true,
		}),
		{"rbac_authorization_enabled"},
	)

	change := mock_change("azurerm_key_vault", "module.keyvault.azurerm_key_vault.this", after)

	count(warn) == 0 with input as mock_plan([change])
}

# =============================================================================
# Degenerate input must not blow up.
# =============================================================================

test_empty_plan_produces_no_findings if {
	count(deny) == 0 with input as {"resource_changes": []}
	count(warn) == 0 with input as {"resource_changes": []}
	count(deny) == 0 with input as {}
}

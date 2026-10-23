# =============================================================================
# envs/dev/main.tf -- dev environment composition
# =============================================================================
# Modules never call each other (docs/architecture.md, design principle 4).
# All wiring between modules/naming, modules/network, modules/observability,
# modules/acr, modules/aks, modules/identity and modules/keyvault happens
# here, explicitly, so the entire dependency graph for dev is readable in one
# file. See docs/architecture.md's "Module composition" section for the
# producer/consumer table this file implements.
# =============================================================================

data "azurerm_client_config" "current" {}

# -----------------------------------------------------------------------------
# 1. Naming -- single source of truth for every resource name and the common
#    tag set (docs/architecture.md, "Module composition").
# -----------------------------------------------------------------------------

module "naming" {
  source = "../../modules/naming"

  prefix      = var.prefix
  environment = "dev"
  location    = var.location
  owner       = var.owner
  cost_center = var.cost_center

  additional_tags = var.additional_tags
}

locals {
  tags = module.naming.tags

  # modules/observability and modules/identity both build their resource names
  # from a "{prefix}-{environment}-{region_short}" base token (e.g.
  # "aksplat-dev-weu") and prepend their own type token ("log-", "id-", ...)
  # themselves. modules/naming does not expose that bare base as its own
  # output (only the fully-assembled names in `names` and a couple of
  # convenience accessors), so it is reconstructed here from
  # `region_short` -- the exact same formula modules/naming/main.tf uses
  # internally.
  name_prefix = "${var.prefix}-dev-${module.naming.region_short}"
}

# -----------------------------------------------------------------------------
# Resource group -- created here, not by a module, because composition (which
# resource group, how many) is an environment-root decision per
# docs/architecture.md design principle 4. See modules/naming/README.md's own
# usage example for this exact pattern.
# -----------------------------------------------------------------------------

resource "azurerm_resource_group" "this" {
  name     = module.naming.names["resource_group"]
  location = var.location
  tags     = local.tags

  # Deliberately NO lifecycle.prevent_destroy here: dev is designed to be
  # destroyed nightly (docs/architecture.md, design principle 7 / cost.md).
  # Unlike prod, there is nothing irreplaceable in this resource group.
}

# -----------------------------------------------------------------------------
# 2. Network -- VNet, four subnets, NSGs, NAT Gateway, route table, and
#    (only when enable_private_endpoints) the three privatelink DNS zones.
# -----------------------------------------------------------------------------

module "network" {
  source = "../../modules/network"

  names               = module.naming.names
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  tags                = local.tags

  vnet_address_space = var.vnet_address_space
  subnet_cidrs       = var.subnet_cidrs

  # Dev runs no private endpoints (docs/architecture.md's environment
  # topology table), so the private DNS zones they would resolve against
  # would be pure unused cost/clutter -- skip them too.
  enable_private_dns_zones = var.enable_private_endpoints

  log_analytics_workspace_id = module.observability.log_analytics_workspace_id
}

# -----------------------------------------------------------------------------
# 3. Observability -- Log Analytics, Application Insights, the baseline
#    action group and scheduled-query alerts.
#
# KNOWN LIMITATION: aks_cluster_id is passed as null.
# -----------------------------------------------------------------------------
# modules/observability's three cluster-scoped scheduled-query alerts (node
# not ready, pod restart rate, node disk pressure) require a non-null
# `aks_cluster_id`. But module.aks needs this module's
# `log_analytics_workspace_id` BEFORE the cluster can be created (it is wired
# into the `oms_agent` block), and this module would need module.aks's
# `cluster_id` to create those same alerts -- a genuine two-way need between
# two modules that, per docs/architecture.md design principle 4, are not
# allowed to call each other or be wired with depends_on games.
#
# docs/architecture.md's own "Ordering constraints that are real" section
# does not document a cluster-scoped-alerts edge at all (only
# identity-after-aks and keyvault-after-identity), so there is no sanctioned
# two-pass pattern for it in this repository today. Resolving it would mean
# either:
#   (a) a second, later `module "observability_alerts"` block that only
#       creates the three scheduled-query alerts, referencing
#       module.aks.cluster_id (clean, but means modules/observability would
#       need to be refactored to separate "platform" resources from
#       "cluster-scoped alerts"), or
#   (b) applying this root module twice, accepting that the alerts show up
#       as "will be created" only on the second plan.
# Neither is implemented here. The deliberate, documented choice for this
# portfolio platform is to leave the three cluster-scoped alerts uncreated in
# every environment (aks_cluster_id = null everywhere, for consistency) and
# record it as a known limitation -- see README.md, "Known limitations".
# Workspace-level telemetry (Container Insights via oms_agent, ACR/Key Vault
# diagnostic settings) is unaffected: none of it depends on aks_cluster_id.
# -----------------------------------------------------------------------------

module "observability" {
  source = "../../modules/observability"

  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  tags                = local.tags
  name_prefix         = local.name_prefix

  log_retention_days           = var.log_retention_days
  action_group_email_receivers = var.action_group_email_receivers
  enable_managed_prometheus    = var.enable_managed_prometheus
  enable_managed_grafana       = var.enable_managed_grafana

  # See the KNOWN LIMITATION note above.
  aks_cluster_id = null
}

# -----------------------------------------------------------------------------
# 4. Azure Container Registry -- bound to the cluster's kubelet identity via
#    modules/aks's attached_acr_ids, so no imagePullSecret is ever needed.
# -----------------------------------------------------------------------------

module "acr" {
  source = "../../modules/acr"

  name                = module.naming.acr_name
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  tags                = local.tags

  sku                    = var.acr_sku
  retention_policy_days  = var.acr_retention_policy_days

  # Dev has no private endpoint subnet to attach to; the registry stays on
  # its public, RBAC-protected data-plane endpoint.
  public_network_access_enabled = !var.enable_private_endpoints
  private_endpoint_subnet_id    = var.enable_private_endpoints ? module.network.subnet_ids["private_endpoints"] : null
  private_dns_zone_ids = var.enable_private_endpoints ? [
    module.network.private_dns_zone_ids["acr_registry"],
    module.network.private_dns_zone_ids["acr_data"],
  ] : []

  log_analytics_workspace_id = module.observability.log_analytics_workspace_id
}

# -----------------------------------------------------------------------------
# 5. AKS -- the cluster, its system/user node pools, and the AcrPull role
#    assignment against the kubelet identity (see
#    docs/architecture.md, "The one non-obvious edge: ACR to AKS").
# -----------------------------------------------------------------------------

module "aks" {
  source = "../../modules/aks"

  name                = module.naming.aks_name
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  tags                = local.tags

  kubernetes_version = var.kubernetes_version
  sku_tier           = var.sku_tier

  private_cluster_enabled = var.private_cluster_enabled
  authorized_ip_ranges    = var.authorized_ip_ranges

  system_node_subnet_id = module.network.subnet_ids["aks_system"]
  user_node_subnet_id   = module.network.subnet_ids["aks_user"]

  system_node_vm_size = var.system_node_vm_size
  system_node_count   = var.system_node_count

  user_node_vm_size   = var.user_node_vm_size
  user_node_min_count = var.user_node_min_count
  user_node_max_count = var.user_node_max_count

  zones          = var.zones
  network_policy = var.network_policy

  log_analytics_workspace_id = module.observability.log_analytics_workspace_id
  attached_acr_ids           = [module.acr.acr_id]
  admin_group_object_ids     = var.admin_group_object_ids

  automatic_upgrade_channel = var.automatic_upgrade_channel
  node_os_upgrade_channel   = var.node_os_upgrade_channel
  maintenance_window_day    = var.maintenance_window_day
  maintenance_window_hours  = var.maintenance_window_hours
}

# -----------------------------------------------------------------------------
# 6. Identity -- one user-assigned managed identity + federated identity
#    credential per workload. Must come after modules/aks: the federated
#    credential's issuer is the cluster's OIDC issuer URL, which does not
#    exist until the cluster does (docs/architecture.md, "Ordering
#    constraints that are real", #1).
# -----------------------------------------------------------------------------

module "identity" {
  source = "../../modules/identity"

  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  tags                = local.tags
  name_prefix         = local.name_prefix

  oidc_issuer_url = module.aks.oidc_issuer_url
  workloads       = var.workloads
}

# -----------------------------------------------------------------------------
# 7. Key Vault -- RBAC-authorised, with "Key Vault Secrets User" granted to
#    every workload identity. Must come after modules/identity: the role
#    assignment's principal_id is the managed identity's principal ID
#    (docs/architecture.md, "Ordering constraints that are real", #2).
# -----------------------------------------------------------------------------

module "keyvault" {
  source = "../../modules/keyvault"

  name                = module.naming.key_vault_name
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  tags                = local.tags

  sku_name                    = var.key_vault_sku_name
  purge_protection_enabled    = var.key_vault_purge_protection_enabled
  soft_delete_retention_days  = var.key_vault_soft_delete_retention_days

  public_network_access_enabled = !var.enable_private_endpoints
  network_acls_default_action   = var.key_vault_network_acls_default_action
  allowed_ip_rules               = var.key_vault_allowed_ip_rules

  private_endpoint_subnet_id = var.enable_private_endpoints ? module.network.subnet_ids["private_endpoints"] : null
  private_dns_zone_ids = var.enable_private_endpoints ? [
    module.network.private_dns_zone_ids["key_vault"],
  ] : []

  log_analytics_workspace_id = module.observability.log_analytics_workspace_id
  workload_principal_ids     = module.identity.principal_ids
}

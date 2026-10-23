# =============================================================================
# envs/prod/main.tf -- prod environment composition
# =============================================================================
# Modules never call each other (docs/architecture.md, design principle 4).
# All wiring between modules/naming, modules/network, modules/observability,
# modules/acr, modules/aks, modules/identity and modules/keyvault happens
# here, explicitly, so the entire dependency graph for prod is readable in one
# file. See docs/architecture.md's "Module composition" section for the
# producer/consumer table this file implements.
#
# Identical structure to envs/dev and envs/staging's main.tf by design
# (docs/architecture.md design principle 5: "Prod differs from dev by
# configuration, not by code path") -- the only structural difference is the
# `lifecycle.prevent_destroy` note below, which is a comment, not code,
# because of a real limitation explained there.
# =============================================================================

data "azurerm_client_config" "current" {}

# -----------------------------------------------------------------------------
# 1. Naming -- single source of truth for every resource name and the common
#    tag set (docs/architecture.md, "Module composition").
# -----------------------------------------------------------------------------

module "naming" {
  source = "../../modules/naming"

  prefix      = var.prefix
  environment = "prod"
  location    = var.location
  owner       = var.owner
  cost_center = var.cost_center

  additional_tags = var.additional_tags
}

locals {
  tags = module.naming.tags

  # modules/observability and modules/identity both build their resource names
  # from a "{prefix}-{environment}-{region_short}" base token (e.g.
  # "aksplat-prod-weu") and prepend their own type token ("log-", "id-", ...)
  # themselves. modules/naming does not expose that bare base as its own
  # output (only the fully-assembled names in `names` and a couple of
  # convenience accessors), so it is reconstructed here from
  # `region_short` -- the exact same formula modules/naming/main.tf uses
  # internally.
  name_prefix = "${var.prefix}-prod-${module.naming.region_short}"
}

# -----------------------------------------------------------------------------
# Resource group -- created here, not by a module, because composition (which
# resource group, how many) is an environment-root decision per
# docs/architecture.md design principle 4. See modules/naming/README.md's own
# usage example for this exact pattern.
#
# NO lifecycle.prevent_destroy on the resource group itself: the real
# protection against an accidental deletion of a non-empty resource group is
# `prevent_deletion_if_contains_resources = true` in versions.tf's provider
# `resource_group` features block, which is an ARM-level guarantee that does
# not require remembering a per-resource lifecycle block and cannot be
# bypassed by forgetting one.
# -----------------------------------------------------------------------------

resource "azurerm_resource_group" "this" {
  name     = module.naming.names["resource_group"]
  location = var.location
  tags     = local.tags
}

# -----------------------------------------------------------------------------
# 2. Network -- VNet, four subnets, NSGs, NAT Gateway, route table, and (prod
#    only) the three privatelink DNS zones for ACR and Key Vault's private
#    endpoints.
# -----------------------------------------------------------------------------

module "network" {
  source = "../../modules/network"

  names               = module.naming.names
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  tags                = local.tags

  vnet_address_space = var.vnet_address_space
  subnet_cidrs       = var.subnet_cidrs

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
# record it as a known limitation -- see README.md, "Known limitations". This
# matters MORE in prod than elsewhere: it means "node not ready" and "pod
# restart rate" alerts do not exist today, and Container Insights dashboards
# (which are unaffected by this limitation) are the only way to notice those
# conditions until it is resolved.
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
# 4. Azure Container Registry -- Premium, with a private endpoint into
#    snet-private-endpoints, bound to the cluster's kubelet identity via
#    modules/aks's attached_acr_ids so no imagePullSecret is ever needed.
#
# PREVENT_DESTROY: not parametrized here. See the note below module.keyvault
# at the end of this file -- it applies equally to this module.
# -----------------------------------------------------------------------------

module "acr" {
  source = "../../modules/acr"

  name                = module.naming.acr_name
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  tags                = local.tags

  sku                   = var.acr_sku
  retention_policy_days = var.acr_retention_policy_days

  public_network_access_enabled = !var.enable_private_endpoints
  private_endpoint_subnet_id    = var.enable_private_endpoints ? module.network.subnet_ids["private_endpoints"] : null
  private_dns_zone_ids = var.enable_private_endpoints ? [
    module.network.private_dns_zone_ids["acr_registry"],
    module.network.private_dns_zone_ids["acr_data"],
  ] : []

  log_analytics_workspace_id = module.observability.log_analytics_workspace_id
}

# -----------------------------------------------------------------------------
# 5. AKS -- the private cluster, its system/user node pools across three
#    zones, and the AcrPull role assignment against the kubelet identity (see
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
# 7. Key Vault -- RBAC-authorised, private-endpoint-only, purge-protected,
#    with "Key Vault Secrets User" granted to every workload identity. Must
#    come after modules/identity: the role assignment's principal_id is the
#    managed identity's principal ID (docs/architecture.md, "Ordering
#    constraints that are real", #2).
#
# PREVENT_DESTROY: NOT implemented as a Terraform lifecycle block.
# -----------------------------------------------------------------------------
# docs/architecture.md's "Environment topology differences" table lists
# `prevent_destroy` as "yes (Key Vault, ACR, Log Analytics)" for prod. That is
# accurate as a STATEMENT OF INTENT, but it cannot be implemented as code at
# this layer: `lifecycle { prevent_destroy = true }` is a resource-level meta-
# argument in Terraform, and it can only be written inside the `resource`
# block it protects -- it is NOT a module input and cannot be threaded through
# a `module` block's arguments (there is no `lifecycle` argument a module
# consumer can set on the resources a module creates). modules/keyvault,
# modules/acr and modules/observability's variables.tf (read in full before
# writing this file) expose no `prevent_destroy`-shaped variable, and none
# was fabricated here to paper over that -- doing so would silently do
# nothing, which is worse than an honest gap.
#
# Real options to close this gap properly, in order of how much they cost:
#   1. Add a `prevent_destroy` boolean variable to modules/keyvault,
#      modules/acr and modules/observability that wraps their core resource
#      in a conditional `lifecycle` block (Terraform does not support
#      *conditional* lifecycle blocks directly, so in practice this means
#      duplicating the resource behind a `count`/`for_each` toggle, which is
#      its own maintenance cost against three modules used by every
#      environment).
#   2. Write prod-specific resource wrappers here in envs/prod/main.tf that
#      bypass the shared modules for just these three resources, with
#      `prevent_destroy = true` hardcoded. This violates design principle 5
#      ("prod differs from dev by configuration, not by code path") on
#      purpose, deliberately, for exactly the three resources where losing
#      data is unacceptable -- a real, defensible trade-off, just not the one
#      made here.
#   3. Accept the gap and rely on what IS actually protecting prod today
#      (see below) -- the choice made in this repository.
#
# WHAT IS ACTUALLY PROTECTING PROD, independent of this gap:
#   - `prevent_deletion_if_contains_resources = true` on the provider's
#     `resource_group` features block (versions.tf) -- ARM refuses to delete
#     prod's resource group while it still contains these resources, which is
#     most of what `prevent_destroy` would buy you, enforced one level up.
#   - Key Vault `purge_protection_enabled = true` (terraform.tfvars) -- even a
#     successful `terraform destroy` only SOFT-deletes the vault; the key
#     material is recoverable for `key_vault_soft_delete_retention_days` (90
#     here) and CANNOT be purged by Terraform, the portal, or support. This is
#     a stronger guarantee than `prevent_destroy` for the vault specifically,
#     because it survives even a destroy that somehow got past every other
#     gate.
#   - The GitHub Environment approval gate on prod (2 reviewers -- see
#     docs/architecture.md, "2. GitHub OIDC to Azure authentication flow")
#     and the production apply guard in scripts/apply-env.ps1 (`-Force` AND a
#     typed `apply-prod` confirmation).
#   - `.github/workflows/terraform-destroy.yml` blocks the destroy workflow
#     for prod entirely (see docs/architecture.md's environment topology
#     table, "Destroy workflow: blocked").
#   - Storage account versioning + soft delete on the STATE backend itself
#     (bootstrap/main.tf) -- even if prod's resources were destroyed, the
#     state history proving what existed is independently recoverable.
#   - A management lock can additionally be applied by hand
#     (`az lock create --lock-type CanNotDelete`) on prod's resource group or
#     individual resources -- deliberately not automated here, the same way
#     bootstrap/main.tf's own CanNotDelete lock on the state resource group
#     must be removed by hand before that stack can be destroyed. That
#     friction is the point for a resource this critical.
# -----------------------------------------------------------------------------

module "keyvault" {
  source = "../../modules/keyvault"

  name                = module.naming.key_vault_name
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  tags                = local.tags

  sku_name                    = var.key_vault_sku_name
  purge_protection_enabled   = var.key_vault_purge_protection_enabled
  soft_delete_retention_days = var.key_vault_soft_delete_retention_days

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

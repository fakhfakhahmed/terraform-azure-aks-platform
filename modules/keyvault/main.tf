# =============================================================================
# modules/keyvault/main.tf -- RBAC-authorised Key Vault with optional
# private endpoint
# =============================================================================

data "azurerm_client_config" "current" {}

locals {
  tags = merge(
    var.tags,
    {
      module = "keyvault"
    }
  )

  create_private_endpoint = var.private_endpoint_subnet_id != null
}

# -----------------------------------------------------------------------------
# Why RBAC authorisation instead of vault access policies
# -----------------------------------------------------------------------------
# Key Vault supports two mutually exclusive authorisation models, chosen by
# `enable_rbac_authorization`:
#
#   - ACCESS POLICIES (the legacy default, `false`): a single, vault-wide list
#     of principal -> {secrets, keys, certificates} permission grants, stored
#     as part of the vault resource itself. It has a practical ceiling of
#     ~1024 entries, grants are all-or-nothing across the WHOLE secret/key/
#     certificate namespace (no scoping to a single secret path), there is no
#     way to express a time-bound or conditional grant, and every change is a
#     write to the vault resource -- so two engineers editing policies
#     concurrently can clobber each other's Terraform-managed state.
#
#   - AZURE RBAC (`true`, used here): role assignments are first-class Azure
#     Resource Manager objects, independently auditable via Activity Log,
#     assignable at finer scope than the whole vault (a resource group,
#     subscription, or even a specific secret via `/secrets/<name>`),
#     support Privileged Identity Management (PIM) for just-in-time
#     elevation, and support Azure ABAC conditions. They compose with the
#     SAME authorization model as every other resource in this platform
#     (the AcrPull assignment in modules/aks, the Contributor/User Access
#     Administrator assignments in bootstrap/github-oidc.tf) rather than
#     being a Key-Vault-specific bolt-on.
#
# The only reason to still pick access policies in a new vault is HSM-backed
# cryptographic operations on the "premium" SKU predating RBAC support for
# some operation types -- not a constraint this platform has.
# -----------------------------------------------------------------------------

resource "azurerm_key_vault" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  tenant_id           = data.azurerm_client_config.current.tenant_id

  sku_name = var.sku_name

  enable_rbac_authorization = true

  purge_protection_enabled   = var.purge_protection_enabled
  soft_delete_retention_days = var.soft_delete_retention_days

  public_network_access_enabled = var.public_network_access_enabled

  network_acls {
    default_action = var.network_acls_default_action
    bypass         = "AzureServices"
    ip_rules       = var.allowed_ip_rules
  }

  tags = local.tags

  # No `lifecycle { prevent_destroy = true }` here: per docs/architecture.md
  # Design principle 5 ("Prod differs from dev by configuration, not by code
  # path"), this module's code is identical in every environment, and
  # `prevent_destroy` is a Terraform meta-argument that cannot be driven by a
  # variable. Prod's protection against accidental deletion is applied at the
  # environment root (envs/prod/main.tf wraps this module call, or the vault
  # resource it owns, with its own `prevent_destroy = true`), which is also
  # where Design principle 5 says that kind of environment-specific literal
  # belongs. `purge_protection_enabled` (above) is the protection that DOES
  # travel with this module, because it is a real vault property, not a
  # Terraform-local one.
}

# -----------------------------------------------------------------------------
# Private endpoint (prod only, per docs/architecture.md's environment
# topology table -- dev/staging pass private_endpoint_subnet_id = null)
# -----------------------------------------------------------------------------

resource "azurerm_private_endpoint" "key_vault" {
  count = local.create_private_endpoint ? 1 : 0

  name                = "pe-${var.name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoint_subnet_id

  private_service_connection {
    name                           = "psc-${var.name}"
    private_connection_resource_id = azurerm_key_vault.this.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  dynamic "private_dns_zone_group" {
    for_each = length(var.private_dns_zone_ids) > 0 ? [1] : []

    content {
      name                 = "default"
      private_dns_zone_ids = var.private_dns_zone_ids
    }
  }

  tags = local.tags
}

# -----------------------------------------------------------------------------
# Diagnostic settings
# -----------------------------------------------------------------------------
# AuditEvent captures every vault operation (GetSecret, SetSecret, every RBAC
# authorization decision) -- the primary forensic trail for "who read which
# secret, and when". AllMetrics covers saturation/availability, relevant
# mainly for capacity planning on high-throughput vaults.
# -----------------------------------------------------------------------------

resource "azurerm_monitor_diagnostic_setting" "key_vault" {
  name                       = "diag-${var.name}"
  target_resource_id         = azurerm_key_vault.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "AuditEvent"
  }

  # `enabled_metric`, not `metric` -- matches the block name this platform's
  # pinned azurerm ~> 4.0 provider expects, as established in
  # bootstrap/main.tf's own diagnostic setting.
  enabled_metric {
    category = "AllMetrics"
  }
}

# -----------------------------------------------------------------------------
# Workload access: "Key Vault Secrets User" per principal
# -----------------------------------------------------------------------------
# Deliberately the narrowest built-in role that can read secret VALUES
# (list + get on secrets only -- no write, no key/certificate access, no
# vault-level management operations). Scoped to the vault as a whole rather
# than per-secret: this platform's workloads each get their own vault-wide
# reader grant, and finer per-secret scoping is left as an extension point
# for a tenant that needs it (RBAC authorization supports it; this module's
# interface currently does not expose it).
# -----------------------------------------------------------------------------

resource "azurerm_role_assignment" "workload" {
  for_each = var.workload_principal_ids

  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = each.value
  principal_type       = "ServicePrincipal"

  description = "Lets the '${each.key}' workload identity read secret values via the Secrets Store CSI driver."

  # Same Entra replication-delay guard used everywhere else in this platform
  # a freshly created identity is granted a role against -- see
  # bootstrap/github-oidc.tf for the canonical explanation.
  skip_service_principal_aad_check = true
}

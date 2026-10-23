# =============================================================================
# modules/acr/main.tf -- Azure Container Registry
# =============================================================================
# One registry per environment, bound to the AKS cluster's kubelet identity
# via an AcrPull role assignment created in modules/aks (not here -- see "The
# one non-obvious edge: ACR to AKS" in docs/architecture.md for why that
# assignment lives on the consumer side rather than here).
# =============================================================================

locals {
  tags = merge(var.tags, { module = "acr" })

  # Geo-replication and the retention policy are Premium-only features. Below
  # SKU "Premium" these locals collapse to "do nothing" rather than letting a
  # misconfigured Basic/Standard caller hit an API-time error, so flipping
  # `sku` between environments in a single shared .tfvars pattern never
  # breaks on the lower tiers.
  geo_replications_effective = var.sku == "Premium" ? var.geo_replication_locations : []

  # A private endpoint is only created when BOTH a subnet was supplied AND
  # the SKU supports Private Link (Premium only). Silently skipping rather
  # than erroring means dev/staging .tfvars can simply not set
  # private_endpoint_subnet_id while prod does, with no SKU-specific branching
  # needed at the call site.
  create_private_endpoint = var.private_endpoint_subnet_id != null && var.sku == "Premium"
}

resource "azurerm_container_registry" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = var.sku

  # Hardcoded, not `var.admin_enabled` -- this is deliberate. Never expose the
  # registry's shared admin credential; workloads authenticate via managed
  # identity + the AcrPull role assignment (see modules/aks). The
  # `admin_enabled` variable still exists, with a validation that forbids
  # anything but `false`, purely so the intent is visible in `terraform plan`
  # and to a reviewer reading variables.tf -- see that variable's description.
  admin_enabled = false

  public_network_access_enabled = var.public_network_access_enabled

  # Premium only; a number on Basic/Standard is an API-time error, so this is
  # explicitly null rather than var.retention_policy_days below Premium.
  # Governs how long an untagged manifest (an orphaned layer from CI pushing
  # a new tag over an old digest) survives before ACR's background purge
  # task removes it.
  retention_policy_in_days = var.sku == "Premium" ? var.retention_policy_days : null

  # NOTE on content trust / var.trust_policy_enabled:
  # azurerm's `trust_policy` block on this resource was deprecated ahead of
  # Azure's own retirement of Docker Content Trust for ACR, and is REMOVED
  # entirely as of the v4.0 provider -- there is no argument left to set here.
  # `var.trust_policy_enabled` is therefore accepted for interface stability
  # (a future provider or a different registry backend might reintroduce an
  # equivalent knob) but deliberately left unwired below. See that variable's
  # description and "No image signing / content trust" in
  # docs/architecture.md's known-gaps table -- the real replacement is
  # Notation/cosign signing in CI plus Ratify + Gatekeeper admission, not this
  # field.

  dynamic "georeplications" {
    for_each = local.geo_replications_effective

    content {
      location                = georeplications.value.location
      zone_redundancy_enabled = georeplications.value.zone_redundancy_enabled
    }
  }

  tags = local.tags

  lifecycle {
    # admin_enabled is asserted false above and by the variable's own
    # validation; this precondition is a third, belt-and-braces guard that
    # fails `terraform plan` loudly if a future edit to this resource ever
    # reintroduces `var.admin_enabled` by accident.
    precondition {
      condition     = var.admin_enabled == false
      error_message = "ACR admin account must never be enabled on this platform."
    }
  }
}

# -----------------------------------------------------------------------------
# Private endpoint (Premium + subnet supplied only)
# -----------------------------------------------------------------------------
# Two DNS zones are needed for a fully private registry: the registry/login
# zone (privatelink.azurecr.io) and the region-scoped data-plane zone
# (privatelink.<region>.data.azurecr.io) that blob pulls actually resolve
# through -- both come in via var.private_dns_zone_ids from modules/network.
# -----------------------------------------------------------------------------

resource "azurerm_private_endpoint" "this" {
  count = local.create_private_endpoint ? 1 : 0

  name                = "pe-${var.name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoint_subnet_id

  private_service_connection {
    name                           = "psc-${var.name}"
    private_connection_resource_id = azurerm_container_registry.this.id
    subresource_names              = ["registry"]
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
# Diagnostics
# -----------------------------------------------------------------------------
# Repository events (push/pull/delete at the image level) and login events
# (who authenticated, with what identity) are the two logs that answer "who
# put this image here" and "who pulled it" during an incident -- the pair
# Checkov and most registry-hardening baselines look for.
# -----------------------------------------------------------------------------

resource "azurerm_monitor_diagnostic_setting" "this" {
  name                       = "diag-${var.name}"
  target_resource_id         = azurerm_container_registry.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "ContainerRegistryRepositoryEvents"
  }

  enabled_log {
    category = "ContainerRegistryLoginEvents"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

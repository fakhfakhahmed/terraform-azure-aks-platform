# =============================================================================
# modules/network/main.tf -- VNet, subnets, NSGs, NAT egress, private DNS
# =============================================================================
# See "1. Azure resource topology", "IP address plan" and "Network design
# rationale" in docs/architecture.md for the full picture this module
# implements. The short version:
#
#   - One VNet per environment, a fixed /16, four fixed subnets at fixed
#     offsets (only the second octet differs between environments).
#   - Every subnet except snet-appgw carries an NSG; AKS itself manages rules
#     on the cluster's NICs, so these NSGs only encode what AKS will not add
#     for you (deny stray inbound, contain lateral movement to the private
#     endpoint subnet).
#   - A single NAT Gateway with a static Standard public IP gives the whole
#     cluster one deterministic, allow-listable egress address, in every
#     environment -- see "Why NAT Gateway rather than load-balancer outbound
#     SNAT".
#   - snet-appgw is provisioned and otherwise untouched: no NSG, no NAT
#     association, no resources. It exists purely to avoid re-IP-ing the VNet
#     if AGIC or Application Gateway for Containers is adopted later.
# =============================================================================

locals {
  tags = merge(var.tags, { module = "network" })

  # Per-subnet configuration. Centralised here so the subnet resource below,
  # the service-endpoint decision and the NSG association are all driven from
  # one table instead of four near-duplicate resource blocks.
  subnets = {
    aks_system = {
      name              = var.names["subnet_aks_system"]
      address_prefixes  = [var.subnet_cidrs.aks_system]
      # Service endpoints matter most where there is no private endpoint to
      # the same service (dev/staging, which deploy no private endpoints at
      # all -- see "Environment topology differences"). Keeping them on in
      # every environment is harmless: a service endpoint and a private
      # endpoint to the same service can coexist, and Azure prefers the
      # private endpoint's more specific route when both exist.
      service_endpoints = ["Microsoft.KeyVault", "Microsoft.ContainerRegistry", "Microsoft.Storage"]
    }
    aks_user = {
      name              = var.names["subnet_aks_user"]
      address_prefixes  = [var.subnet_cidrs.aks_user]
      service_endpoints = ["Microsoft.KeyVault", "Microsoft.ContainerRegistry", "Microsoft.Storage"]
    }
    private_endpoints = {
      name = var.names["subnet_private_endpoints"]
      address_prefixes = [var.subnet_cidrs.private_endpoints]
      # No service endpoints here: this subnet's entire purpose is to host
      # private endpoint NICs, which use Private Link rather than the service
      # endpoint mechanism.
      service_endpoints = []
    }
    appgw = {
      name              = var.names["subnet_appgw"]
      address_prefixes  = [var.subnet_cidrs.appgw]
      service_endpoints = []
    }
  }

  # NSGs are not created for snet-appgw: it is empty and reserved, and an NSG
  # with no resources behind it is pure noise. Keyed by the same keys as
  # local.subnets so the association resource below can look each one up.
  nsg_subnet_keys = ["aks_system", "aks_user", "private_endpoints"]
}

# -----------------------------------------------------------------------------
# Virtual network
# -----------------------------------------------------------------------------

resource "azurerm_virtual_network" "this" {
  name                = var.names["vnet"]
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = [var.vnet_address_space]
  tags                = local.tags
}

resource "azurerm_subnet" "this" {
  for_each = local.subnets

  name                 = each.value.name
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = each.value.address_prefixes
  service_endpoints    = each.value.service_endpoints
}

# -----------------------------------------------------------------------------
# Network security groups
# -----------------------------------------------------------------------------
# Deliberately thin. AKS manages a set of rules on the node NICs directly;
# duplicating or fighting those here produces drift without adding security.
# Each NSG below encodes only what AKS leaves to the platform operator.
# -----------------------------------------------------------------------------

resource "azurerm_network_security_group" "this" {
  for_each = toset(local.nsg_subnet_keys)

  name                = var.names["nsg_${each.key}"]
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = local.tags
}

# --- snet-aks-system and snet-aks-user: shared baseline rules ---------------
# Both node subnets get the same two rules: there is no legitimate direct
# inbound path to a node from the Internet (ingress always arrives through
# the Kubernetes-managed Standard Load Balancer, which evaluates its own
# rules ahead of the subnet NSG), and AKS's required control-plane and image
# pull traffic is outbound-only and already covered by Azure's default
# AllowInternetOutBound / AllowVnetOutBound rules -- so nothing needs to be
# added for outbound to work, only for inbound to be locked down.
resource "azurerm_network_security_rule" "deny_internet_inbound" {
  for_each = toset(["aks_system", "aks_user"])

  name                        = "DenyInternetInbound"
  priority                    = 200
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "Internet"
  destination_address_prefix  = "*"
  resource_group_name        = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.this[each.key].name
}

# --- snet-aks-user -> snet-private-endpoints: contain lateral movement -----
# A compromised application pod lands on a node in snet-aks-user. Without
# this pair of rules it could port-scan every private endpoint in the VNet
# (Key Vault, ACR) on any port. HTTPS (443) is allowed because that is the
# only protocol a workload legitimately needs against a private endpoint;
# everything else to that subnet is denied. Priority order matters: the
# allow rule must be evaluated before the deny rule.
resource "azurerm_network_security_rule" "allow_user_to_pe_https" {
  name                         = "AllowAksUserToPrivateEndpointsHttps"
  priority                     = 200
  direction                    = "Outbound"
  access                       = "Allow"
  protocol                     = "Tcp"
  source_port_range            = "*"
  destination_port_range       = "443"
  source_address_prefix        = var.subnet_cidrs.aks_user
  destination_address_prefix   = var.subnet_cidrs.private_endpoints
  resource_group_name          = var.resource_group_name
  network_security_group_name  = azurerm_network_security_group.this["aks_user"].name
}

resource "azurerm_network_security_rule" "deny_user_to_pe_other" {
  name                         = "DenyAksUserToPrivateEndpointsOther"
  priority                     = 210
  direction                    = "Outbound"
  access                       = "Deny"
  protocol                     = "*"
  source_port_range            = "*"
  destination_port_range       = "*"
  source_address_prefix        = var.subnet_cidrs.aks_user
  destination_address_prefix   = var.subnet_cidrs.private_endpoints
  resource_group_name          = var.resource_group_name
  network_security_group_name  = azurerm_network_security_group.this["aks_user"].name
}

# --- snet-private-endpoints: defence in depth ------------------------------
# Private endpoint NICs have no public IP and are unreachable from the
# Internet by construction, but an explicit deny documents the intent and
# protects against a future misconfiguration (e.g. someone attaching a public
# IP directly to a NIC in this subnet).
resource "azurerm_network_security_rule" "deny_internet_inbound_pe" {
  name                         = "DenyInternetInbound"
  priority                     = 200
  direction                    = "Inbound"
  access                       = "Deny"
  protocol                     = "*"
  source_port_range            = "*"
  destination_port_range       = "*"
  source_address_prefix        = "Internet"
  destination_address_prefix   = "*"
  resource_group_name          = var.resource_group_name
  network_security_group_name  = azurerm_network_security_group.this["private_endpoints"].name
}

resource "azurerm_subnet_network_security_group_association" "this" {
  for_each = toset(local.nsg_subnet_keys)

  subnet_id                 = azurerm_subnet.this[each.key].id
  network_security_group_id = azurerm_network_security_group.this[each.key].id
}

# NSG flow + diagnostic visibility. Routed to Log Analytics so "what did this
# NSG actually allow/deny" is answerable without re-running `az network
# watcher` interactively during an incident.
resource "azurerm_monitor_diagnostic_setting" "nsg" {
  for_each = toset(local.nsg_subnet_keys)

  name                       = "diag-${azurerm_network_security_group.this[each.key].name}"
  target_resource_id         = azurerm_network_security_group.this[each.key].id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "NetworkSecurityGroupEvent"
  }

  enabled_log {
    category = "NetworkSecurityGroupRuleCounter"
  }
}

# -----------------------------------------------------------------------------
# NAT Gateway: deterministic, allow-listable egress
# -----------------------------------------------------------------------------

resource "azurerm_public_ip" "nat" {
  count = var.enable_nat_gateway ? 1 : 0

  name                = var.names["nat_public_ip"]
  resource_group_name = var.resource_group_name
  location            = var.location

  # Standard SKU is required for NAT Gateway attachment and is always
  # zone-redundant by default, unlike Basic. Static allocation is what makes
  # the egress IP a stable, allow-listable value across the gateway's life.
  sku               = "Standard"
  allocation_method = "Static"

  tags = local.tags
}

resource "azurerm_nat_gateway" "this" {
  count = var.enable_nat_gateway ? 1 : 0

  name                = var.names["nat_gateway"]
  resource_group_name = var.resource_group_name
  location            = var.location

  # Standard is the only SKU NAT Gateway offers; stated explicitly rather
  # than relying on the provider default so a future provider change cannot
  # silently alter it.
  sku_name = "Standard"

  # Idle flow timeout. Azure's default (4 minutes) is usually fine; raising
  # it slightly reduces SNAT port churn for long-lived keep-alive connections
  # (e.g. a pod holding an open gRPC stream to an external API) without
  # meaningfully delaying port reuse.
  idle_timeout_in_minutes = 10

  tags = local.tags
}

resource "azurerm_nat_gateway_public_ip_association" "this" {
  count = var.enable_nat_gateway ? 1 : 0

  nat_gateway_id       = azurerm_nat_gateway.this[0].id
  public_ip_address_id = azurerm_public_ip.nat[0].id
}

# Associated to both node subnets -- NOT to snet-private-endpoints (private
# endpoints need no outbound internet path) and NOT to snet-appgw (reserved,
# empty).
resource "azurerm_subnet_nat_gateway_association" "this" {
  for_each = var.enable_nat_gateway ? toset(["aks_system", "aks_user"]) : toset([])

  subnet_id      = azurerm_subnet.this[each.key].id
  nat_gateway_id = azurerm_nat_gateway.this[0].id
}

# -----------------------------------------------------------------------------
# Route table: reserved for future UDR
# -----------------------------------------------------------------------------
# Deliberately empty. `outbound_type = "userAssignedNATGateway"` needs no
# UDR -- this exists so that adopting a hub-and-spoke egress model later (see
# "Rejected: hub-and-spoke with Azure Firewall" in docs/architecture.md) means
# adding routes to an already-associated table rather than creating and
# re-associating a new one, which would briefly interrupt traffic on the
# subnet.
# -----------------------------------------------------------------------------

resource "azurerm_route_table" "this" {
  name                = var.names["route_table"]
  resource_group_name = var.resource_group_name
  location            = var.location

  # BGP route propagation from a (currently nonexistent) ExpressRoute/VPN
  # gateway is disabled: this platform has no on-premises connectivity today,
  # and leaving propagation on is a routing surprise waiting to happen the
  # day one is added elsewhere in the subscription.
  bgp_route_propagation_enabled = false

  tags = local.tags
}

resource "azurerm_subnet_route_table_association" "this" {
  for_each = toset(["aks_system", "aks_user"])

  subnet_id      = azurerm_subnet.this[each.key].id
  route_table_id = azurerm_route_table.this.id
}

# -----------------------------------------------------------------------------
# Private DNS zones (prod only, via enable_private_dns_zones)
# -----------------------------------------------------------------------------
# Three zones, matching exactly the three private-link-capable services this
# platform deploys. The AKS zone is created here (network owns DNS) but
# consumed by the private API server, which modules/aks wires up -- the zone
# ID is not an output here because modules/aks reads the cluster's own
# private DNS requirements; only the ACR- and Key-Vault-facing zone IDs are
# returned to callers (see outputs.tf).
# -----------------------------------------------------------------------------

locals {
  private_dns_zone_names = var.enable_private_dns_zones ? {
    key_vault    = "privatelink.vaultcore.azure.net"
    acr_registry = "privatelink.azurecr.io"
    # ACR's DATA plane (blob pulls) resolves through a second, region-scoped
    # zone distinct from the registry/login zone above -- a frequent source
    # of "image pulls fail but `docker login` works" confusion if omitted.
    acr_data = "privatelink.${var.location}.data.azurecr.io"
    aks      = "privatelink.${var.location}.azmk8s.io"
  } : {}
}

resource "azurerm_private_dns_zone" "this" {
  for_each = local.private_dns_zone_names

  name                = each.value
  resource_group_name = var.resource_group_name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  for_each = local.private_dns_zone_names

  name                  = "link-${azurerm_virtual_network.this.name}"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.this[each.key].name
  virtual_network_id    = azurerm_virtual_network.this.id

  # Zones created by this module are only ever consumed inside this one VNet
  # today (no hub-and-spoke, no cross-VNet Private Link), so auto-registration
  # of VM DNS records would add nothing and only obscure the explicit
  # A-records a private endpoint's DNS zone group writes.
  registration_enabled = false
}

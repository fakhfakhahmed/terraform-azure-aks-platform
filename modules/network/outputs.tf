# =============================================================================
# modules/network/outputs.tf
# =============================================================================

output "vnet_id" {
  description = "Resource ID of the virtual network."
  value       = azurerm_virtual_network.this.id
}

output "vnet_name" {
  description = "Name of the virtual network."
  value       = azurerm_virtual_network.this.name
}

output "subnet_ids" {
  description = "Subnet resource IDs keyed aks_system, aks_user, private_endpoints, appgw."
  value = {
    for key, subnet in azurerm_subnet.this : key => subnet.id
  }
}

output "nsg_ids" {
  description = "Network security group resource IDs keyed aks_system, aks_user, private_endpoints. No entry for appgw -- that subnet has no NSG (reserved, empty)."
  value = {
    for key, nsg in azurerm_network_security_group.this : key => nsg.id
  }
}

output "route_table_id" {
  description = "Resource ID of the (currently empty, reserved-for-UDR) route table."
  value       = azurerm_route_table.this.id
}

output "nat_gateway_id" {
  description = "Resource ID of the NAT Gateway, or null if enable_nat_gateway = false."
  value       = var.enable_nat_gateway ? azurerm_nat_gateway.this[0].id : null
}

output "nat_public_ip_address" {
  description = "The NAT Gateway's static public IP address (dotted-quad), or null if enable_nat_gateway = false. This is the one address every packet leaving the cluster carries -- hand it to partners for allow-listing."
  value       = var.enable_nat_gateway ? azurerm_public_ip.nat[0].ip_address : null
}

output "private_dns_zone_ids" {
  description = "Private DNS zone resource IDs keyed key_vault, acr_registry, acr_data, aks. Empty map when enable_private_dns_zones = false."
  value = {
    for key, zone in azurerm_private_dns_zone.this : key => zone.id
  }
}

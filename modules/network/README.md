# modules/network

VNet, four fixed subnets, per-subnet NSGs, NAT Gateway egress, a reserved route table, and
(optionally) the three privatelink DNS zones this platform's private endpoints need. See
"1. Azure resource topology" and "IP address plan" in
[docs/architecture.md](../../docs/architecture.md) for the full design rationale.

## Usage

```hcl
module "naming" {
  source      = "../../modules/naming"
  prefix      = "aksplat"
  environment = "prod"
  location    = "westeurope"
  owner       = "ahmed.fakhfakh"
  cost_center = "platform-engineering"
}

resource "azurerm_resource_group" "this" {
  name     = module.naming.names["resource_group"]
  location = "westeurope"
  tags     = module.naming.tags
}

module "network" {
  source = "../../modules/network"

  names                = module.naming.names
  resource_group_name  = azurerm_resource_group.this.name
  location             = "westeurope"
  tags                 = module.naming.tags

  vnet_address_space = "10.30.0.0/16"
  subnet_cidrs = {
    aks_system        = "10.30.0.0/20"
    aks_user          = "10.30.16.0/20"
    private_endpoints = "10.30.32.0/24"
    appgw             = "10.30.33.0/24"
  }

  enable_private_dns_zones   = true # prod only; false in dev/staging
  log_analytics_workspace_id = module.observability.log_analytics_workspace_id
}
```

## Design notes

- **Modules never call each other.** This module takes `names` (the full map from
  `modules/naming`, passed through unchanged) rather than reaching into that module itself --
  composition happens in the environment root. See design principle 4 in
  [docs/architecture.md](../../docs/architecture.md).
- **`snet-appgw` gets no NSG, no NAT association, no route table association.** It is reserved
  and empty by design -- see "Deferred: Application Gateway Ingress Controller".
- **The route table is intentionally empty.** `outbound_type = "userAssignedNATGateway"` needs no
  UDR today; the table exists pre-associated so adding one later needs no subnet re-association.
- **Private DNS zones are the caller's decision**, via `enable_private_dns_zones`. This platform
  only deploys private endpoints in prod (see "Environment topology differences"), but this
  module does not hardcode that -- it takes a bool.

## Requirements

| Name | Version |
|---|---|
| terraform | >= 1.9.0 |
| azurerm | ~> 4.0 |

## Providers

| Name | Version |
|---|---|
| azurerm | ~> 4.0 |

## Inputs

| Name | Description | Type | Default | Required |
|---|---|---|---|---|
| names | `names` map from modules/naming, passed through unchanged | `map(string)` | n/a | yes |
| resource_group_name | Resource group to create resources in | `string` | n/a | yes |
| location | Azure region | `string` | n/a | yes |
| tags | Tags applied to every taggable resource | `map(string)` | `{}` | no |
| vnet_address_space | VNet CIDR, e.g. `"10.30.0.0/16"` | `string` | n/a | yes |
| subnet_cidrs | Object with `aks_system`, `aks_user`, `private_endpoints`, `appgw` CIDR strings | `object(...)` | n/a | yes |
| enable_private_dns_zones | Create and VNet-link the three privatelink DNS zones | `bool` | `true` | no |
| log_analytics_workspace_id | Workspace ID for NSG diagnostic settings | `string` | n/a | yes |
| enable_nat_gateway | Attach a NAT Gateway with a static public IP to the node subnets | `bool` | `true` | no |

## Outputs

| Name | Description |
|---|---|
| vnet_id | VNet resource ID |
| vnet_name | VNet name |
| subnet_ids | Map keyed `aks_system`, `aks_user`, `private_endpoints`, `appgw` |
| nsg_ids | Map keyed `aks_system`, `aks_user`, `private_endpoints` (no `appgw` entry) |
| route_table_id | Resource ID of the reserved, empty route table |
| nat_gateway_id | NAT Gateway resource ID, or `null` if disabled |
| nat_public_ip_address | The NAT Gateway's static egress IP, or `null` if disabled |
| private_dns_zone_ids | Map keyed `key_vault`, `acr_registry`, `acr_data`, `aks`; empty map if disabled |

## Resources

- `azurerm_virtual_network.this`
- `azurerm_subnet.this` (for_each over 4 subnets)
- `azurerm_network_security_group.this` (for_each over 3 subnets -- not `appgw`)
- `azurerm_network_security_rule.deny_internet_inbound` (aks_system, aks_user)
- `azurerm_network_security_rule.allow_user_to_pe_https`
- `azurerm_network_security_rule.deny_user_to_pe_other`
- `azurerm_network_security_rule.deny_internet_inbound_pe`
- `azurerm_subnet_network_security_group_association.this`
- `azurerm_monitor_diagnostic_setting.nsg`
- `azurerm_public_ip.nat`
- `azurerm_nat_gateway.this`
- `azurerm_nat_gateway_public_ip_association.this`
- `azurerm_subnet_nat_gateway_association.this`
- `azurerm_route_table.this`
- `azurerm_subnet_route_table_association.this`
- `azurerm_private_dns_zone.this` (for_each over up to 4 zones)
- `azurerm_private_dns_zone_virtual_network_link.this`

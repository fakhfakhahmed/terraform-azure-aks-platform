# modules/naming

Computes every resource name and the common tag set for one environment. Pure HCL: no provider,
no resources. Every other module in this platform (`network`, `acr`, `aks`, `identity`,
`keyvault`, `observability`) consumes this module's output rather than inventing names itself --
see "Module composition" in [docs/architecture.md](../../docs/architecture.md).

## Usage

```hcl
module "naming" {
  source = "../../modules/naming"

  prefix      = "aksplat"
  environment = "prod"
  location    = "westeurope"

  owner       = "ahmed.fakhfakh"
  cost_center = "platform-engineering"

  additional_tags = {
    ticket = "PLAT-1234"
  }
}

# Consumers destructure the names map, e.g.:
resource "azurerm_resource_group" "this" {
  name     = module.naming.names["resource_group"]
  location = "westeurope"
  tags     = module.naming.tags
}
```

## Naming convention

| Shape | Applies to | Example |
|---|---|---|
| `{type}-{prefix}-{environment}-{region_short}` | Most resources | `vnet-aksplat-prod-weu` |
| `{type}-{workload}` (no prefix/env/region) | Subnets and their NSGs -- unique inside their VNet | `snet-aks-system`, `nsg-aks-system` |
| `{type}{prefix}{environment}{region_short}` (no separators) | Globally-unique, alphanumeric-only resources | `acraksplatprodweu` |

`region_short` comes from the same abbreviation table as `bootstrap/main.tf` (duplicated there
deliberately -- see that file's header comment on the bootstrap chicken-and-egg problem).

## Requirements

| Name | Version |
|---|---|
| terraform | >= 1.9.0 |

No providers are required -- this module performs no Azure API calls.

## Providers

None.

## Inputs

| Name | Description | Type | Default | Required |
|---|---|---|---|---|
| prefix | Short organisation/workload prefix, 2-24 chars lowercase alphanumeric | `string` | n/a | yes |
| environment | `dev`, `staging`, or `prod` | `string` | n/a | yes |
| location | Full Azure region name, e.g. `westeurope` | `string` | n/a | yes |
| owner | Owner tag value | `string` | n/a | yes |
| cost_center | Cost centre tag value | `string` | n/a | yes |
| additional_tags | Extra tags merged over the computed defaults | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|---|---|
| names | Map of every computed resource name, keyed by logical resource (see main.tf) |
| tags | Common tag set: environment, project, owner, managed_by, cost_center, plus additional_tags |
| region_short | Abbreviated region token, e.g. `weu` |
| resource_group_name | Convenience accessor for `names["resource_group"]` |
| vnet_name | Convenience accessor for `names["vnet"]` |
| aks_name | Convenience accessor for `names["aks"]` |
| acr_name | Convenience accessor for `names["acr"]` |
| key_vault_name | Convenience accessor for `names["key_vault"]` |
| log_analytics_name | Convenience accessor for `names["log_analytics"]` |

### Keys present in `names`

`resource_group`, `vnet`, `subnet_aks_system`, `subnet_aks_user`, `subnet_private_endpoints`,
`subnet_appgw`, `nsg_aks_system`, `nsg_aks_user`, `nsg_private_endpoints`, `nat_gateway`,
`nat_public_ip`, `route_table`, `aks`, `acr`, `key_vault`, `log_analytics`, `app_insights`,
`action_group`, `user_assigned_identity_prefix`.

`user_assigned_identity_prefix` is a prefix string only -- `modules/identity` appends
`-<workload-key>` per workload identity it creates.

## Resources

None -- this module declares no resources, only locals and outputs.

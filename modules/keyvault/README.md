# modules/keyvault

Provisions an Azure Key Vault with RBAC authorisation, optional private endpoint, diagnostic
settings, and per-workload "Key Vault Secrets User" role assignments.

## Usage

```hcl
module "keyvault" {
  source = "../../modules/keyvault"

  name                 = module.naming.names.key_vault
  resource_group_name  = azurerm_resource_group.this.name
  location             = var.location
  tags                 = local.tags

  sku_name                    = "standard"
  purge_protection_enabled    = var.environment != "dev"
  soft_delete_retention_days  = var.environment == "prod" ? 90 : 7

  public_network_access_enabled = var.environment != "prod"
  network_acls_default_action   = var.environment == "prod" ? "Deny" : "Allow"

  private_endpoint_subnet_id = var.environment == "prod" ? module.network.private_endpoint_subnet_id : null
  private_dns_zone_ids       = var.environment == "prod" ? [module.network.private_dns_zone_ids["vault"]] : []

  log_analytics_workspace_id = module.observability.log_analytics_workspace_id
  workload_principal_ids     = module.identity.principal_ids
}
```

## Design notes

- **RBAC authorisation over access policies.** `enable_rbac_authorization = true` is set
  unconditionally. Access policies are a single vault-wide, all-or-nothing grant list with a
  ~1024-entry practical ceiling and no scoping below "the whole vault's secrets/keys/certs" or
  conditional access; RBAC role assignments are auditable ARM objects, support PIM and ABAC
  conditions, and compose with the rest of Azure's authorization model used everywhere else in
  this platform. See the comment block above `azurerm_key_vault.this` in `main.tf`.
- **`purge_protection_enabled` is a one-way door** at the Azure API level — once true it can
  never be set back to false on that vault. On in staging/prod; off in dev, where vaults are
  created and destroyed routinely.
- **No `prevent_destroy` in this module.** Per the "same code path, different config" design
  principle, a Terraform meta-argument that cannot be parameterised by a variable belongs in the
  environment root, not in a reusable module — prod's `envs/prod/main.tf` applies it there.
- **Private endpoint is optional and off by default** (`private_endpoint_subnet_id = null`). Only
  prod wires one up, per `docs/architecture.md`'s environment topology table.

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
| name | Precomputed vault name | `string` | n/a | yes |
| resource_group_name | Resource group | `string` | n/a | yes |
| location | Azure region | `string` | n/a | yes |
| tags | Tags merged onto the vault and its private endpoint | `map(string)` | `{}` | no |
| sku_name | `standard` \| `premium` | `string` | `"standard"` | no |
| purge_protection_enabled | One-way-door purge protection | `bool` | `false` | no |
| soft_delete_retention_days | 7-90 | `number` | `90` | no |
| public_network_access_enabled | Whether the data plane is reachable publicly | `bool` | `true` | no |
| network_acls_default_action | `Allow` \| `Deny` | `string` | `"Allow"` | no |
| allowed_ip_rules | Allow-listed CIDRs/IPs | `list(string)` | `[]` | no |
| private_endpoint_subnet_id | Subnet for the private endpoint, or null to skip it | `string` | `null` | no |
| private_dns_zone_ids | Private DNS zone IDs for the endpoint's DNS zone group | `list(string)` | `[]` | no |
| log_analytics_workspace_id | Workspace for AuditEvent/AllMetrics diagnostics | `string` | n/a | yes |
| workload_principal_ids | Map of workload key -> principal ID granted Key Vault Secrets User | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|---|---|
| key_vault_id | Resource ID of the vault |
| key_vault_uri | Data-plane URI, consumed by SecretProviderClass |
| key_vault_name | Name of the vault |

## Resources

- `azurerm_key_vault.this`
- `azurerm_private_endpoint.key_vault` (count, only when `private_endpoint_subnet_id != null`)
- `azurerm_monitor_diagnostic_setting.key_vault`
- `azurerm_role_assignment.workload` (for_each over `workload_principal_ids`)

# modules/acr

Azure Container Registry: no admin credential ever, optional Premium geo-replication and private
endpoint, retention policy for untagged manifests, diagnostics routed to Log Analytics. See
"Who consumes what" in [docs/architecture.md](../../docs/architecture.md) -- the registry's own
`acr_id` output is consumed by `modules/aks` for the `AcrPull` role assignment.

## Usage

```hcl
module "acr" {
  source = "../../modules/acr"

  name                 = module.naming.names["acr"]
  resource_group_name  = azurerm_resource_group.this.name
  location             = "westeurope"
  tags                 = module.naming.tags

  sku                            = "Premium" # Basic in dev, Standard in staging, Premium in prod
  public_network_access_enabled = false      # true in dev/staging, which have no private endpoint

  private_endpoint_subnet_id = module.network.subnet_ids["private_endpoints"]
  private_dns_zone_ids = [
    module.network.private_dns_zone_ids["acr_registry"],
    module.network.private_dns_zone_ids["acr_data"],
  ]

  geo_replication_locations = [
    { location = "northeurope", zone_redundancy_enabled = true },
  ]

  retention_policy_days      = 7
  log_analytics_workspace_id = module.observability.log_analytics_workspace_id
}
```

## Design notes

- **`admin_enabled` is hardcoded `false` on the resource**, not read from the variable of the same
  name. The variable exists (with a validation that rejects any value but `false`) purely so the
  intent is visible to a reviewer and in `terraform plan` -- see that variable's description in
  `variables.tf`. A `lifecycle.precondition` on the resource is a third, belt-and-braces guard.
- **`trust_policy_enabled` is accepted but not wired to anything.** azurerm's `trust_policy` block
  was removed from this resource as of the v4.0 provider, following Azure's own retirement of
  Docker Content Trust for ACR. See the comment in `main.tf` and "No image signing / content
  trust" in `docs/architecture.md`'s known-gaps table -- the real replacement is
  Notation/cosign signing in CI plus Ratify + Gatekeeper admission.
- **Geo-replication and the retention policy are Premium-only** and collapse to "do nothing" below
  Premium, so a single module call can be reused across environments that differ only by `sku` in
  `.tfvars`.

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
| name | Precomputed globally-unique registry name | `string` | n/a | yes |
| resource_group_name | Resource group to create the registry in | `string` | n/a | yes |
| location | Azure region | `string` | n/a | yes |
| tags | Tags applied to the registry | `map(string)` | `{}` | no |
| sku | `Basic`, `Standard`, or `Premium` | `string` | `"Premium"` | no |
| admin_enabled | Must be `false` (enforced); see Design notes | `bool` | `false` | no |
| public_network_access_enabled | Whether the data-plane endpoint is publicly reachable | `bool` | `true` | no |
| private_endpoint_subnet_id | Subnet for the private endpoint NIC; `null` to skip | `string` | `null` | no |
| private_dns_zone_ids | DNS zone IDs for the private endpoint's zone group | `list(string)` | `[]` | no |
| geo_replication_locations | Additional regions to replicate to (Premium only) | `list(object({location=string, zone_redundancy_enabled=bool}))` | `[]` | no |
| retention_policy_days | Untagged manifest retention, in days (Premium only) | `number` | `7` | no |
| log_analytics_workspace_id | Workspace for diagnostic settings | `string` | n/a | yes |
| trust_policy_enabled | Accepted for interface stability; not wired (see Design notes) | `bool` | `false` | no |

## Outputs

| Name | Description |
|---|---|
| acr_id | Registry resource ID |
| acr_name | Registry name |
| acr_login_server | Login server FQDN, e.g. `acraksplatprodweu.azurecr.io` |

## Resources

- `azurerm_container_registry.this`
- `azurerm_private_endpoint.this` (count: Premium + subnet supplied only)
- `azurerm_monitor_diagnostic_setting.this`

# modules/aks

Provisions the AKS cluster: a control-plane user-assigned identity, the cluster itself with its
system (default) node pool, a separate autoscaling user node pool, and the `AcrPull` role
assignment(s) that let the kubelet pull images with no `imagePullSecret`.

This module does **not** create a resource group, VNet/subnets, or a Log Analytics workspace.
Those come from `modules/network` and `modules/observability` and are passed in as IDs -- modules
never call each other, composition happens in `envs/<env>/main.tf`. See
[docs/architecture.md](../../docs/architecture.md).

## Usage

```hcl
module "aks" {
  source = "../../modules/aks"

  name                = module.naming.names.aks
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  tags                = local.tags

  kubernetes_version = var.kubernetes_version # null in dev; pinned in staging/prod
  sku_tier           = var.aks_sku_tier
  zones              = var.availability_zones

  private_cluster_enabled = var.private_cluster_enabled
  authorized_ip_ranges    = var.aks_authorized_ip_ranges

  system_node_subnet_id = module.network.subnet_ids["aks_system"]
  user_node_subnet_id   = module.network.subnet_ids["aks_user"]

  system_node_vm_size = var.system_node_vm_size
  system_node_count   = var.system_node_count

  user_node_vm_size    = var.user_node_vm_size
  user_node_min_count  = var.user_node_min_count
  user_node_max_count  = var.user_node_max_count

  network_policy = var.network_policy

  log_analytics_workspace_id = module.observability.log_analytics_workspace_id
  attached_acr_ids           = [module.acr.acr_id]
  admin_group_object_ids     = var.aks_admin_group_object_ids

  automatic_upgrade_channel = "patch"
  node_os_upgrade_channel   = "NodeImage"
  maintenance_window_day    = "Sunday"
  maintenance_window_hours  = [2, 3]
}
```

## Design notes

- **System pool never autoscales; user pool always does.** The system pool carries only
  `CriticalAddonsOnly`-tolerating add-on pods (CoreDNS, konnectivity, metrics-server, CSI
  drivers), whose load scales with cluster size, not request volume -- autoscaling it adds
  complexity for no benefit. The user pool is a hard **minimum requirement** to autoscale per
  this module's contract, since it is where elastic application load actually lands.
- **`only_critical_addons_enabled = true`** is the declarative equivalent of the
  `CriticalAddonsOnly=true:NoSchedule` taint, applied to the whole default node pool. See
  docs/architecture.md, "Why a system/user node-pool split".
- **`temporary_name_for_rotation`** is required by azurerm v4 so that resizing or changing the
  default node pool's VM size triggers the provider's create-new/drain/delete-old rotation
  instead of a hard failure.
- **AcrPull targets the kubelet identity**, not the control-plane identity this module also
  creates. Mixing these up is the single most common cause of `ImagePullBackOff` with an opaque
  401. See `azurerm_role_assignment.kubelet_acr_pull` in `main.tf`.
- **`outbound_type = "userAssignedNATGateway"`** requires the node subnets to already be
  associated with a NAT Gateway -- done in `modules/network`. This module never references a NAT
  Gateway resource ID directly.
- **Maintenance windows** take a single weekday + list of UTC hours (e.g. `"Sunday"`, `[2, 3]`)
  and are translated internally into the `start_time`/`duration` shape the azurerm v4
  `maintenance_window_auto_upgrade` / `maintenance_window_node_os` blocks expect.

## azurerm v4 argument renames applied here

| v3 name | v4 name used in this module |
|---|---|
| `enable_auto_scaling` | `auto_scaling_enabled` |
| `enable_node_public_ip` | `node_public_ip_enabled` |

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
| name | Precomputed cluster resource name | `string` | n/a | yes |
| resource_group_name | Resource group the cluster is deployed into | `string` | n/a | yes |
| location | Azure region | `string` | n/a | yes |
| tags | Tags merged onto every resource this module creates | `map(string)` | `{}` | no |
| kubernetes_version | Kubernetes version, or null to let Azure pick the default | `string` | `null` | no |
| sku_tier | `Free` \| `Standard` \| `Premium` | `string` | n/a | yes |
| private_cluster_enabled | Whether the API server has only a private endpoint | `bool` | n/a | yes |
| system_node_subnet_id | Subnet ID for the system node pool | `string` | n/a | yes |
| user_node_subnet_id | Subnet ID for the user node pool | `string` | n/a | yes |
| system_node_vm_size | VM SKU for the system node pool | `string` | n/a | yes |
| system_node_count | Fixed node count for the system node pool | `number` | n/a | yes |
| user_node_vm_size | VM SKU for the user node pool | `string` | n/a | yes |
| user_node_min_count | Autoscaler floor for the user node pool | `number` | n/a | yes |
| user_node_max_count | Autoscaler ceiling for the user node pool | `number` | n/a | yes |
| zones | Availability zones for both node pools | `list(string)` | `[]` | no |
| network_policy | `azure` \| `cilium` | `string` | n/a | yes |
| log_analytics_workspace_id | Workspace ID for Container Insights and diagnostics | `string` | n/a | yes |
| attached_acr_ids | ACR IDs to grant the kubelet identity AcrPull on | `list(string)` | `[]` | no |
| admin_group_object_ids | Entra group IDs bound to the Kubernetes RBAC Cluster Admin role | `list(string)` | `[]` | no |
| automatic_upgrade_channel | Control-plane auto-upgrade channel | `string` | `"patch"` | no |
| node_os_upgrade_channel | Node OS image upgrade channel | `string` | `"NodeImage"` | no |
| maintenance_window_day | Weekday maintenance is allowed to run | `string` | n/a | yes |
| maintenance_window_hours | UTC hours maintenance is allowed to run | `list(number)` | n/a | yes |
| authorized_ip_ranges | CIDRs allowed to reach a public API server | `list(string)` | `[]` | no |
| outbound_type | AKS egress method | `string` | `"userAssignedNATGateway"` | no |

## Outputs

| Name | Description |
|---|---|
| cluster_id | Resource ID of the AKS cluster |
| cluster_name | Name of the AKS cluster |
| oidc_issuer_url | Public OIDC issuer URL, consumed by modules/identity |
| kubelet_identity_object_id | Object ID of the kubelet identity (AcrPull target) |
| cluster_identity_principal_id | Principal ID of the control-plane user-assigned identity |
| node_resource_group | The auto-managed MC_* resource group |
| cluster_fqdn | API server FQDN, private or public as applicable |

## Resources

- `azurerm_user_assigned_identity.control_plane`
- `azurerm_kubernetes_cluster.this`
- `azurerm_kubernetes_cluster_node_pool.user`
- `azurerm_role_assignment.kubelet_acr_pull` (for_each over `attached_acr_ids`)

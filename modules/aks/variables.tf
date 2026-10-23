# =============================================================================
# modules/aks/variables.tf
# =============================================================================
# This module owns exactly one azurerm_kubernetes_cluster plus its user node
# pool, control-plane identity and ACR role assignments. It does NOT create
# its own resource group, VNet/subnets, or Log Analytics workspace -- those
# are produced by modules/network and modules/observability and consumed here
# as plain IDs, per the "modules never call each other" rule in
# docs/architecture.md (Design principle 4 / Module composition).
# =============================================================================

variable "name" {
  description = <<-EOT
    The cluster's resource name, precomputed by modules/naming in the
    environment root (e.g. "aks-aksplat-prod-weu"). This module does not
    compute names itself so that naming conventions stay centralised in one
    module, per docs/architecture.md's "Module composition" table.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9_-]{0,61}[a-zA-Z0-9]$", var.name))
    error_message = "AKS cluster names must be 2-63 characters, start/end alphanumeric, and contain only letters, numbers, underscores and hyphens."
  }
}

variable "resource_group_name" {
  description = "Name of the resource group the cluster is deployed into."
  type        = string
}

variable "location" {
  description = "Azure region for the cluster and every resource this module creates (control-plane identity, node pool, role assignments)."
  type        = string
}

variable "tags" {
  description = "Tags merged onto every taggable resource this module creates."
  type        = map(string)
  default     = {}
}

variable "kubernetes_version" {
  description = <<-EOT
    Kubernetes version to pin the control plane and default node pool to.
    Pass null to let Azure provision the current default version for the
    region and let `automatic_upgrade_channel` manage drift from there --
    this is the recommended setting for dev, where chasing a specific patch
    manually is wasted effort. Pin an explicit version (e.g. "1.29.7") in
    staging/prod once you need deterministic, change-controlled upgrades.
  EOT
  type        = string
  default     = null
}

variable "sku_tier" {
  description = <<-EOT
    AKS control-plane pricing tier. "Free" has no uptime SLA and a lower API
    server request/rate-limit ceiling -- acceptable in dev, where discovering
    control-plane throttling early (as an annoyance) beats discovering it in
    prod (as an incident). "Standard" carries a 99.95% SLA and is required for
    anything serving real traffic. "Premium" adds Long Term Support for
    extended Kubernetes version support windows.
  EOT
  type        = string

  validation {
    condition     = contains(["Free", "Standard", "Premium"], var.sku_tier)
    error_message = "sku_tier must be one of: Free, Standard, Premium."
  }
}

variable "private_cluster_enabled" {
  description = <<-EOT
    When true, the API server is reachable only through a private endpoint
    inside the VNet (see snet-private-endpoints in docs/architecture.md) and
    has no public FQDN. Prod runs private; dev and staging run public to keep
    `kubectl` reachable from a laptop without a VPN/bastion, trading that
    convenience for the `authorized_ip_ranges` allow-list below.
  EOT
  type        = bool
}

variable "system_node_subnet_id" {
  description = "Subnet ID (from modules/network) that the system node pool's NICs are placed in. Sized for nodes, not nodes x max_pods, because Azure CNI overlay keeps pod IPs out of the VNet -- see docs/architecture.md, 'Why /20 for node subnets'."
  type        = string
}

variable "user_node_subnet_id" {
  description = "Subnet ID (from modules/network) that the user node pool's NICs are placed in."
  type        = string
}

variable "system_node_vm_size" {
  description = "VM SKU for the system node pool. Differs per environment: Standard_B2s (dev, burstable, cheap) through Standard_D4s_v5 (prod)."
  type        = string
}

variable "system_node_count" {
  description = <<-EOT
    Fixed node count for the system (default) node pool. The system pool
    deliberately does NOT autoscale in this module: it carries only
    CoreDNS/konnectivity/metrics-server/CSI-driver pods (see
    `only_critical_addons_enabled` in main.tf), whose load is proportional to
    cluster size, not to request volume -- autoscaling it buys nothing and
    adds one more moving part to a component you want boringly stable. The
    user pool is where elasticity actually matters, and it is the pool that
    is REQUIRED to autoscale per this module's contract (see
    user_node_min_count/user_node_max_count below).
  EOT
  type        = number

  validation {
    condition     = var.system_node_count >= 1 && var.system_node_count <= 100
    error_message = "system_node_count must be between 1 and 100."
  }
}

variable "user_node_vm_size" {
  description = "VM SKU for the user (application workload) node pool."
  type        = string
}

variable "user_node_min_count" {
  description = "Minimum node count the cluster autoscaler will scale the user pool down to."
  type        = number

  validation {
    condition     = var.user_node_min_count >= 1
    error_message = "user_node_min_count must be at least 1 -- a user pool scaled to zero cannot schedule the first pod that would trigger a scale-up."
  }
}

variable "user_node_max_count" {
  description = "Maximum node count the cluster autoscaler will scale the user pool up to."
  type        = number

  validation {
    condition     = var.user_node_max_count >= 1
    error_message = "user_node_max_count must be at least 1."
  }
}

variable "zones" {
  description = <<-EOT
    Availability zones both node pools are spread across, e.g. ["1","2","3"].
    Pass [] for no zone pinning -- the only sane choice in a region/SKU
    combination without zone support, and what dev uses to avoid capacity
    errors on burstable SKUs that are not available in every zone.
  EOT
  type        = list(string)
  default     = []
}

variable "network_policy" {
  description = <<-EOT
    Kubernetes network policy engine. "cilium" (Azure CNI powered by Cilium)
    gives an eBPF dataplane and identity-based policy enforcement; it is used
    in staging/prod. "azure" is used in dev because Cilium's dataplane needs
    node SKU/kernel combinations that interact poorly with the burstable
    Standard_B2s node dev runs on -- see docs/architecture.md, "Network
    policy: Cilium in staging/prod, azure in dev".
  EOT
  type        = string

  validation {
    condition     = contains(["azure", "cilium"], var.network_policy)
    error_message = "network_policy must be one of: azure, cilium."
  }
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics workspace ID (from modules/observability) that Container Insights (oms_agent) and this cluster's diagnostic settings send data to."
  type        = string
}

variable "attached_acr_ids" {
  description = <<-EOT
    Azure Container Registry resource IDs to grant the cluster's KUBELET
    identity (not the control-plane identity -- see the role_assignment
    resource in main.tf) the AcrPull role on. This is what makes
    imagePullSecrets unnecessary; see docs/architecture.md, "The one
    non-obvious edge: ACR to AKS", and kubernetes/README.md.
  EOT
  type        = list(string)
  default     = []
}

variable "admin_group_object_ids" {
  description = <<-EOT
    Entra ID group object IDs bound to the "Azure Kubernetes Service RBAC
    Cluster Admin" role via `azure_active_directory_role_based_access_control`.
    Can be empty in dev, where a single operator typically holds Owner/
    Contributor on the resource group and authenticates with their own Entra
    identity against Azure RBAC for Kubernetes without needing a dedicated
    admin group.
  EOT
  type        = list(string)
  default     = []
}

variable "automatic_upgrade_channel" {
  description = <<-EOT
    Control-plane auto-upgrade channel: "patch" upgrades within the current
    minor version automatically (recommended baseline -- keeps CVEs patched
    without surprise minor-version jumps), "stable", "rapid", "node-image",
    or "none".
  EOT
  type        = string
  default     = "patch"

  validation {
    condition     = contains(["patch", "stable", "rapid", "node-image", "none"], var.automatic_upgrade_channel)
    error_message = "automatic_upgrade_channel must be one of: patch, stable, rapid, node-image, none."
  }
}

variable "node_os_upgrade_channel" {
  description = <<-EOT
    Node OS image upgrade channel, independent of the Kubernetes version
    channel above. "NodeImage" pulls the latest VHD (kernel/OS patches) on
    every release, roughly weekly, which is how node-level CVEs get patched
    without waiting for a Kubernetes version bump.
  EOT
  type        = string
  default     = "NodeImage"

  validation {
    condition     = contains(["Unmanaged", "SecurityPatch", "NodeImage", "None"], var.node_os_upgrade_channel)
    error_message = "node_os_upgrade_channel must be one of: Unmanaged, SecurityPatch, NodeImage, None."
  }
}

variable "maintenance_window_day" {
  description = "Day of week the auto-upgrade and node-OS maintenance windows are allowed to run on, e.g. \"Sunday\". Picking a low-traffic day/hour window bounds when an automatic upgrade can disrupt the cluster."
  type        = string

  validation {
    condition     = contains(["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"], var.maintenance_window_day)
    error_message = "maintenance_window_day must be a full English weekday name, e.g. \"Sunday\"."
  }
}

variable "maintenance_window_hours" {
  description = "Hours of the day (0-23, UTC) within maintenance_window_day that auto-upgrade and node-OS maintenance are allowed to run, e.g. [2, 3] for 02:00-04:00 UTC."
  type        = list(number)

  validation {
    condition     = alltrue([for h in var.maintenance_window_hours : h >= 0 && h <= 23])
    error_message = "maintenance_window_hours must each be between 0 and 23."
  }
}

variable "authorized_ip_ranges" {
  description = <<-EOT
    CIDR ranges allowed to reach the public API server. Only meaningful when
    `private_cluster_enabled = false`; ignored (and not emitted) otherwise.
    Default [] means no restriction -- the API server is reachable from the
    whole internet, which is what dev typically accepts in exchange for not
    needing a VPN, but should be tightened to office/VPN egress ranges
    wherever practical.
  EOT
  type        = list(string)
  default     = []
}

variable "outbound_type" {
  description = <<-EOT
    AKS egress method. "userAssignedNATGateway" is the default and expected
    value for every environment in this platform: it requires the node
    subnets to ALREADY be associated with a user-assigned NAT Gateway, which
    is done upstream in modules/network, not here. AKS itself never owns or
    references the NAT Gateway resource directly -- it only needs to know
    that the subnet's egress is already deterministic. See
    docs/architecture.md, "Why NAT Gateway rather than load-balancer outbound
    SNAT". Valid alternatives ("loadBalancer", "userDefinedRouting") exist for
    completeness but are not exercised by this platform.
  EOT
  type        = string
  default     = "userAssignedNATGateway"

  validation {
    condition     = contains(["loadBalancer", "userDefinedRouting", "userAssignedNATGateway"], var.outbound_type)
    error_message = "outbound_type must be one of: loadBalancer, userDefinedRouting, userAssignedNATGateway."
  }
}

# =============================================================================
# modules/aks/main.tf -- the AKS cluster, its control-plane identity, and the
# user node pool
# =============================================================================
#
# WHAT THIS MODULE OWNS
# ----------------------
#   - a user-assigned managed identity for the cluster CONTROL PLANE
#     (distinct from the kubelet identity AKS creates for itself);
#   - the azurerm_kubernetes_cluster resource itself, with its system
#     (default) node pool;
#   - a separate azurerm_kubernetes_cluster_node_pool for the user workload
#     pool, because azurerm models "more than one node pool" as one resource
#     per pool rather than a block inside the cluster resource;
#   - the AcrPull role assignment(s) that let the kubelet pull images with no
#     imagePullSecret.
#
# This module does NOT create a resource group, a VNet, subnets, a NAT
# Gateway, or a Log Analytics workspace. Those come from modules/network and
# modules/observability and are consumed here as plain IDs -- see
# docs/architecture.md, Design principle 4 ("modules own resources, the
# environment root owns composition").
# =============================================================================

locals {
  tags = merge(
    var.tags,
    {
      module = "aks"
    }
  )

  # --- Maintenance window translation --------------------------------------
  # The module's public interface takes a single weekday plus a list of UTC
  # hours (e.g. day="Sunday", hours=[2,3]) because that is the shape an
  # environment's tfvars actually wants to express ("patch Sunday nights").
  # The underlying azurerm v4 schema for both maintenance_window_auto_upgrade
  # and maintenance_window_node_os wants a contiguous start_time + duration
  # instead, so we derive one here rather than exposing that plumbing as five
  # separate variables.
  maintenance_start_hour = min(var.maintenance_window_hours...)
  maintenance_start_time = format("%02d:00", local.maintenance_start_hour)
  # Duration is expressed in hours by the provider; the length of the
  # supplied hour list is exactly that, provided the hours are contiguous
  # (enforced by convention, not by a validation block, since expressing
  # "list must be contiguous" cleanly in a `validation` condition is more
  # obscure than the bug it prevents).
  maintenance_duration_hours = length(var.maintenance_window_hours)
}

# -----------------------------------------------------------------------------
# Control-plane identity
# -----------------------------------------------------------------------------
# AKS creates its OWN identity for the kubelet (node-level operations such as
# pulling images and attaching disks) automatically. It does NOT need one for
# the control plane unless we hand it one -- but a user-assigned identity here
# (rather than SystemAssigned) is what makes the control-plane identity's
# lifecycle independent of the cluster's: it can be pre-created, inspected,
# and granted roles (e.g. Network Contributor on the VNet, not wired up in
# this module) before the cluster exists, and it survives a cluster rebuild.
# -----------------------------------------------------------------------------

resource "azurerm_user_assigned_identity" "control_plane" {
  name                = "id-${var.name}-controlplane"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = local.tags
}

# -----------------------------------------------------------------------------
# The cluster
# -----------------------------------------------------------------------------

resource "azurerm_kubernetes_cluster" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  dns_prefix          = replace(var.name, "/[^a-zA-Z0-9-]/", "")

  kubernetes_version = var.kubernetes_version
  sku_tier           = var.sku_tier

  # --- Identity ------------------------------------------------------------
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.control_plane.id]
  }

  # --- Default (system) node pool -------------------------------------------
  default_node_pool {
    name                 = "system"
    vm_size              = var.system_node_vm_size
    node_count           = var.system_node_count
    vnet_subnet_id       = var.system_node_subnet_id
    zones                = var.zones
    os_sku               = "AzureLinux"
    max_pods             = 110

    # `only_critical_addons_enabled = true` applies the taint
    # CriticalAddonsOnly=true:NoSchedule to every node in this pool
    # DECLARATIVELY. This is the Terraform-native way to carve out a pool
    # that only CoreDNS/konnectivity/metrics-server/CSI-driver pods (which
    # all tolerate that taint) will land on -- see docs/architecture.md,
    # "Why a system/user node-pool split". There is deliberately no
    # corresponding `node_taints` argument here: azurerm rejects setting
    # custom taints on the default node pool alongside this flag.
    only_critical_addons_enabled = true

    # azurerm v4 REQUIRES this when the default node pool might ever be
    # resized or have its VM size changed in place, which both legitimately
    # happen over this cluster's lifetime. Without it, a change to
    # system_node_vm_size fails outright instead of performing the
    # create-new/delete-old node pool rotation AKS supports. The temporary
    # pool is created, workloads drain onto it, and the original pool is
    # replaced -- all orchestrated by the provider, never left behind.
    temporary_name_for_rotation = "systemtmp"

    upgrade_settings {
      max_surge = "33%"
    }
  }

  # --- Workload Identity / OIDC federation ----------------------------------
  # oidc_issuer_enabled publishes the cluster's public JWKS at a stable URL;
  # workload_identity_enabled installs the mutating admission webhook that
  # projects a service-account token into labelled pods. Together these are
  # what let modules/identity's federated credentials work with zero secrets
  # -- see docs/architecture.md, "3. Workload Identity token exchange".
  oidc_issuer_enabled      = true
  workload_identity_enabled = true

  # --- Azure RBAC for Kubernetes authorisation ------------------------------
  # local_account_disabled = true means `az aks get-credentials --admin` and
  # the cluster's static kubeconfig certificate stop working entirely: every
  # kubectl session authenticates as a real Entra identity via kubelogin, and
  # every authorization decision is an auditable Azure RBAC role assignment
  # rather than a Kubernetes RoleBinding nobody can enumerate centrally.
  azure_active_directory_role_based_access_control {
    tenant_id              = null # defaults to the provider's tenant; set explicitly only for a cross-tenant cluster.
    azure_rbac_enabled     = true
    admin_group_object_ids = var.admin_group_object_ids
  }

  local_account_disabled = true

  # --- Secrets Store CSI driver addon ---------------------------------------
  # secret_rotation_enabled makes the driver re-poll Key Vault on an interval
  # and update the mounted file in place, so a secret rotated in Key Vault
  # reaches the pod's filesystem without a pod restart.
  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "2m"
  }

  # --- Azure Policy addon ----------------------------------------------------
  # Installs Gatekeeper plus Azure's policy-to-constraint translation,
  # enforcing the built-in "Kubernetes cluster pod security baseline" and any
  # custom initiative assigned at the subscription/resource-group scope. This
  # is the admission-control baseline referenced in docs/architecture.md's
  # "Known gaps" table (a second admission controller like Kyverno/Gatekeeper
  # OSS is deliberately not layered on top).
  azure_policy_enabled = true

  # --- Networking ------------------------------------------------------------
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay" # keeps pod IPs out of the VNet -- see docs/architecture.md, ADR-0003.
    network_policy      = var.network_policy
    pod_cidr            = "10.244.0.0/16"
    service_cidr        = "172.16.0.0/16"
    dns_service_ip      = "172.16.0.10"
    load_balancer_sku   = "standard"

    # See the `outbound_type` variable description: for
    # "userAssignedNATGateway" to actually take effect, the node subnets must
    # already carry a NAT Gateway association -- done in modules/network, not
    # here. AKS does not need (and this module does not accept) the NAT
    # Gateway's resource ID.
    outbound_type = var.outbound_type
  }

  private_cluster_enabled = var.private_cluster_enabled

  # Only emitted when the cluster is public AND an allow-list was actually
  # supplied -- an empty `authorized_ip_ranges` block with no entries is
  # different from omitting the block entirely (the former can behave like
  # "deny all", which is never the intent of an unset variable).
  dynamic "api_server_access_profile" {
    for_each = (!var.private_cluster_enabled && length(var.authorized_ip_ranges) > 0) ? [1] : []

    content {
      authorized_ip_ranges = var.authorized_ip_ranges
    }
  }

  # --- Container Insights -----------------------------------------------------
  oms_agent {
    log_analytics_workspace_id = var.log_analytics_workspace_id
  }

  # --- Upgrade channels and maintenance windows -------------------------------
  automatic_upgrade_channel = var.automatic_upgrade_channel
  node_os_upgrade_channel   = var.node_os_upgrade_channel

  # Bounds WHEN an automatic control-plane upgrade (driven by
  # automatic_upgrade_channel) is allowed to start.
  maintenance_window_auto_upgrade {
    frequency   = "Weekly"
    interval    = 1
    duration    = local.maintenance_duration_hours
    day_of_week = var.maintenance_window_day
    start_time  = local.maintenance_start_time
    utc_offset  = "+00:00"
  }

  # Bounds WHEN an automatic node OS image upgrade (driven by
  # node_os_upgrade_channel) is allowed to start. Kept on the same
  # day/window as the control-plane upgrade above so there is exactly one
  # "maintenance night" to reason about, rather than two independent ones
  # that can land on different days and double the blast-radius surface.
  maintenance_window_node_os {
    frequency   = "Weekly"
    interval    = 1
    duration    = local.maintenance_duration_hours
    day_of_week = var.maintenance_window_day
    start_time  = local.maintenance_start_time
    utc_offset  = "+00:00"
  }

  tags = local.tags

  lifecycle {
    # kubernetes_version is intentionally allowed to drift: when it is null,
    # Azure may provision a newer default than what is recorded in state on
    # a subsequent apply, and automatic_upgrade_channel moves it further
    # still. Fighting that with Terraform would mean every `plan` in a
    # channel-managed cluster shows a spurious downgrade.
    ignore_changes = [kubernetes_version]
  }
}

# -----------------------------------------------------------------------------
# User node pool
# -----------------------------------------------------------------------------
# A second, independent resource -- NOT a block inside azurerm_kubernetes_
# cluster -- because azurerm models every node pool beyond the mandatory
# default one as its own azurerm_kubernetes_cluster_node_pool. This is also
# why AT MINIMUM this pool must autoscale: it is the pool application
# workloads actually land on, and its load is driven by request volume, not
# by cluster size the way the system pool's is.
# -----------------------------------------------------------------------------

resource "azurerm_kubernetes_cluster_node_pool" "user" {
  name                  = "user"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id

  vm_size        = var.user_node_vm_size
  vnet_subnet_id = var.user_node_subnet_id
  zones          = var.zones
  mode           = "User"
  os_type        = "Linux"
  os_sku         = "AzureLinux"
  max_pods       = 110

  # azurerm v4 RENAMED this from `enable_auto_scaling` to
  # `auto_scaling_enabled`. Using the v3 name against a v4 provider raises an
  # "Unsupported argument" error at plan time.
  auto_scaling_enabled = true
  min_count            = var.user_node_min_count
  max_count            = var.user_node_max_count

  # `node_count` must be omitted entirely (not just left at a default) when
  # auto_scaling_enabled is true -- supplying both is a provider-level
  # conflict, since the autoscaler, not Terraform, owns the live count after
  # the first apply.

  # azurerm v4 RENAMED `enable_node_public_ip` to `node_public_ip_enabled`.
  # Explicit here (even though false is the default) because "no node in this
  # platform ever has a public IP" is a security invariant worth stating,
  # not leaving to a default that could change.
  node_public_ip_enabled = false

  upgrade_settings {
    max_surge = "33%"
  }

  tags = local.tags
}

# -----------------------------------------------------------------------------
# AcrPull role assignment(s) for the kubelet identity
# -----------------------------------------------------------------------------
# THIS is what makes imagePullSecrets unnecessary -- see docs/architecture.md,
# "The one non-obvious edge: ACR to AKS", and kubernetes/README.md.
#
# The subtlety that bites people: this role assignment must target the
# cluster's KUBELET identity (`kubelet_identity[0].object_id`), which is what
# actually performs `docker pull` under the hood -- NOT the control-plane
# identity created above (`azurerm_user_assigned_identity.control_plane`),
# which only manages the cluster's own Azure resources (load balancers, disks,
# route tables). Assigning AcrPull to the wrong principal produces
# ImagePullBackOff with an opaque 401 and no indication of which identity is
# at fault.
# -----------------------------------------------------------------------------

resource "azurerm_role_assignment" "kubelet_acr_pull" {
  for_each = toset(var.attached_acr_ids)

  scope                = each.value
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
  principal_type       = "ServicePrincipal"

  description = "Lets the AKS kubelet identity pull images from this registry with no imagePullSecret. See docs/architecture.md section 'The one non-obvious edge: ACR to AKS'."

  # Belt and braces for the same Entra replication delay documented in
  # bootstrap/github-oidc.tf -- the kubelet identity is itself newly created
  # by the cluster resource above, within the same apply.
  skip_service_principal_aad_check = true
}

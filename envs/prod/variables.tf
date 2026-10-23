# =============================================================================
# envs/prod/variables.tf
# =============================================================================
# This file declares every knob prod's main.tf needs to compose
# modules/{naming,network,observability,acr,aks,identity,keyvault}. Per
# docs/architecture.md design principle 3 ("Modules are composable, not
# configurable-to-death"), a variable exists here only if dev, staging and
# prod actually differ on it, or if it is a genuine per-operator secret-ish
# value (subscription_id, tenant_id) that must never be hardcoded.
#
# Identical schema to envs/dev and envs/staging's variables.tf by design
# (docs/architecture.md design principle 5: "Prod differs from dev by
# configuration, not by code path") -- only the descriptions below and the
# values in terraform.tfvars differ.
# =============================================================================

# -----------------------------------------------------------------------------
# Azure context
# -----------------------------------------------------------------------------

variable "subscription_id" {
  description = <<-EOT
    Target Azure subscription ID (GUID). Required by azurerm ~> 4.0 -- the
    provider no longer infers it from the Azure CLI context. Find yours with:
      az account show --query id -o tsv
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "subscription_id must be a GUID, e.g. 00000000-0000-0000-0000-000000000000."
  }
}

variable "tenant_id" {
  description = <<-EOT
    Microsoft Entra ID tenant ID (GUID). Only consumed indirectly today (no
    resource in this root module reads it directly), but declared here so it
    is set once, validated, and available the moment a future resource
    (an `azuread_*` data source, a Key Vault access policy fallback, etc.)
    needs it. Find yours with:
      az account show --query tenantId -o tsv

    DEFAULT IS A PLACEHOLDER. 00000000-0000-0000-0000-000000000000 is not a
    real tenant and will fail against the real Azure API -- it exists only so
    `terraform plan` does not immediately demand a value before you have
    decided on one. Override it in terraform.tfvars.
  EOT
  type        = string
  default     = "00000000-0000-0000-0000-000000000000"

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$", var.tenant_id))
    error_message = "tenant_id must be a GUID, e.g. 00000000-0000-0000-0000-000000000000."
  }
}

variable "location" {
  description = "Azure region for every resource in this environment. Must be a region modules/naming has a short-code mapping for."
  type        = string
  default     = "westeurope"

  validation {
    condition = contains([
      "westeurope", "northeurope", "francecentral", "germanywestcentral",
      "uksouth", "ukwest", "swedencentral", "switzerlandnorth",
      "eastus", "eastus2", "westus2", "westus3", "centralus",
    ], var.location)
    error_message = "location must be one of the regions modules/naming has a short-code mapping for."
  }
}

# -----------------------------------------------------------------------------
# Naming / tagging
# -----------------------------------------------------------------------------

variable "prefix" {
  description = "Short workload prefix used in every resource name by modules/naming, e.g. \"aksplat\". Must match dev/staging's prefix if you want the three environments to read as one platform."
  type        = string
  default     = "aksplat"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,23}$", var.prefix))
    error_message = "prefix must be 2-24 characters, lowercase alphanumeric, starting with a letter."
  }
}

variable "owner" {
  description = "Owner tag value -- the human or team accountable for this environment's resources. In prod this should name a team, not an individual."
  type        = string
}

variable "cost_center" {
  description = "Cost centre tag used for showback/chargeback reporting."
  type        = string
}

variable "additional_tags" {
  description = "Extra tags merged over the common tag set computed by modules/naming."
  type        = map(string)
  default     = {}
}

# -----------------------------------------------------------------------------
# Networking
# -----------------------------------------------------------------------------

variable "vnet_address_space" {
  description = "CIDR block for prod's VNet. Per the IP address plan in docs/architecture.md, prod owns 10.30.0.0/16."
  type        = string

  validation {
    condition     = can(cidrhost(var.vnet_address_space, 0))
    error_message = "vnet_address_space must be a valid CIDR block, e.g. \"10.30.0.0/16\"."
  }
}

variable "subnet_cidrs" {
  description = <<-EOT
    CIDR blocks for the four fixed subnets (aks_system, aks_user,
    private_endpoints, appgw), per the IP address plan in
    docs/architecture.md. Subnet offsets are identical across environments --
    only the VNet's second octet changes.
  EOT
  type = object({
    aks_system        = string
    aks_user          = string
    private_endpoints = string
    appgw             = string
  })

  validation {
    condition = alltrue([
      can(cidrhost(var.subnet_cidrs.aks_system, 0)),
      can(cidrhost(var.subnet_cidrs.aks_user, 0)),
      can(cidrhost(var.subnet_cidrs.private_endpoints, 0)),
      can(cidrhost(var.subnet_cidrs.appgw, 0)),
    ])
    error_message = "Every entry in subnet_cidrs must be a valid CIDR block."
  }
}

variable "enable_private_endpoints" {
  description = <<-EOT
    Provision private endpoints (and the matching private DNS zones) for ACR
    and Key Vault. Per docs/architecture.md's "Environment topology
    differences" table, prod is the ONLY environment that turns this on --
    dev and staging keep ACR/Key Vault on their public, RBAC-protected data
    planes. Kept as a variable (rather than hardcoded true) so this root
    module is byte-for-byte reusable across environments -- only
    terraform.tfvars differs.
  EOT
  type        = bool
}

variable "authorized_ip_ranges" {
  description = <<-EOT
    CIDR ranges allowed to reach the public AKS API server. Irrelevant in
    prod when private_cluster_enabled = true (the default here): the module
    does not even emit this argument in that case. Declared anyway so the
    variable set stays identical across all three environments per design
    principle 5, and so flipping private_cluster_enabled off in an emergency
    does not also require inventing this variable on the spot.
  EOT
  type        = list(string)
  default     = []
}

# -----------------------------------------------------------------------------
# Observability
# -----------------------------------------------------------------------------

variable "log_retention_days" {
  description = "Log Analytics workspace retention in days. 30 in dev/staging, 90 in prod per docs/architecture.md."
  type        = number

  validation {
    condition     = var.log_retention_days >= 30 && var.log_retention_days <= 730
    error_message = "log_retention_days must be between 30 and 730."
  }
}

variable "action_group_email_receivers" {
  description = "Email addresses that receive alert notifications from the baseline action group. Prod MUST have at least one real, monitored address -- an alert nobody reads is not a control."
  type        = list(string)
  default     = []
}

variable "enable_managed_prometheus" {
  description = "Create an azurerm_monitor_workspace (Azure Monitor managed Prometheus). Off everywhere by default -- see modules/observability's known-gaps note on ingestion cost."
  type        = bool
  default     = false
}

variable "enable_managed_grafana" {
  description = "Create an azurerm_dashboard_grafana (Azure Managed Grafana). Off everywhere by default, for the same cost reasons as enable_managed_prometheus."
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# Azure Container Registry
# -----------------------------------------------------------------------------

variable "acr_sku" {
  description = "ACR SKU. Basic in dev, Standard in staging, Premium in prod -- see docs/architecture.md's environment topology table. Premium is REQUIRED in prod: it is the only tier supporting private endpoints and the untagged-manifest retention policy."
  type        = string
  default     = "Premium"

  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.acr_sku)
    error_message = "acr_sku must be one of: Basic, Standard, Premium."
  }
}

variable "acr_retention_policy_days" {
  description = "Days an untagged ACR manifest is retained before purge. Premium-only, and prod is Premium, so this actually takes effect here (unlike dev/staging)."
  type        = number
  default     = 7

  validation {
    condition     = var.acr_retention_policy_days >= 0 && var.acr_retention_policy_days <= 365
    error_message = "acr_retention_policy_days must be between 0 and 365."
  }
}

# -----------------------------------------------------------------------------
# AKS
# -----------------------------------------------------------------------------

variable "kubernetes_version" {
  description = "Kubernetes version to pin the cluster to. Prod should always pin an explicit version (e.g. \"1.29.7\") for deterministic, change-controlled upgrades -- never leave this null in prod."
  type        = string
  default     = null
}

variable "sku_tier" {
  description = "AKS control-plane pricing tier: Free (dev), Standard (staging/prod), or Premium."
  type        = string

  validation {
    condition     = contains(["Free", "Standard", "Premium"], var.sku_tier)
    error_message = "sku_tier must be one of: Free, Standard, Premium."
  }
}

variable "private_cluster_enabled" {
  description = "Whether the AKS API server is reachable only via a private endpoint. false in dev/staging; true in prod -- the only environment where this platform runs a private API server."
  type        = bool
}

variable "system_node_vm_size" {
  description = "VM SKU for the system (default) node pool."
  type        = string
}

variable "system_node_count" {
  description = "Fixed node count for the system node pool (it does not autoscale -- see modules/aks's variable description)."
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
  description = "Minimum node count the cluster autoscaler scales the user pool down to."
  type        = number

  validation {
    condition     = var.user_node_min_count >= 1
    error_message = "user_node_min_count must be at least 1."
  }
}

variable "user_node_max_count" {
  description = "Maximum node count the cluster autoscaler scales the user pool up to."
  type        = number

  validation {
    condition     = var.user_node_max_count >= 1
    error_message = "user_node_max_count must be at least 1."
  }
}

variable "zones" {
  description = "Availability zones both node pools are spread across. Empty in dev; [\"1\",\"2\"] in staging; [\"1\",\"2\",\"3\"] in prod -- prod is the only environment spread across all three."
  type        = list(string)
  default     = ["1", "2", "3"]
}

variable "network_policy" {
  description = "Kubernetes network policy engine: \"azure\" (dev) or \"cilium\" (staging/prod) -- see docs/architecture.md, 'Network policy: Cilium in staging/prod, azure in dev'."
  type        = string

  validation {
    condition     = contains(["azure", "cilium"], var.network_policy)
    error_message = "network_policy must be one of: azure, cilium."
  }
}

variable "admin_group_object_ids" {
  description = "Entra ID group object IDs granted the AKS RBAC Cluster Admin role. Prod MUST name a real Entra group here -- individual operator access to a production cluster should always flow through group membership, not a personal grant."
  type        = list(string)
  default     = []
}

variable "automatic_upgrade_channel" {
  description = "Control-plane auto-upgrade channel."
  type        = string
  default     = "patch"

  validation {
    condition     = contains(["patch", "stable", "rapid", "node-image", "none"], var.automatic_upgrade_channel)
    error_message = "automatic_upgrade_channel must be one of: patch, stable, rapid, node-image, none."
  }
}

variable "node_os_upgrade_channel" {
  description = "Node OS image upgrade channel, independent of the Kubernetes version channel."
  type        = string
  default     = "NodeImage"

  validation {
    condition     = contains(["Unmanaged", "SecurityPatch", "NodeImage", "None"], var.node_os_upgrade_channel)
    error_message = "node_os_upgrade_channel must be one of: Unmanaged, SecurityPatch, NodeImage, None."
  }
}

variable "maintenance_window_day" {
  description = "Day of week the auto-upgrade and node-OS maintenance windows are allowed to run on. Pick the lowest-traffic day for this workload."
  type        = string
  default     = "Sunday"

  validation {
    condition     = contains(["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"], var.maintenance_window_day)
    error_message = "maintenance_window_day must be a full English weekday name, e.g. \"Sunday\"."
  }
}

variable "maintenance_window_hours" {
  description = "Hours of the day (0-23, UTC) maintenance is allowed to run in. Pick the lowest-traffic hours for this workload."
  type        = list(number)
  default     = [2, 3]

  validation {
    condition     = alltrue([for h in var.maintenance_window_hours : h >= 0 && h <= 23])
    error_message = "maintenance_window_hours must each be between 0 and 23."
  }
}

# -----------------------------------------------------------------------------
# Workload Identity
# -----------------------------------------------------------------------------

variable "workloads" {
  description = <<-EOT
    Workloads to provision a managed identity and Workload Identity federated
    credential for, keyed by a stable workload key. Each entry binds exactly
    one Kubernetes ServiceAccount (namespace + name) to its own Azure
    identity -- see docs/architecture.md, "3. Workload Identity token
    exchange", and kubernetes/serviceaccount.yaml. Workload identity subjects
    are derived from the Kubernetes namespace/ServiceAccount, not from
    GitHub -- there is nothing GitHub-specific to parametrize here.
  EOT
  type = map(object({
    namespace            = string
    service_account_name = string
  }))
  default = {
    "demo-app" = {
      namespace            = "apps"
      service_account_name = "demo-app"
    }
  }

  validation {
    condition = alltrue([
      for k, w in var.workloads : length(w.namespace) > 0 && length(w.service_account_name) > 0
    ])
    error_message = "Every workload entry must specify a non-empty namespace and service_account_name."
  }
}

# -----------------------------------------------------------------------------
# Key Vault
# -----------------------------------------------------------------------------

variable "key_vault_sku_name" {
  description = "Key Vault pricing tier. \"standard\" everywhere except prod, which uses \"premium\"."
  type        = string
  default     = "premium"

  validation {
    condition     = contains(["standard", "premium"], var.key_vault_sku_name)
    error_message = "key_vault_sku_name must be one of: standard, premium."
  }
}

variable "key_vault_purge_protection_enabled" {
  description = <<-EOT
    Once true, cannot be reverted to false for the life of the vault (Azure's
    own one-way-door design). MUST be true in prod: it is the only thing
    standing between a mis-targeted `terraform destroy` and PERMANENT loss of
    prod's key material. See docs/architecture.md, "Why prod's purge
    protection is on and irreversible".
  EOT
  type        = bool
}

variable "key_vault_soft_delete_retention_days" {
  description = "Days a soft-deleted vault/secret/key/certificate is recoverable for. Azure enforces soft delete unconditionally; this only controls the retention window. Prod uses the maximum allowed."
  type        = number
  default     = 90

  validation {
    condition     = var.key_vault_soft_delete_retention_days >= 7 && var.key_vault_soft_delete_retention_days <= 90
    error_message = "key_vault_soft_delete_retention_days must be between 7 and 90."
  }
}

variable "key_vault_network_acls_default_action" {
  description = "Default action for the vault's network ACLs. Prod sets public_network_access_enabled = false via enable_private_endpoints, so this mostly governs the rare break-glass IP allow-list rather than general access."
  type        = string
  default     = "Deny"

  validation {
    condition     = contains(["Allow", "Deny"], var.key_vault_network_acls_default_action)
    error_message = "key_vault_network_acls_default_action must be one of: Allow, Deny."
  }
}

variable "key_vault_allowed_ip_rules" {
  description = "CIDR ranges or individual IPs allowed through the vault's network ACLs when key_vault_network_acls_default_action is \"Deny\". Only relevant if public_network_access_enabled ends up true; with enable_private_endpoints = true in prod, the private endpoint is the real path in."
  type        = list(string)
  default     = []
}

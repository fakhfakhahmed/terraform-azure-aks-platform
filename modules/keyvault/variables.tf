# =============================================================================
# modules/keyvault/variables.tf
# =============================================================================

variable "name" {
  description = <<-EOT
    The vault's resource name, precomputed by modules/naming (e.g.
    "kv-aksplat-prod-weu"). Key Vault names are globally unique across every
    Azure tenant and, once purge protection is enabled, stay RESERVED for the
    soft-delete retention period even after deletion -- see the
    purge_protection_enabled description below.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9-]{1,22}[a-zA-Z0-9]$", var.name))
    error_message = "Key Vault names must be 3-24 characters, start with a letter, end alphanumeric, and contain only letters, numbers and hyphens."
  }
}

variable "resource_group_name" {
  description = "Resource group the vault is deployed into."
  type        = string
}

variable "location" {
  description = "Azure region for the vault."
  type        = string
}

variable "tags" {
  description = "Tags merged onto the vault and its private endpoint."
  type        = map(string)
  default     = {}
}

variable "sku_name" {
  description = "Key Vault pricing tier. \"premium\" adds HSM-backed keys; this platform has no current use for them, so every environment defaults to \"standard\"."
  type        = string
  default     = "standard"

  validation {
    condition     = contains(["standard", "premium"], var.sku_name)
    error_message = "sku_name must be one of: standard, premium."
  }
}

variable "purge_protection_enabled" {
  description = <<-EOT
    Once true, CANNOT be reverted to false for the life of the vault --
    purge protection is a one-way door by Azure's own design. A deleted vault
    stays in a recoverable, soft-deleted state for `soft_delete_retention_days`
    and its name stays reserved throughout. On in staging/prod (it is the only
    thing standing between a mis-targeted `terraform destroy` and permanent
    loss of key material); off in dev, where vaults are created and destroyed
    routinely and a reserved name during iteration is pure friction. See
    docs/architecture.md, "Why prod's purge protection is on and irreversible".
  EOT
  type        = bool
  default     = false
}

variable "soft_delete_retention_days" {
  description = "Days a soft-deleted vault/secret/key/certificate is recoverable for before permanent purge. Azure enforces soft delete unconditionally (it cannot be disabled on a v4 vault); this only controls the retention window."
  type        = number
  default     = 90

  validation {
    condition     = var.soft_delete_retention_days >= 7 && var.soft_delete_retention_days <= 90
    error_message = "soft_delete_retention_days must be between 7 and 90."
  }
}

variable "public_network_access_enabled" {
  description = "Whether the vault's data plane is reachable over the public internet at all (subject to network_acls_default_action below). Set false in prod, where a private endpoint is the only path in."
  type        = bool
  default     = true
}

variable "network_acls_default_action" {
  description = "Default action for the vault's network ACLs when a request does not match allowed_ip_rules or a trusted Azure service. \"Deny\" requires either allowed_ip_rules or a private endpoint to be reachable at all."
  type        = string
  default     = "Allow"

  validation {
    condition     = contains(["Allow", "Deny"], var.network_acls_default_action)
    error_message = "network_acls_default_action must be one of: Allow, Deny."
  }
}

variable "allowed_ip_rules" {
  description = "CIDR ranges or individual IPs allowed through the vault's network ACLs when network_acls_default_action is \"Deny\"."
  type        = list(string)
  default     = []
}

variable "private_endpoint_subnet_id" {
  description = "Subnet ID (from modules/network, snet-private-endpoints) to place the vault's private endpoint NIC in. Pass null to skip creating a private endpoint entirely -- dev and staging do not provision one per docs/architecture.md's environment topology table."
  type        = string
  default     = null
}

variable "private_dns_zone_ids" {
  description = "Private DNS zone IDs (privatelink.vaultcore.azure.net) to register the private endpoint's A record in. Ignored when private_endpoint_subnet_id is null."
  type        = list(string)
  default     = []
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics workspace ID (from modules/observability) that AuditEvent logs and AllMetrics are sent to."
  type        = string
}

variable "workload_principal_ids" {
  description = <<-EOT
    Map of workload key -> principal (object) ID to grant the "Key Vault
    Secrets User" role on this vault, scoped to the whole vault. Typically
    fed directly from modules/identity's `principal_ids` output. Default {}
    means no workload has data-plane access until explicitly granted here --
    the vault starts locked down.
  EOT
  type        = map(string)
  default     = {}
}

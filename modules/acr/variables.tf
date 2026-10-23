# =============================================================================
# modules/acr/variables.tf
# =============================================================================

variable "name" {
  description = <<-EOT
    Globally-unique ACR name, precomputed by modules/naming (names["acr"]),
    e.g. "acraksplatprodweu". Alphanumeric only, 5-50 characters -- Azure
    validates global uniqueness at apply time; this module can only validate
    shape.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9]{5,50}$", var.name))
    error_message = "name must be 5-50 characters, alphanumeric only (no hyphens, underscores or dots)."
  }
}

variable "resource_group_name" {
  description = "Resource group the registry is created in."
  type        = string
}

variable "location" {
  description = "Azure region for the registry."
  type        = string
}

variable "tags" {
  description = "Tags applied to the registry, typically module.naming.tags from the caller."
  type        = map(string)
  default     = {}
}

variable "sku" {
  description = <<-EOT
    Registry SKU.
      Basic    - dev. No geo-replication, no private endpoints, no retention
                 policy, no content trust.
      Standard - staging. Larger storage/throughput than Basic, still no
                 geo-replication or private endpoints.
      Premium  - prod. Required for geo-replication, private endpoints,
                 the untagged-manifest retention policy, and (if ever
                 enabled) content trust.
    See "Environment topology differences" in docs/architecture.md.
  EOT
  type        = string
  default     = "Premium"

  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.sku)
    error_message = "sku must be one of: Basic, Standard, Premium."
  }
}

variable "public_network_access_enabled" {
  description = <<-EOT
    Whether the registry's data-plane endpoint (login, push, pull) is
    reachable from the public internet. Set to false in prod once the private
    endpoint is in place (dev/staging have no private endpoint, so this must
    stay true there or every `docker pull` breaks).
  EOT
  type        = bool
  default     = true
}

variable "private_endpoint_subnet_id" {
  description = <<-EOT
    Subnet to create the registry's private endpoint NIC in (expected: the
    private-endpoints subnet from modules/network). A private endpoint is
    only created when this is non-null AND sku = "Premium" -- Basic/Standard
    do not support private endpoints at all, so passing a subnet ID at a
    lower SKU is silently ignored rather than erroring, which keeps the
    module usable with environment tfvars that only flip the SKU.
  EOT
  type        = string
  default     = null
}

variable "private_dns_zone_ids" {
  description = <<-EOT
    Private DNS zone IDs for the private endpoint's DNS zone group -- expected
    to be [private_dns_zone_ids["acr_registry"], private_dns_zone_ids["acr_data"]]
    from modules/network's output. Only used when a private endpoint is
    actually created (see private_endpoint_subnet_id).
  EOT
  type        = list(string)
  default     = []
}

variable "geo_replication_locations" {
  description = <<-EOT
    Additional regions to geo-replicate the registry to. Only valid on
    Premium -- ignored (and should be left empty) at Basic/Standard. Empty by
    default: this platform is single-region (see "No DR / multi-region" in
    docs/architecture.md's known-gaps table), so this is wired for a future
    DR rollout rather than used today.
  EOT
  type = list(object({
    location                = string
    zone_redundancy_enabled = bool
  }))
  default = []

  validation {
    condition     = var.sku == "Premium" || length(var.geo_replication_locations) == 0
    error_message = "geo_replication_locations requires sku = \"Premium\"."
  }
}

variable "retention_policy_days" {
  description = <<-EOT
    Days an untagged manifest is retained before ACR's background task purges
    it. Premium only. Keeps registry storage (and its cost) from growing
    unbounded from CI's untagged intermediate build layers.
  EOT
  type        = number
  default     = 7

  validation {
    condition     = var.retention_policy_days >= 0 && var.retention_policy_days <= 365
    error_message = "retention_policy_days must be between 0 and 365."
  }
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics workspace ID that registry diagnostic settings (repository events, login events, all metrics) are routed to."
  type        = string
}

variable "admin_enabled" {
  description = <<-EOT
    Whether the registry's admin account (a single shared username/password
    with full push/pull rights) is enabled.

    This MUST stay false. It exists as a variable only so the intent is
    explicit in `terraform plan` output and so a reviewer sees this
    description rather than a silently hardcoded value; the registry
    resource below does NOT read this variable -- `admin_enabled` is
    hardcoded to `false` on the resource itself, and this variable's
    validation forbids any other value. Workloads authenticate via managed
    identity + the `AcrPull` role assignment (see modules/aks and
    "3. Workload Identity token exchange" in docs/architecture.md); there is
    never a legitimate reason to re-enable the shared admin credential on
    this platform.
  EOT
  type        = bool
  default     = false

  validation {
    condition     = var.admin_enabled == false
    error_message = "admin_enabled must be false. The registry authenticates workloads via managed identity + AcrPull, never the shared admin account -- see this variable's description."
  }
}

variable "trust_policy_enabled" {
  description = <<-EOT
    Enable Docker Content Trust (image signing enforcement) on the registry.

    Defaults to false. This is a known, documented gap -- see "No image
    signing / content trust" in docs/architecture.md's known-gaps table.
    Content trust without a signing key custodian and an admission-time
    verification policy (Notation/cosign + Ratify + Gatekeeper) provides
    close to zero real security benefit: it blocks unsigned pulls but nothing
    here currently signs images in CI, so turning this on today would simply
    break every deployment. Flip it on only after the signing pipeline exists.
  EOT
  type        = bool
  default     = false
}

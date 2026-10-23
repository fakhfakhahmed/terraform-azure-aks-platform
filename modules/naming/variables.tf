# =============================================================================
# modules/naming/variables.tf
# =============================================================================

variable "prefix" {
  description = <<-EOT
    Short organisation/workload prefix used in every resource name, e.g.
    "aksplat". Kept short deliberately: it is embedded in the ACR name, which
    azurerm limits to 50 characters and Azure requires to be globally unique
    and alphanumeric-only, and in the storage-account-style names that cap at
    24 characters once environment and region tokens are added.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,23}$", var.prefix))
    error_message = "prefix must be 2-24 characters, lowercase alphanumeric, starting with a letter (kept conservative so it composes safely into the ACR name limit)."
  }
}

variable "environment" {
  description = "Deployment environment. Drives the second-octet IP plan (see docs/architecture.md) and every resource name's env token."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "location" {
  description = "Full Azure region name (e.g. \"westeurope\"), not the short code. This module derives region_short from it using the same table as bootstrap/main.tf."
  type        = string

  validation {
    condition = contains([
      "westeurope", "northeurope", "francecentral", "germanywestcentral",
      "uksouth", "ukwest", "swedencentral", "switzerlandnorth",
      "eastus", "eastus2", "westus2", "westus3", "centralus",
    ], var.location)
    error_message = "location must be one of the regions this platform has a short-code mapping for. Add the region to the region_short_map local in main.tf before extending this list."
  }
}

variable "owner" {
  description = "Owner tag value -- the human or team accountable for resources carrying names produced by this module."
  type        = string
}

variable "cost_center" {
  description = "Cost centre tag used for showback/chargeback reporting."
  type        = string
}

variable "additional_tags" {
  description = "Extra tags merged over the common tag set computed by this module. Useful for a ticket reference or a temporary owner override."
  type        = map(string)
  default     = {}
}

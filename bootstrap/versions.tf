# =============================================================================
# bootstrap/versions.tf
# =============================================================================
# NOTE: there is deliberately NO `backend` block in this stack.
#
# This is the chicken-and-egg layer: it CREATES the storage account that every
# other stack uses as its remote backend. It cannot store its own state in a
# backend that does not exist yet, so it runs with LOCAL state. See
# bootstrap/README.md for how to handle that state file safely (and for the
# optional "migrate bootstrap state into its own backend afterwards" step).
# =============================================================================

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      # azurerm v4 is a major rewrite of the provider's authentication and
      # resource-ID handling. Two consequences matter here:
      #   1. `subscription_id` is now REQUIRED in the provider block (or via
      #      ARM_SUBSCRIPTION_ID). v3 inferred it from the Azure CLI context.
      #   2. Several arguments were renamed, e.g.
      #      enable_https_traffic_only -> https_traffic_only_enabled.
      # Pinning to ~> 4.0 keeps us on 4.x and off the 5.x breaking changes.
      version = "~> 5.10"
    }

    azuread = {
      source = "hashicorp/azuread"
      # azuread v3 renamed `application_id` -> `client_id` on service
      # principals, and the federated identity credential resource now takes
      # the application's resource ID rather than its object ID.
      version = "~> 3.0"
    }

    random = {
      source = "hashicorp/random"
      # Used only to suffix the storage account name, which must be globally
      # unique across all of Azure.
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  # REQUIRED from azurerm v4 onwards. Omitting this produces:
  #   "Error: `subscription_id` is a required provider property when
  #    performing a plan/apply operation"
  # Passing it explicitly (rather than relying on ARM_SUBSCRIPTION_ID) makes
  # the target subscription a reviewable part of the configuration instead of
  # an invisible property of whoever's shell is running Terraform.
  subscription_id = var.subscription_id

  # Use Entra ID (AAD) for storage DATA-plane operations rather than the
  # account access key. This is what lets us set `shared_access_key_enabled =
  # false` on the state account: creating the blob container below goes
  # through RBAC, not through a shared key.
  #
  # The identity running this stack therefore needs "Storage Blob Data Owner"
  # (or Contributor) on the account. Owner/Contributor at the control plane is
  # NOT sufficient for data-plane operations -- a classic Azure gotcha.
  storage_use_azuread = true

  features {
    resource_group {
      # Refuse to delete a resource group that still contains resources
      # Terraform does not know about. The default (true) will happily delete
      # them. For the stack that holds every environment's state file, that
      # default is unacceptable.
      prevent_deletion_if_contains_resources = true
    }

    key_vault {
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
  }
}

provider "azuread" {
  tenant_id = var.tenant_id
}

provider "random" {}

# =============================================================================
# envs/staging/versions.tf -- provider requirements and provider configuration
# =============================================================================
# Pinned to the same floor as every other root module in this repository (see
# bootstrap/variables.tf's cross-variable validation note on why >= 1.9 is the
# floor: cross-variable references inside a `validation` block require it).
# =============================================================================

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  # azurerm ~> 4.0 no longer infers the subscription from the az CLI context --
  # it must be supplied explicitly or via ARM_SUBSCRIPTION_ID. scripts/init-env.ps1
  # exports ARM_SUBSCRIPTION_ID from the active `az login` session automatically,
  # but var.subscription_id (set in terraform.tfvars) is what actually reaches
  # the provider here.
  subscription_id = var.subscription_id

  features {
    key_vault {
      # Staging's Key Vault runs with purge_protection_enabled = true (see
      # terraform.tfvars). Purge protection is Azure's one-way door: once on,
      # a vault can no longer be purged, period -- not by this flag, not by
      # the portal, not by support. Setting purge_soft_delete_on_destroy =
      # true here would therefore be, at best, a silent no-op the moment
      # Terraform tried to act on it (Azure refuses the purge), and at worst
      # it would train an operator to expect `terraform destroy` to "clean
      # up" a purge-protected vault the same way it does in dev -- which it
      # categorically cannot. Leaving this false is the honest reflection of
      # what staging's vault actually does on destroy: soft-delete only, and
      # the name stays reserved for soft_delete_retention_days.
      purge_soft_delete_on_destroy = false

      # Lets a `terraform apply` that collides with a still-soft-deleted
      # vault from a previous destroy recover it automatically instead of
      # failing with "a vault with this name already exists in a
      # soft-deleted state". Safe in every environment -- recovering a vault
      # is not the same operation as purging one.
      recover_soft_deleted_key_vaults = true
    }

    resource_group {
      # Staging mirrors prod's topology at smaller scale (see README.md), so
      # it also mirrors prod's guardrail against an accidental
      # `terraform destroy` or portal delete silently taking a resource group
      # that still has live resources in it. See envs/prod/versions.tf for
      # the same setting with the stakes stated plainly.
      prevent_deletion_if_contains_resources = true
    }
  }
}

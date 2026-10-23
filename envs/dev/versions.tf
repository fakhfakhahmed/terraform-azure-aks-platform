# =============================================================================
# envs/dev/versions.tf -- provider requirements and provider configuration
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
      # Dev's Key Vault runs with purge_protection_enabled = false (see
      # terraform.tfvars and modules/keyvault/variables.tf), because dev vaults
      # are created and destroyed routinely and a reserved name during that
      # churn is pure friction, not safety. With purge protection off, a
      # `terraform destroy` only SOFT-deletes the vault -- it stays in a
      # recoverable, name-reserving state for soft_delete_retention_days. The
      # very next `terraform apply` in this same directory would then fail
      # trying to create a vault whose name is still reserved by its own
      # soft-deleted predecessor.
      #
      # purge_soft_delete_on_destroy = true makes `terraform destroy` actually
      # purge (permanently delete) a vault it just soft-deleted, so the name is
      # immediately free again for the next apply. This is safe ONLY because
      # dev never enables purge protection -- doing the same in staging/prod
      # would either be a silent no-op (Azure refuses to purge a
      # purge-protected vault) or, worse, give a false sense that destroy is
      # "clean" when the whole point of purge protection there is that it is
      # NOT.
      purge_soft_delete_on_destroy = true

      # Lets a `terraform apply` that collides with a still-soft-deleted vault
      # from a previous destroy recover it automatically instead of failing
      # with "a vault with this name already exists in a soft-deleted state".
      # Safe in every environment.
      recover_soft_deleted_key_vaults = true
    }

    resource_group {
      # Dev's resource group is torn down routinely (see the teardown reminder
      # in scripts/apply-env.ps1) and is expected to contain resources right
      # up until the moment it is destroyed. Requiring it to be empty first
      # would turn every `terraform destroy` into a two-step dance; dev
      # explicitly opts out of that friction. Staging and prod opt back in --
      # see their versions.tf.
      prevent_deletion_if_contains_resources = false
    }
  }
}

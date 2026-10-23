# =============================================================================
# envs/prod/versions.tf -- provider requirements and provider configuration
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
      version = "~> 5.10"
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
      # Prod's Key Vault runs with purge_protection_enabled = true (see
      # terraform.tfvars). Purge protection is Azure's one-way door: once on,
      # a vault can never be purged again -- not by this flag, not by the
      # portal, not by support. Setting purge_soft_delete_on_destroy = true
      # here would therefore be, at best, a silent no-op the moment Terraform
      # tried to act on it (Azure refuses the purge), and at worst it would
      # train an operator to expect `terraform destroy` to "clean up" prod's
      # vault the same way it does in dev -- which it categorically cannot,
      # and must not. This is the single most important `false` in this
      # directory: it is what stands between a mis-targeted
      # `terraform destroy` and PERMANENT loss of prod's key material. See
      # docs/architecture.md, "Why prod's purge protection is on and
      # irreversible".
      purge_soft_delete_on_destroy = false

      # Lets a `terraform apply` that collides with a still-soft-deleted
      # vault from a previous (deliberate, approved) destroy recover it
      # automatically instead of failing with "a vault with this name already
      # exists in a soft-deleted state". Recovering is not the same operation
      # as purging -- this does not weaken purge protection in any way.
      recover_soft_deleted_key_vaults = true
    }

    resource_group {
      # The single most load-bearing `true` in this file. Without it, a
      # `terraform destroy` run against the wrong directory, a `az group
      # delete` from a distracted operator, or a misconfigured pipeline
      # variable pointing at prod's resource group would succeed immediately.
      # With it, ANY attempt to delete a resource group that still contains
      # resources fails loudly at the Azure Resource Manager level -- before
      # Terraform, before the pipeline's own guards, independent of both.
      # Combined with the GitHub Environment approval gate and the blocked
      # destroy workflow (.github/workflows/terraform-destroy.yml), this is
      # one of several independent layers protecting prod -- see README.md,
      # "What is actually protecting prod".
      prevent_deletion_if_contains_resources = true
    }
  }
}

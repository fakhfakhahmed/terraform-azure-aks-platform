# =============================================================================
# envs/staging/backend.tf -- remote state backend (PARTIAL configuration)
# =============================================================================
# This block is deliberately incomplete. `resource_group_name`,
# `storage_account_name`, `container_name` and `key` are NOT hardcoded here --
# they are supplied at `terraform init` time via `-backend-config=backend.hcl`
# (see scripts/init-env.ps1, which runs exactly that).
#
# WHY PARTIAL, NOT COMPLETE
# -----------------------------------------------------------------------------
# 1. The storage account name is not known until bootstrap/ has been applied.
#    bootstrap/main.tf generates it with a random suffix
#    (`${prefix}tfstate${region_short}${random_string.state_suffix.result}`,
#    e.g. "afktfstateweu482913") specifically so it is globally-unique without
#    a human having to invent a name. That value cannot be committed here
#    because it does not exist until a human runs bootstrap once, and it will
#    be a DIFFERENT value in every fork/clone of this repository that bootstraps
#    its own backend.
# 2. Keeping the coordinates out of version control means this exact,
#    committed code can target a differently-named backend (a different
#    subscription, a disaster-recovery copy of the state account, a
#    second bootstrap for a workshop) without editing a tracked file -- only
#    the gitignored backend.hcl changes.
# 3. It keeps the (admittedly not-secret, but environment-specific and
#    bootstrap-derived) backend coordinates from living in git history
#    forever. See backend.hcl.example for the keys an operator fills in, and
#    .gitignore's "Backend configuration" section for the ignore rule.
#
# `use_azuread_auth = true` is NOT optional: bootstrap/variables.tf disables
# the storage account's shared access keys by default
# (`shared_access_key_enabled = false`), so the account key this backend type
# would otherwise use simply does not work. Authentication is via the
# operator's (or CI's OIDC-federated) Entra ID identity holding "Storage Blob
# Data Contributor" on the state container -- see
# bootstrap/github-oidc.tf's "Data-plane access to the Terraform state
# container" section.
# =============================================================================

terraform {
  backend "azurerm" {
    use_azuread_auth = true

    # resource_group_name  = (from backend.hcl)
    # storage_account_name = (from backend.hcl)
    # container_name       = (from backend.hcl)
    # key                  = (from backend.hcl, "staging/terraform.tfstate")
  }
}

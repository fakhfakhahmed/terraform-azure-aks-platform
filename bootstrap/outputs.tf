# =============================================================================
# bootstrap/outputs.tf
# =============================================================================
# These outputs are the hand-off between the one-time bootstrap and everything
# else. Two of them (`backend_config_hcl` and `github_variables_cli`) are
# deliberately formatted as copy-pasteable text rather than structured data,
# because the next step is a human pasting them somewhere -- and a setup guide
# that makes you assemble a string from six separate outputs is a setup guide
# people get wrong.
#
# NOTE ON SENSITIVITY: none of these values are secrets. A client ID, tenant ID
# and subscription ID are identifiers, not credentials -- which is the entire
# point of the OIDC model. They are stored as GitHub repository VARIABLES, not
# secrets, so they remain visible in logs and in the Actions UI where they are
# useful for debugging. Under a client-secret model, at least one of these
# would have had to be a secret.
# =============================================================================

# -----------------------------------------------------------------------------
# State backend
# -----------------------------------------------------------------------------

output "state_resource_group_name" {
  description = "Resource group containing the Terraform state storage account."
  value       = azurerm_resource_group.state.name
}

output "state_storage_account_name" {
  description = "Globally-unique name of the storage account holding Terraform state. Supply as the storage_account_name backend setting."
  value       = azurerm_storage_account.state.name
}

output "state_storage_account_id" {
  description = "Full ARM resource ID of the state storage account. Useful for scoping additional role assignments."
  value       = azurerm_storage_account.state.id
}

output "state_container_name" {
  description = "Blob container holding one state file per environment."
  value       = azurerm_storage_container.tfstate.name
}

output "state_blob_endpoint" {
  description = "Primary blob service endpoint of the state account."
  value       = azurerm_storage_account.state.primary_blob_endpoint
}

output "state_shared_access_key_enabled" {
  description = "Whether shared access keys remain usable on the state account. When false (the default), every consumer must authenticate with Entra ID and set use_azuread_auth = true in its backend block."
  value       = azurerm_storage_account.state.shared_access_key_enabled
}

# -----------------------------------------------------------------------------
# GitHub Actions OIDC identity
# -----------------------------------------------------------------------------

output "github_actions_client_id" {
  description = "Application (client) ID of the GitHub Actions OIDC identity. Set as the GitHub repository variable AZURE_CLIENT_ID. NOT a secret -- it is useless without a GitHub-signed token asserting a matching subject."
  value       = azuread_application.github_actions.client_id
}

output "github_actions_object_id" {
  description = "Object ID of the service principal. This is what role assignments actually reference; use it when granting further roles by hand."
  value       = azuread_service_principal.github_actions.object_id
}

output "github_actions_application_object_id" {
  description = "Object ID of the application registration (distinct from the service principal's object ID -- a frequent source of confusion when adding federated credentials manually)."
  value       = azuread_application.github_actions.object_id
}

output "federated_credential_subjects" {
  description = "The exact subject strings Entra ID will accept, keyed by credential name. Compare against the 'sub' claim in a failing workflow's token to debug AADSTS70021 errors."
  value       = { for k, v in local.federated_credentials : k => v.subject }
}

output "github_actions_role_assignments" {
  description = "Roles granted to the CI identity and the scope of each, for audit purposes."
  value       = { for k, v in local.ci_role_assignments : k => "${v.role} @ ${v.scope}" }
}

# -----------------------------------------------------------------------------
# Azure context
# -----------------------------------------------------------------------------

output "tenant_id" {
  description = "Entra ID tenant ID. Set as the GitHub repository variable AZURE_TENANT_ID."
  value       = data.azurerm_client_config.current.tenant_id
}

output "subscription_id" {
  description = "Target subscription ID. Set as the GitHub repository variable AZURE_SUBSCRIPTION_ID, and as the subscription_id input of every environment (azurerm v4 requires it)."
  value       = data.azurerm_client_config.current.subscription_id
}

output "subscription_display_name" {
  description = "Human-readable subscription name, printed so the operator can confirm they bootstrapped the subscription they intended to."
  value       = data.azurerm_subscription.current.display_name
}

# -----------------------------------------------------------------------------
# Copy-pasteable hand-off
# -----------------------------------------------------------------------------

output "backend_config_hcl" {
  description = "Contents to write into envs/<env>/backend.hcl. The 'key' line differs per environment -- uncomment the one you need."
  value       = <<-EOT
    # envs/<env>/backend.hcl -- partial backend configuration.
    # Generated by the bootstrap stack. This file is gitignored.
    #
    # Apply with:
    #   terraform init -reconfigure -backend-config=backend.hcl

    resource_group_name  = "${azurerm_resource_group.state.name}"
    storage_account_name = "${azurerm_storage_account.state.name}"
    container_name       = "${azurerm_storage_container.tfstate.name}"

    # One state blob per environment. Set exactly one:
    key = "dev/terraform.tfstate"
    # key = "staging/terraform.tfstate"
    # key = "prod/terraform.tfstate"

    # Authenticate to the blob endpoint with Entra ID rather than an account
    # key. Required, because the account has shared access keys disabled.
    use_azuread_auth = true
  EOT
}

output "github_variables_cli" {
  description = "gh CLI commands that configure every repository variable the workflows need. Run them from a clone of the repository."
  value       = <<-EOT
    # Requires the GitHub CLI, authenticated: gh auth login
    # These are VARIABLES, not secrets -- none of these values is a credential.

    gh variable set AZURE_CLIENT_ID        --body "${azuread_application.github_actions.client_id}"
    gh variable set AZURE_TENANT_ID        --body "${data.azurerm_client_config.current.tenant_id}"
    gh variable set AZURE_SUBSCRIPTION_ID  --body "${data.azurerm_client_config.current.subscription_id}"
    gh variable set TFSTATE_RESOURCE_GROUP --body "${azurerm_resource_group.state.name}"
    gh variable set TFSTATE_STORAGE_ACCOUNT --body "${azurerm_storage_account.state.name}"
    gh variable set TFSTATE_CONTAINER      --body "${azurerm_storage_container.tfstate.name}"

    # The approval gate is NOT created by Terraform -- GitHub Environments and
    # their protection rules live in GitHub, not Azure. Create them, then add
    # required reviewers, or the `environment:` key in the apply workflow is
    # decorative and applies will proceed unattended:
    #
    #   gh api -X PUT repos/${var.github_org}/${var.github_repository}/environments/dev
    #   gh api -X PUT repos/${var.github_org}/${var.github_repository}/environments/staging
    #   gh api -X PUT repos/${var.github_org}/${var.github_repository}/environments/prod
    #
    # Then, in the GitHub UI: Settings -> Environments -> prod ->
    #   [x] Required reviewers   (add yourself)
    #   [x] Deployment branches  (restrict to: ${var.github_default_branch})
  EOT
}

output "next_steps" {
  description = "What to do once the bootstrap apply completes."
  value       = <<-EOT
    Bootstrap complete.

      1. Write the backend config:
           terraform output -raw backend_config_hcl
         into envs/dev/backend.hcl, envs/staging/backend.hcl and
         envs/prod/backend.hcl, changing the `key` line in each.

      2. Configure the GitHub repository variables:
           terraform output -raw github_variables_cli

      3. Create the dev/staging/prod GitHub Environments and add REQUIRED
         REVIEWERS to each. Until you do, the apply workflow's approval gate
         does nothing.

      4. Initialise and plan an environment:
           make init-dev
           make plan-dev

      5. Store bootstrap/terraform.tfstate somewhere durable and private. It
         is LOCAL state and is not in the remote backend by design.

    Cost so far: a storage account with a handful of small blobs, and an Entra
    application. Effectively zero. The AKS clusters are what cost money --
    see docs/cost.md before running `make apply-dev`.
  EOT
}

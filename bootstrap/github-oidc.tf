# =============================================================================
# bootstrap/github-oidc.tf -- secretless GitHub Actions -> Azure authentication
# =============================================================================
#
# WHAT THIS REPLACES
# ------------------
# The conventional setup is:
#   az ad sp create-for-rbac --sdk-auth
# which prints a JSON blob containing a CLIENT SECRET, which you paste into a
# GitHub secret, and which then:
#   - is a bearer credential: anyone who obtains it is the service principal,
#     from anywhere on the internet, until someone notices,
#   - expires on a schedule nobody tracks, breaking deployments at 2am,
#   - is copied into every fork, every local .env, every screenshot,
#   - leaves no evidence of compromise -- the audit log just shows a normal
#     login from a valid credential.
#
# WHAT HAPPENS INSTEAD
# --------------------
# GitHub Actions can mint a short-lived OIDC ID token describing the *exact*
# job that is running: which repository, which branch or environment, which
# workflow. Entra ID is configured to trust that token for a specific
# application, but only when the token's issuer, audience AND subject match a
# federated identity credential we declare here.
#
#   1. The job asks the GitHub OIDC provider for a token with
#      audience "api://AzureADTokenExchange".
#   2. GitHub signs a JWT whose `sub` claim is, for example,
#      "repo:fakhfakhahmed/terraform-azure-aks-platform:environment:prod"
#      and whose `iss` is "https://token.actions.githubusercontent.com".
#   3. The job presents that JWT to Entra ID's token endpoint as a
#      client_assertion (grant type urn:ietf:params:oauth:client-assertion-type:jwt-bearer).
#   4. Entra validates the signature against GitHub's published JWKS, then
#      looks for a federated identity credential on the application whose
#      issuer/subject/audience all match. No match -> no token.
#   5. Entra returns a short-lived (roughly one hour) Azure access token.
#
# Net result: there is NO long-lived secret to steal. A leaked repository
# gives an attacker nothing, because the credential is bound to GitHub's
# assertion about where the code is running, and GitHub will not make that
# assertion for a job the attacker controls.
#
# THE SUBJECT STRING IS THE SECURITY BOUNDARY
# -------------------------------------------
# It is matched EXACTLY and is case-sensitive. "repo:Org/Repo:environment:prod"
# will not match a token carrying "repo:org/repo:environment:prod". This is the
# single most common reason an otherwise-correct OIDC setup fails with
# AADSTS70021 ("No matching federated identity record found").
#
# Never use a wildcard subject (`repo:org/*`) on a production identity: it
# would let any branch in any matching repository assume it.
#
# =============================================================================

locals {
  # The canonical "repo:<owner>/<name>" prefix every subject is built from.
  github_subject_prefix = "repo:${var.github_org}/${var.github_repository}"

  # ---------------------------------------------------------------------------
  # Federated credentials to create.
  #
  # Keyed by a stable, human-meaningful name so that adding or removing an
  # environment touches exactly one credential in state -- the reason this is
  # a for_each over a map rather than a count over a list.
  #
  # Azure limit: 20 federated identity credentials per application. With one
  # branch credential, one pull_request credential and one per environment,
  # this configuration uses 5. If you ever approach 20, that is the signal to
  # split into per-environment applications rather than to raise a support
  # ticket.
  # ---------------------------------------------------------------------------
  federated_credentials = merge(
    # --- Default branch -----------------------------------------------------
    # Lets a push to main run the apply workflow. Note the full ref path:
    # "ref:refs/heads/main", not "main".
    {
      "github-main-branch" = {
        subject     = "${local.github_subject_prefix}:ref:refs/heads/${var.github_default_branch}"
        description = "Workflows running on the ${var.github_default_branch} branch."
      }
    },

    # --- Pull requests ------------------------------------------------------
    # GitHub emits the literal subject "repo:<org>/<repo>:pull_request" for
    # pull_request-triggered workflows -- there is no branch name in it. This
    # subject is NOT issued for pull requests originating from forks, which is
    # what keeps an untrusted contributor from obtaining Azure credentials.
    var.create_pull_request_credential ? {
      "github-pull-request" = {
        subject     = "${local.github_subject_prefix}:pull_request"
        description = "Pull request workflows running terraform plan."
      }
    } : {},

    # --- GitHub Environments ------------------------------------------------
    # This is the approval gate. A job only receives a token with the subject
    # "...:environment:prod" once GitHub has admitted it into the `prod`
    # environment, and a protected environment admits a job only after its
    # required reviewers approve.
    #
    # The approval is therefore enforced at TOKEN ISSUANCE, in GitHub's
    # infrastructure, not by an `if:` condition in a YAML file that anyone with
    # write access could edit. That distinction is the whole point.
    {
      for env_name in var.github_environments :
      "github-environment-${env_name}" => {
        subject     = "${local.github_subject_prefix}:environment:${env_name}"
        description = "Workflows running in the protected '${env_name}' GitHub Environment."
      }
    }
  )

  # ---------------------------------------------------------------------------
  # Scopes at which the CI identity is granted its roles.
  # ---------------------------------------------------------------------------
  role_assignment_scopes = (
    var.role_assignment_scope == "subscription"
    ? { "subscription" = data.azurerm_subscription.current.id }
    : {
      for rg_name in var.scoped_resource_group_names :
      rg_name => "${data.azurerm_subscription.current.id}/resourceGroups/${rg_name}"
    }
  )

  # Roles granted at each scope above.
  #   Contributor                - create/update/delete resources.
  #   User Access Administrator  - create ROLE ASSIGNMENTS. Contributor
  #                                deliberately excludes this (otherwise it
  #                                could promote itself to Owner), and this
  #                                platform must create them: AcrPull for the
  #                                kubelet identity, Key Vault Secrets User for
  #                                each workload identity, Network Contributor
  #                                for the cluster identity on the VNet.
  ci_roles = var.grant_user_access_administrator ? ["Contributor", "User Access Administrator"] : ["Contributor"]

  # Cartesian product of scopes x roles, keyed stably for for_each.
  ci_role_assignments = {
    for pair in setproduct(keys(local.role_assignment_scopes), local.ci_roles) :
    "${pair[0]}|${pair[1]}" => {
      scope = local.role_assignment_scopes[pair[0]]
      role  = pair[1]
    }
  }
}

# -----------------------------------------------------------------------------
# Entra ID application registration
# -----------------------------------------------------------------------------
# An "application" is the identity definition; the "service principal" below is
# its instantiation inside this tenant, and is what role assignments actually
# point at. Both are needed.
# -----------------------------------------------------------------------------

resource "azuread_application" "github_actions" {
  display_name = "gh-${var.github_org}-${var.github_repository}"

  # Single-tenant. The default ("AzureADandPersonalMicrosoftAccount") would
  # let identities outside this tenant sign in to the application -- never
  # appropriate for a workload identity.
  sign_in_audience = "AzureADMyOrg"

  description = "GitHub Actions OIDC identity for ${var.github_org}/${var.github_repository}. No client secret is ever issued for this application -- authentication is exclusively via the federated identity credentials below."

  # Ownership matters operationally: without an owner, only a Global
  # Administrator can modify the application later.
  owners = [data.azurerm_client_config.current.object_id]

  # Tags here are Entra "service principal names"/labels, not Azure Resource
  # Manager tags. They surface in the Entra portal's app list and make a
  # purpose-built identity distinguishable from the dozens of others.
  tags = ["terraform", "github-actions", "oidc", "platform"]

  # No `password` block, no `azuread_application_password` resource anywhere in
  # this repository. That absence is the feature.

  lifecycle {
    # The application's object ID is referenced by every federated credential
    # and every role assignment. Recreating it silently breaks CI with a
    # confusing "no matching federated identity record found" rather than an
    # obvious failure.
    prevent_destroy = true
  }
}

resource "azuread_service_principal" "github_actions" {
  # azuread v3 renamed this argument from `application_id` to `client_id`.
  client_id = azuread_application.github_actions.client_id

  owners = [data.azurerm_client_config.current.object_id]

  description = "Service principal backing the GitHub Actions OIDC application. Role assignments target this principal's object ID."

  feature_tags {
    enterprise = true
    hide       = true # Hide from the "My Apps" portal -- no human signs in as this.
  }
}

# -----------------------------------------------------------------------------
# Federated identity credentials
# -----------------------------------------------------------------------------

resource "azuread_application_federated_identity_credential" "github" {
  for_each = local.federated_credentials

  # azuread v3 takes the application's RESOURCE ID here (the "/applications/
  # <object-id>" form exposed as `.id`). azuread v2 used a separate
  # `application_object_id` argument -- a frequent source of upgrade errors.
  application_id = azuread_application.github_actions.id

  display_name = each.key
  description  = each.value.description

  # The audience Entra expects in the `aud` claim. This exact string is also
  # what `azure/login@v2` requests from GitHub's token service by default.
  audiences = ["api://AzureADTokenExchange"]

  # GitHub's OIDC issuer. Entra fetches the signing keys from
  # <issuer>/.well-known/openid-configuration to validate the token.
  issuer = "https://token.actions.githubusercontent.com"

  # The security boundary. Matched exactly, case-sensitively.
  subject = each.value.subject
}

# -----------------------------------------------------------------------------
# Azure RBAC for the CI identity
# -----------------------------------------------------------------------------

resource "azurerm_role_assignment" "github_actions" {
  for_each = local.ci_role_assignments

  scope                = each.value.scope
  role_definition_name = each.value.role
  principal_id         = azuread_service_principal.github_actions.object_id

  # Declaring the principal type lets ARM skip its "does this object exist in
  # the directory yet?" lookup. Newly created service principals take time to
  # replicate across Entra, and without this the apply frequently fails with
  # "PrincipalNotFound" on the very first run -- then succeeds on a retry,
  # which is the most annoying class of flake there is.
  principal_type = "ServicePrincipal"

  description = "GitHub Actions OIDC identity for ${var.github_org}/${var.github_repository}."

  # Belt and braces for the same replication delay.
  skip_service_principal_aad_check = true
}

# -----------------------------------------------------------------------------
# Data-plane access to the Terraform state container
# -----------------------------------------------------------------------------
# Separate from the Contributor assignment above and genuinely required:
# Contributor is a CONTROL-plane role. It lets you manage the storage account
# resource; it does not let you read a blob. Because this account has shared
# access keys disabled, reading state is only possible through an Entra
# identity holding a data-plane role.
#
# Scoped to the CONTAINER rather than the account, so this principal can touch
# the state container and nothing else that might later live in the account.
# -----------------------------------------------------------------------------

resource "azurerm_role_assignment" "github_actions_state" {
  scope                = azurerm_storage_container.tfstate.resource_manager_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azuread_service_principal.github_actions.object_id
  principal_type       = "ServicePrincipal"

  description = "Read/write Terraform state blobs, and acquire the blob lease that implements state locking."

  skip_service_principal_aad_check = true
}

# -----------------------------------------------------------------------------
# Optional: Entra directory permissions
# -----------------------------------------------------------------------------
# If the platform ever needs to CREATE Entra objects from CI (groups, app
# registrations, or federated credentials for workload identities declared in
# an environment rather than here), the service principal needs Microsoft Graph
# application permissions -- Azure RBAC does not cover the directory.
#
# This is deliberately NOT automated. Granting Graph application permissions
# requires tenant-wide admin consent, which:
#   - most engineers do not have and should not have,
#   - is a materially bigger privilege than Contributor on one subscription,
#   - should be an explicit, logged decision by a directory administrator.
#
# The environments in this repository are designed to avoid needing it: all
# Entra objects are created here in bootstrap, by a human, and the environments
# consume them. If you do need it, the minimum is "Application.ReadWrite.OwnedBy"
# (not ".All"), granted and consented manually:
#
#   az ad app permission add --id <app-id> \
#     --api 00000003-0000-0000-c000-000000000000 \
#     --api-permissions 18a4783c-866b-4cc7-a460-3d5e5662c884=Role
#   az ad app permission admin-consent --id <app-id>
#
# -----------------------------------------------------------------------------

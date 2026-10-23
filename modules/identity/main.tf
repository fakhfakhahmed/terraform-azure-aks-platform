# =============================================================================
# modules/identity/main.tf -- per-workload Azure Workload Identity bindings
# =============================================================================
#
# One azurerm_user_assigned_identity and one azurerm_federated_identity_
# credential per entry in var.workloads. Each credential's `subject` pins
# the identity to exactly one Kubernetes ServiceAccount
# (system:serviceaccount:<namespace>:<name>), matched byte-for-byte -- the
# same "no wildcard, exact match" security property as the GitHub OIDC
# federation in bootstrap/github-oidc.tf, one layer down. See
# docs/architecture.md, "3. Workload Identity token exchange".
#
# This module deliberately grants NO Azure RBAC roles itself -- it only
# creates identities and binds them to the cluster's OIDC issuer. Role
# assignments (e.g. Key Vault Secrets User) are the consuming module's job
# (modules/keyvault takes `workload_principal_ids` and assigns roles there),
# keeping "who this identity IS" separate from "what this identity CAN DO".
# =============================================================================

locals {
  tags = merge(
    var.tags,
    {
      module = "identity"
    }
  )
}

resource "azurerm_user_assigned_identity" "workload" {
  for_each = var.workloads

  name                = "id-${var.name_prefix}-${each.key}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "workload" {
  for_each = var.workloads

  name                = "fic-${each.key}"
  resource_group_name = var.resource_group_name
  parent_id           = azurerm_user_assigned_identity.workload[each.key].id

  # The cluster's public OIDC issuer -- Entra fetches its JWKS from here to
  # verify the projected service-account token's signature at exchange time.
  issuer = var.oidc_issuer_url

  # THE security boundary. Must equal, byte-for-byte, the ServiceAccount that
  # will actually request tokens. A mismatch here (wrong namespace, wrong
  # name, trailing whitespace) produces AADSTS70021 at pod startup with no
  # indication of which half of the comparison is wrong -- see
  # docs/architecture.md, "The two failure modes you will actually hit".
  subject = "system:serviceaccount:${each.value.namespace}:${each.value.service_account_name}"

  # The only audience Entra's token exchange endpoint accepts for Workload
  # Identity Federation -- the same audience used in the GitHub OIDC flow in
  # bootstrap/github-oidc.tf, since both are instances of the same
  # client_assertion jwt-bearer exchange against Entra.
  audience = ["api://AzureADTokenExchange"]
}

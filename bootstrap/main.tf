# =============================================================================
# bootstrap/main.tf -- the Terraform remote state backend itself
# =============================================================================
#
# THE CHICKEN-AND-EGG PROBLEM
# ---------------------------
# Every environment in this repository stores its state in an Azure Storage
# blob container. But that storage account is itself infrastructure, and we
# want it managed as code like everything else. So: where does the state of
# the stack that creates the state backend live?
#
# Three options, and why this repo picks the third:
#
#   1. Click it together in the portal.
#      Rejected -- it is the single most security-sensitive resource in the
#      platform (it holds every environment's secrets in plaintext) and would
#      be the one thing with no reviewable definition.
#
#   2. Create it with Terraform, then migrate this stack's own state into it.
#      `terraform init -migrate-state` after adding a backend block. Elegant
#      and self-hosting, but it means the state of the backend depends on the
#      backend: if the account is ever lost you cannot run Terraform to
#      recreate it. A real deadlock at the worst possible moment.
#
#   3. Create it with Terraform using LOCAL state, and accept that this one
#      stack is bootstrapped out-of-band.   <-- chosen
#      This stack runs once, by a human, and is then essentially frozen. Its
#      local state file is small and the resources it manages are trivially
#      re-importable (`terraform import`) if it is ever lost -- there are only
#      a handful of them and their names are deterministic. The dependency
#      graph has no cycle.
#
# WHAT TO DO WITH bootstrap/terraform.tfstate
# -------------------------------------------
#   - It is gitignored and must never be committed.
#   - Store it somewhere durable and private (a password manager attachment, an
#     encrypted vault, or a private storage container in a *different*
#     subscription).
#   - If you lose it: do not panic and do not re-apply blindly. Import the
#     existing resources instead -- see bootstrap/README.md, "Recovering".
#
# =============================================================================

# -----------------------------------------------------------------------------
# Context
# -----------------------------------------------------------------------------

# Resolves the identity Terraform is currently running as. Used to grant that
# identity data-plane access to the state container, and as the owner of the
# Entra ID application created in github-oidc.tf.
data "azurerm_client_config" "current" {}

data "azurerm_subscription" "current" {}

locals {
  # Short region token used in resource names. Azure region names are too long
  # for the 24-character storage account limit, so they are abbreviated. The
  # same table lives in modules/naming -- duplicated here deliberately, because
  # bootstrap must not depend on a module it is responsible for bootstrapping.
  region_short_map = {
    westeurope         = "weu"
    northeurope        = "neu"
    francecentral      = "frc"
    germanywestcentral = "gwc"
    uksouth            = "uks"
    ukwest             = "ukw"
    swedencentral      = "sdc"
    switzerlandnorth   = "szn"
    eastus             = "eus"
    eastus2            = "eus2"
    westus2            = "wus2"
    westus3            = "wus3"
    centralus          = "cus"
  }

  region_short = lookup(local.region_short_map, var.location, substr(replace(var.location, " ", ""), 0, 4))

  # Storage account names: 3-24 chars, lowercase alphanumeric ONLY (no
  # hyphens), and globally unique across every Azure tenant. The random suffix
  # is what makes "afktfstate" collision-proof.
  #   afk + tfstate + weu + 6 random  = 3 + 7 + 3 + 6 = 19 chars. Comfortable.
  state_storage_account_name = substr(
    lower("${var.prefix}tfstate${local.region_short}${random_string.state_suffix.result}"),
    0,
    24
  )

  # Canonical tag set. The same five keys are required on every resource in
  # this platform and are enforced by policy/conftest/terraform.rego and by
  # the Azure Policy definition in policy/azure-policy/require-tags.json.
  tags = merge(
    {
      environment = "shared"
      project     = "terraform-azure-aks-platform"
      owner       = var.owner
      managed_by  = "terraform"
      cost_center = var.cost_center

      # Non-required but highly useful operational tags.
      component  = "terraform-state-backend"
      repository = "${var.github_org}/${var.github_repository}"
      criticality = "high"
    },
    var.additional_tags
  )
}

# Globally-unique suffix for the storage account name.
#
# `keepers` is deliberately empty: nothing should ever cause this value to be
# regenerated, because that would rename the storage account and orphan every
# environment's state file. If you need to change it, do so knowingly and
# migrate state first.
resource "random_string" "state_suffix" {
  length  = 6
  lower   = true
  upper   = false
  numeric = true
  special = false

  lifecycle {
    ignore_changes = [length, lower, upper, numeric, special]
  }
}

# -----------------------------------------------------------------------------
# Resource group
# -----------------------------------------------------------------------------
# Deliberately NOT one of the per-environment resource groups. The state
# backend must survive `terraform destroy` of every environment -- if state
# lived in the environment's own resource group, destroying the environment
# would delete the record of what was destroyed, halfway through.
# -----------------------------------------------------------------------------

resource "azurerm_resource_group" "state" {
  name     = var.state_resource_group_name
  location = var.location
  tags     = local.tags

  lifecycle {
    # This resource group is the root of trust for the whole platform.
    # Replacing it (which a location change would force) destroys every
    # environment's state file. Make that fail loudly at plan time.
    prevent_destroy = true
  }
}

# -----------------------------------------------------------------------------
# Storage account for Terraform state
# -----------------------------------------------------------------------------
# Hardening rationale, attribute by attribute, because this account holds every
# environment's state and state is PLAINTEXT SECRETS.
# -----------------------------------------------------------------------------

resource "azurerm_storage_account" "state" {
  name                = local.state_storage_account_name
  resource_group_name = azurerm_resource_group.state.name
  location            = azurerm_resource_group.state.location

  account_tier             = "Standard"
  account_replication_type = var.state_account_replication_type
  # StorageV2 is required for blob versioning, soft delete and the change feed.
  account_kind = "StorageV2"

  # Hot access tier: state blobs are small but read on every plan. Cool/Archive
  # would add retrieval latency and early-deletion charges for no benefit.
  access_tier = "Hot"

  # --- Transport security -----------------------------------------------
  # azurerm v4 RENAMED this argument from `enable_https_traffic_only`.
  # Using the v3 name against a v4 provider is an "Unsupported argument" error.
  https_traffic_only_enabled = true
  min_tls_version            = "TLS1_2"

  # --- Anonymous access --------------------------------------------------
  # Blocks any container or blob from being made publicly readable, even if
  # someone later sets a container's access level to "blob" or "container".
  # This is the account-level kill switch, and the single most important line
  # in this file.
  allow_nested_items_to_be_public = false

  # --- Credential surface ------------------------------------------------
  # With shared keys disabled, the ONLY way to read state is an Entra ID
  # identity holding an RBAC data-plane role. See the variable's description
  # for the full argument.
  shared_access_key_enabled = var.shared_access_key_enabled

  # Reachability from the public internet. Kept on by default so that
  # GitHub-hosted runners can reach the backend; see the variable description.
  public_network_access_enabled = var.state_account_public_network_access_enabled

  # Defence in depth against a mis-scoped SAS token: even if one is minted,
  # it cannot grant OAuth-protected operations.
  default_to_oauth_authentication = true

  # Require infrastructure-level double encryption at rest.
  infrastructure_encryption_enabled = true

  # Cross-tenant replication is a data-exfiltration path with no use case here.
  cross_tenant_replication_enabled = false

  blob_properties {
    # --- The recovery story -------------------------------------------
    # Versioning keeps every prior revision of terraform.tfstate. Combined
    # with soft delete, this is what makes "someone corrupted/truncated the
    # state file" a ten-minute recovery instead of a rebuild-from-scratch.
    # See docs/state-management.md, "Recovering a corrupted state".
    versioning_enabled = true

    # The change feed is an append-only log of every blob mutation: who
    # changed state, when, and from where. Invaluable for answering "which
    # pipeline run wrote this?" after an incident.
    change_feed_enabled           = true
    change_feed_retention_in_days = 90

    # Recover a deleted blob (and deleted versions) for N days.
    delete_retention_policy {
      days = var.blob_soft_delete_retention_days
    }

    # Recover an accidentally deleted *container*. Deleting the container is
    # the realistic worst case; this makes it survivable.
    container_delete_retention_policy {
      days = var.blob_soft_delete_retention_days
    }
  }

  # --- Network ACLs ------------------------------------------------------
  # Only emitted when IP rules were actually supplied. Applying a
  # `default_action = "Deny"` with an empty allow-list would lock everyone,
  # including this Terraform run, out of the account -- and because the
  # provider needs data-plane access to manage the container below, that
  # failure is not even recoverable by re-running.
  dynamic "network_rules" {
    for_each = length(var.allowed_state_access_ip_rules) > 0 ? [1] : []

    content {
      default_action = "Deny"
      ip_rules       = var.allowed_state_access_ip_rules

      # AzureServices bypass lets first-party services (and the portal's
      # storage browser) through. Logging/Metrics are included so diagnostic
      # settings keep working.
      bypass = ["AzureServices", "Logging", "Metrics"]
    }
  }

  tags = local.tags

  lifecycle {
    prevent_destroy = true
  }
}

# -----------------------------------------------------------------------------
# Blob container holding one state file per environment
# -----------------------------------------------------------------------------
# Layout inside the container:
#   tfstate/
#     dev/terraform.tfstate
#     staging/terraform.tfstate
#     prod/terraform.tfstate
#
# One container, one blob per environment, each with its own lease. Terraform
# acquires an exclusive BLOB LEASE on the state file for the duration of an
# operation -- this is Azure's native locking and is why, unlike the AWS S3
# backend, there is no DynamoDB table to provision. One fewer moving part.
# See docs/state-management.md.
# -----------------------------------------------------------------------------

resource "azurerm_storage_container" "tfstate" {
  name = var.state_container_name

  # azurerm v4 takes the storage account's RESOURCE ID here.
  # `storage_account_name` still works in 4.x but is deprecated and scheduled
  # for removal in 5.0; using the ID also removes the implicit dependency on
  # name resolution. Requires azurerm >= 4.9.
  storage_account_id = azurerm_storage_account.state.id

  # "private" = no anonymous access whatsoever. Belt and braces with the
  # account-level `allow_nested_items_to_be_public = false` above.
  container_access_type = "private"

  metadata = {
    purpose     = "terraform-remote-state"
    managed_by  = "terraform"
    environment = "shared"
  }
}

# -----------------------------------------------------------------------------
# Data-plane RBAC for the bootstrapping human
# -----------------------------------------------------------------------------
# Control-plane Owner does NOT grant data-plane blob access on a storage
# account. Without this assignment, `terraform plan` in envs/dev fails with
# a 403 from the blob endpoint even for a subscription Owner -- one of the
# most commonly misdiagnosed Azure errors there is.
# -----------------------------------------------------------------------------

resource "azurerm_role_assignment" "bootstrapper_state_access" {
  scope                = azurerm_storage_account.state.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = data.azurerm_client_config.current.object_id

  description = "Lets the engineer who bootstrapped the platform read and write Terraform state. Narrow this to a group in a real tenant."
}

# -----------------------------------------------------------------------------
# Optional management lock
# -----------------------------------------------------------------------------
# A CanNotDelete lock on the resource group means that `az group delete`, a
# portal click, or a Terraform run against the wrong directory cannot take out
# every environment's state in one action. The lock must be removed by hand
# before this stack can legitimately be destroyed -- that friction is the point.
# -----------------------------------------------------------------------------

resource "azurerm_management_lock" "state" {
  count = var.enable_state_resource_lock ? 1 : 0

  name       = "lock-terraform-state"
  scope      = azurerm_resource_group.state.id
  lock_level = "CanNotDelete"

  notes = "Protects the Terraform remote state backend. Removing this lock allows deletion of every environment's state file. Remove deliberately, never casually."
}

# -----------------------------------------------------------------------------
# Diagnostics on the blob service
# -----------------------------------------------------------------------------
# Every read and write of a state file is a security-relevant event: it is the
# moment plaintext secrets leave the account. Capturing StorageRead/Write/Delete
# gives an auditable answer to "who read state, and when".
#
# Routed to a workspace only if one is supplied; a Log Analytics workspace in
# the bootstrap stack would be an unexpected recurring cost for a repo someone
# just cloned, so it is opt-in.
# -----------------------------------------------------------------------------

resource "azurerm_log_analytics_workspace" "state_audit" {
  count = var.enable_state_audit_logging ? 1 : 0

  name                = "log-${var.prefix}-shared-${local.region_short}-tfstate"
  location            = azurerm_resource_group.state.location
  resource_group_name = azurerm_resource_group.state.name
  sku                 = "PerGB2018"
  retention_in_days   = 30

  tags = local.tags
}

resource "azurerm_monitor_diagnostic_setting" "state_blob" {
  count = var.enable_state_audit_logging ? 1 : 0

  name = "diag-tfstate-blob"
  # Diagnostics for blob operations attach to the blob SUB-RESOURCE, not to
  # the storage account itself. Getting this wrong yields "category not
  # supported" errors.
  target_resource_id         = "${azurerm_storage_account.state.id}/blobServices/default"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.state_audit[0].id

  enabled_log {
    category = "StorageRead"
  }

  enabled_log {
    category = "StorageWrite"
  }

  enabled_log {
    category = "StorageDelete"
  }

  enabled_metric {
    category = "Transaction"
  }
}

# =============================================================================
# bootstrap/variables.tf
# =============================================================================

# -----------------------------------------------------------------------------
# Azure context
# -----------------------------------------------------------------------------

variable "subscription_id" {
  description = <<-EOT
    Target Azure subscription ID (GUID). Required by azurerm v4 -- the provider
    no longer infers it from the Azure CLI context. Find yours with:
      az account show --query id -o tsv
  EOT
  type        = string

  validation {
    # Catch a pasted subscription *name*, a truncated GUID, or an ARM resource
    # path before Terraform spends 30 seconds failing against the API.
    condition     = can(regex("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "subscription_id must be a GUID, e.g. 00000000-0000-0000-0000-000000000000."
  }
}

variable "tenant_id" {
  description = <<-EOT
    Microsoft Entra ID tenant ID (GUID) that owns the subscription and in which
    the GitHub Actions application registration is created. Find yours with:
      az account show --query tenantId -o tsv
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$", var.tenant_id))
    error_message = "tenant_id must be a GUID, e.g. 00000000-0000-0000-0000-000000000000."
  }
}

variable "location" {
  description = "Azure region for the state backend resources."
  type        = string
  default     = "westeurope"

  validation {
    condition = contains([
      "westeurope", "northeurope", "francecentral", "germanywestcentral",
      "uksouth", "ukwest", "swedencentral", "switzerlandnorth",
      "eastus", "eastus2", "westus2", "westus3", "centralus",
    ], var.location)
    error_message = "location must be one of the supported regions. Add a region here after confirming AKS and the required SKUs are available in it (az vm list-skus --location <region>)."
  }
}

# -----------------------------------------------------------------------------
# Naming
# -----------------------------------------------------------------------------

variable "prefix" {
  description = <<-EOT
    Short organisation/owner prefix used in every resource name. Kept very
    short because Azure storage account names are limited to 24 characters and
    must be globally unique across every Azure tenant on the planet.
  EOT
  type        = string
  default     = "afk"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,5}$", var.prefix))
    error_message = "prefix must be 2-6 characters, lowercase alphanumeric, starting with a letter."
  }
}

variable "state_resource_group_name" {
  description = "Name of the resource group holding the Terraform state backend. Deliberately separate from every workload resource group so it is never caught in an environment teardown."
  type        = string
  default     = "rg-terraform-state"

  validation {
    condition     = can(regex("^[a-zA-Z0-9._()-]{1,90}$", var.state_resource_group_name))
    error_message = "Resource group names may be up to 90 characters of alphanumerics, underscores, parentheses, hyphens and periods."
  }
}

variable "state_container_name" {
  description = "Blob container holding the per-environment state files."
  type        = string
  default     = "tfstate"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{2,62}$", var.state_container_name))
    error_message = "Container names must be 3-63 characters, lowercase alphanumeric or hyphen, and start with a letter or number."
  }
}

# -----------------------------------------------------------------------------
# State storage account hardening
# -----------------------------------------------------------------------------

variable "state_account_replication_type" {
  description = <<-EOT
    Replication type for the state storage account.
      LRS  - 3 copies in one datacentre. Cheapest. Fine for a personal lab.
      ZRS  - 3 copies across availability zones in one region.
      GRS  - LRS plus asynchronous replication to a paired region.
      RAGRS- GRS with read access to the secondary.
    The real durability story for state is blob VERSIONING plus SOFT DELETE
    (both enabled below), not cross-region replication -- but a team that
    cannot tolerate a regional outage blocking all deployments should use GRS.
  EOT
  type        = string
  default     = "GRS"

  validation {
    condition     = contains(["LRS", "ZRS", "GRS", "RAGRS", "GZRS", "RAGZRS"], var.state_account_replication_type)
    error_message = "state_account_replication_type must be one of: LRS, ZRS, GRS, RAGRS, GZRS, RAGZRS."
  }
}

variable "blob_soft_delete_retention_days" {
  description = "Days a deleted state blob version remains recoverable. This is the primary recovery mechanism for 'someone deleted the state file'."
  type        = number
  default     = 30

  validation {
    condition     = var.blob_soft_delete_retention_days >= 7 && var.blob_soft_delete_retention_days <= 365
    error_message = "blob_soft_delete_retention_days must be between 7 and 365. Below 7 days there is no realistic chance of noticing and recovering."
  }
}

variable "shared_access_key_enabled" {
  description = <<-EOT
    Whether the storage account's shared access KEYS are usable.

    Set to false (the default) so the only way to read or write state is via
    Entra ID + RBAC. That is a significant security win: a leaked account key
    is a permanent, un-revocable, un-auditable credential that grants full
    read/write to every environment's state -- and state contains secrets in
    plaintext. With keys disabled, access is an RBAC assignment you can see,
    audit and revoke.

    The cost: every consumer must set `use_azuread_auth = true` in its backend
    block (this repo does) and hold "Storage Blob Data Contributor" on the
    container. Tools that only speak account keys will stop working.
  EOT
  type        = bool
  default     = false
}

variable "state_account_public_network_access_enabled" {
  description = <<-EOT
    Whether the state account is reachable from the public internet.

    Kept true by default because GitHub-hosted runners egress from a large,
    changing set of IPs that cannot practically be allow-listed, and locking
    this down without a self-hosted runner or a private endpoint would break
    CI entirely. The compensating controls are: shared keys disabled, Entra-only
    auth, TLS 1.2 minimum, and RBAC scoped to exactly two principals.

    In a corporate environment, set this to false and reach the account over a
    private endpoint from a self-hosted runner in the VNet.
  EOT
  type        = bool
  default     = true
}

variable "allowed_state_access_ip_rules" {
  description = "Optional list of public IPv4 addresses or CIDRs allowed through the storage firewall. Leave empty to apply no IP restriction (see state_account_public_network_access_enabled). Note: Azure storage firewalls reject /31 and /32 CIDR suffixes -- supply a bare address instead."
  type        = list(string)
  default     = []
}

variable "enable_state_audit_logging" {
  description = <<-EOT
    Create a Log Analytics workspace and route the state account's blob
    StorageRead/StorageWrite/StorageDelete events to it.

    Every read of a state file is the moment plaintext secrets leave the
    account, so in a real tenant this should be ON and the workspace should be
    one the security team already owns. It defaults to OFF here purely so that
    cloning this repository and running bootstrap does not silently create a
    recurring log-ingestion bill (see docs/cost.md).
  EOT
  type        = bool
  default     = false
}

variable "enable_state_resource_lock" {
  description = "Apply a CanNotDelete management lock to the state resource group. Cheap insurance against an accidental 'az group delete' taking every environment's state with it. Must be removed manually before the bootstrap stack itself can be destroyed."
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# GitHub OIDC federated identity
# -----------------------------------------------------------------------------

variable "github_org" {
  description = "GitHub organisation or user that owns the repository. Forms part of the federated credential subject, so it must match exactly (it is case-sensitive in the token claim)."
  type        = string
  default     = "fakhfakhahmed"

  validation {
    # NOTE: Terraform's regex() uses Go's RE2 engine, which has no lookahead
    # or backreferences. The "no consecutive hyphens" rule GitHub applies is
    # therefore expressed as a separate alltrue() check rather than a lookahead.
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9-]{0,38}$", var.github_org)) && !strcontains(var.github_org, "--")
    error_message = "github_org must be a valid GitHub account name: 1-39 alphanumerics or hyphens, starting with an alphanumeric, with no consecutive hyphens."
  }
}

variable "github_repository" {
  description = "Repository name. Combined with github_org to build the federated credential subject 'repo:<org>/<repo>:<entity>'."
  type        = string
  default     = "terraform-azure-aks-platform"

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]{1,100}$", var.github_repository))
    error_message = "github_repository must be a valid GitHub repository name."
  }
}

variable "github_environments" {
  description = <<-EOT
    GitHub Environments that may assume the Azure identity. One federated
    credential is created per entry, with subject
    'repo:<org>/<repo>:environment:<name>'.

    This is the load-bearing security control in the whole pipeline: a job can
    only obtain Azure credentials for an environment if GitHub asserts that the
    job is running IN that environment, and GitHub only lets a job enter a
    protected environment after the configured reviewers approve. The approval
    gate is therefore enforced by token issuance, not by a conditional in YAML
    that someone could edit.
  EOT
  type        = list(string)
  default     = ["dev", "staging", "prod"]

  validation {
    condition     = length(var.github_environments) > 0 && alltrue([for e in var.github_environments : can(regex("^[a-z0-9-]{1,32}$", e))])
    error_message = "github_environments must be a non-empty list of lowercase names (letters, digits, hyphens)."
  }
}

variable "github_default_branch" {
  description = "Default branch allowed to run applies. Produces the federated credential subject 'repo:<org>/<repo>:ref:refs/heads/<branch>'."
  type        = string
  default     = "main"
}

variable "create_pull_request_credential" {
  description = <<-EOT
    Create a federated credential for the 'pull_request' entity, letting PR
    workflows run `terraform plan` against the real subscription.

    Trade-off, stated honestly: all federated credentials on an application
    map to the SAME service principal, and therefore to the same role
    assignments. A `pull_request` credential consequently carries the full
    Contributor rights of the apply identity, even though the PR workflow only
    ever runs `terraform plan`. Nothing in Azure prevents a modified workflow
    on a branch from calling apply with it.

    What limits the blast radius today:
      - GitHub does not issue a token with this subject for pull requests from
        FORKS, so an untrusted contributor cannot obtain it at all.
      - Reaching apply still requires passing branch protection to land on
        main, or entering a protected GitHub Environment.

    The proper hardening is a SECOND application registration holding only
    Reader + Storage Blob Data Contributor, used exclusively by the PR plan
    job, with the Contributor identity reachable only from environment
    subjects. That is recorded as planned work in docs/security.md rather than
    implemented here, because it doubles the bootstrap surface and the
    single-identity model is what the supplied workflows are wired for.

    Set to false if you would rather PR plans run against no credentials at
    all (plan then only validates syntax, not live state).
  EOT
  type        = bool
  default     = true
}

variable "role_assignment_scope" {
  description = <<-EOT
    Scope at which the GitHub Actions identity is granted Contributor.
      "subscription"   - required if the pipeline creates its own resource
                         groups (it does: each environment owns one).
      "resource_group" - tighter, but then the resource groups must be created
                         out-of-band by a human first.
    Defaults to subscription for a self-contained demo; see README.md for the
    argument for scoping down in a real tenant.
  EOT
  type        = string
  default     = "subscription"

  validation {
    condition     = contains(["subscription", "resource_group"], var.role_assignment_scope)
    error_message = "role_assignment_scope must be either 'subscription' or 'resource_group'."
  }
}

variable "scoped_resource_group_names" {
  description = <<-EOT
    Resource groups the CI identity is granted Contributor on, used only when
    role_assignment_scope = "resource_group".

    These resource groups must ALREADY EXIST -- a role assignment cannot target
    a scope that has not been created yet. That is precisely the trade-off of
    resource-group scoping: it is tighter, but someone has to create the
    resource groups out-of-band first, which means they are no longer fully
    described by this repository.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for n in var.scoped_resource_group_names : can(regex("^[a-zA-Z0-9._()-]{1,90}$", n))])
    error_message = "Each entry must be a valid Azure resource group name."
  }

  validation {
    # Cross-variable references inside a validation block require Terraform
    # >= 1.9 -- which is exactly why required_version pins that floor. Before
    # 1.9 this consistency rule could only be expressed as a `precondition` on
    # some arbitrary resource, or not at all.
    condition     = var.role_assignment_scope != "resource_group" || length(var.scoped_resource_group_names) > 0
    error_message = "When role_assignment_scope = \"resource_group\", scoped_resource_group_names must list at least one existing resource group."
  }
}

variable "grant_user_access_administrator" {
  description = <<-EOT
    Grant the CI identity "User Access Administrator" in addition to
    Contributor.

    Why it is needed: this platform creates ROLE ASSIGNMENTS as part of the
    infrastructure -- AcrPull for the AKS kubelet identity, Key Vault Secrets
    User for each workload identity, Network Contributor for the cluster
    identity on the VNet. Writing a role assignment requires the
    Microsoft.Authorization/roleAssignments/write permission, which Contributor
    explicitly excludes (otherwise Contributor could trivially escalate itself
    to Owner).

    Why it is dangerous: User Access Administrator CAN escalate itself to
    Owner. Treat the CI principal as a privileged identity accordingly.

    How to scope it down -- in order of preference:
      1. Use "Role Based Access Control Administrator" instead, with an ABAC
         condition restricting WHICH roles it may assign (e.g. only AcrPull,
         Key Vault Secrets User, Network Contributor). This removes the
         escalation path. See README.md for the condition expression.
      2. Scope the assignment to individual resource groups rather than the
         subscription.
      3. Pre-create the role assignments out-of-band and have Terraform
         reference them with data sources instead of creating them.
  EOT
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# Tagging
# -----------------------------------------------------------------------------

variable "owner" {
  description = "Owner tag value -- the human or team accountable for these resources."
  type        = string
  default     = "ahmed.fakhfakh"
}

variable "cost_center" {
  description = "Cost centre tag used for showback/chargeback reporting."
  type        = string
  default     = "platform-engineering"
}

variable "additional_tags" {
  description = "Extra tags merged over the defaults. Useful for a ticket reference or a temporary owner override."
  type        = map(string)
  default     = {}
}

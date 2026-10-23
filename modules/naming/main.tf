# =============================================================================
# modules/naming/main.tf -- the single source of truth for every resource name
# =============================================================================
#
# WHY A DEDICATED NAMING MODULE
# ------------------------------
# Every other module in this platform (network, acr, aks, identity, keyvault,
# observability) needs deterministic, CAF-aligned names, and several of them
# (ACR, Key Vault, Storage) have DIFFERENT and stricter character rules than
# the rest (alphanumeric-only, length-capped, globally unique). Computing
# these independently in each module would mean the naming convention lives
# in N places and drifts the moment someone edits one of them.
#
# This module owns that convention exactly once. Per the module composition
# diagram in docs/architecture.md, every other module takes this module's
# `names` output (or the individual convenience outputs) and creates
# resources -- it never invents a name itself.
#
# NAMING CONVENTION
# ------------------
# Most resources: {type}-{prefix}-{environment}-{region_short}
#   e.g. rg-aksplat-prod-weu, vnet-aksplat-prod-weu, aks-aksplat-prod-weu
#
# Resources scoped and already-unique inside the VNet (subnets, their NSGs)
# drop the prefix/env/region tokens -- they are unique by virtue of living in
# one VNet, and the shorter name is what actually appears in `kubectl`
# output, NSG rule descriptions and the architecture diagram, so matching the
# diagram exactly here keeps code and documentation from drifting apart:
#   snet-aks-system, nsg-aks-system, snet-private-endpoints, snet-appgw
#
# Globally-unique, alphanumeric-only resources (ACR today; Storage in a
# future module) compress every token together and drop all separators:
#   acr{prefix}{environment}{region_short}  e.g. acraksplatprodweu
# =============================================================================

locals {
  # Short region token used in every resource name. Azure region names are
  # too long for several name-length limits (24 chars for storage accounts,
  # 50 for ACR once prefix/env are folded in). This is the SAME mapping as
  # bootstrap/main.tf and bootstrap/variables.tf's location validation --
  # duplicated deliberately, because bootstrap must not depend on a module it
  # is responsible for bootstrapping (see bootstrap/main.tf's own comment on
  # this). If you add a region here, add it in both places.
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

  region_short = local.region_short_map[var.location]

  # Common "{prefix}-{environment}-{region_short}" token, reused by almost
  # every name below. Computed once so a future convention tweak (e.g.
  # swapping token order) is a one-line change.
  base = "${var.prefix}-${var.environment}-${local.region_short}"

  # Same token with no separators, lowercased, for alphanumeric-only names.
  base_compact = lower(replace(local.base, "-", ""))

  names = {
    # --- Resource group -----------------------------------------------------
    resource_group = "rg-${local.base}"

    # --- Networking -----------------------------------------------------
    vnet = "vnet-${local.base}"

    # Subnet and per-subnet NSG names deliberately omit prefix/env/region:
    # they are unique within the VNet they live in, and this is the exact
    # naming the architecture diagram and the NSG rule rationale in
    # docs/architecture.md use -- keeping docs and code in lockstep.
    subnet_aks_system         = "snet-aks-system"
    subnet_aks_user           = "snet-aks-user"
    subnet_private_endpoints  = "snet-private-endpoints"
    subnet_appgw              = "snet-appgw"
    nsg_aks_system            = "nsg-aks-system"
    nsg_aks_user              = "nsg-aks-user"
    nsg_private_endpoints     = "nsg-private-endpoints"

    nat_gateway    = "ngw-${local.base}"
    nat_public_ip  = "pip-ngw-${local.base}"
    route_table    = "rt-${local.base}"

    # --- Compute / registry ---------------------------------------------
    aks = "aks-${local.base}"

    # ACR names must be 5-50 characters, alphanumeric only (no hyphens), and
    # globally unique across every Azure tenant. This module cannot enforce
    # global uniqueness (that is an API-time check), but it produces the
    # compliant, collision-minimised shape: "acr" + prefix + env + region,
    # e.g. "acraksplatprodweu" -- 17 chars, comfortably under the 50 cap.
    acr = "acr${local.base_compact}"

    # --- Secrets / observability -----------------------------------------
    key_vault     = "kv-${local.base}"
    log_analytics = "log-${local.base}"
    app_insights  = "appi-${local.base}"
    action_group  = "ag-${local.base}"

    # --- Identity ---------------------------------------------------------
    # Not a full resource name: modules/identity appends "-<workload-key>"
    # per workload identity it creates, e.g. "id-aksplat-prod-weu-demo-app".
    # Exposed as a prefix (rather than this module taking a list of workload
    # names) because the set of workloads is an application-layer concern
    # that this platform-layer module should not need to know about.
    user_assigned_identity_prefix = "id-${local.base}"
  }

  # Canonical tag set applied to every taggable resource in the platform.
  # These five keys are required by policy/conftest/terraform.rego and the
  # Azure Policy definition in policy/azure-policy/require-tags.json -- do
  # not rename them without updating both.
  tags = merge(
    {
      environment = var.environment
      project     = "terraform-azure-aks-platform"
      owner       = var.owner
      managed_by  = "terraform"
      cost_center = var.cost_center
    },
    var.additional_tags
  )
}

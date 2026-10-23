# =============================================================================
# envs/prod/terraform.tfvars -- prod environment shape
# =============================================================================
# Committed on purpose (see .gitignore's "Variable files" section): this file
# holds only non-sensitive environment shape (node counts, SKUs, CIDRs).
# Secrets never belong here -- they come from Key Vault or OIDC-issued tokens.
#
# Applying this file is gated: 2 required reviewers on the GitHub Environment
# named "prod" (see bootstrap/github-oidc.tf), and scripts/apply-env.ps1
# refuses a local apply to prod without -Force AND a typed "apply-prod"
# confirmation. See README.md for the full story.
# =============================================================================

# --- Azure context -----------------------------------------------------------
# PLACEHOLDERS. Replace both with your real subscription/tenant before
# running `terraform plan`:
#   az account show --query "{subscription_id:id, tenant_id:tenantId}" -o json
subscription_id = "00000000-0000-0000-0000-000000000000"
tenant_id       = "00000000-0000-0000-0000-000000000000"

location = "westeurope"

# --- Naming / tagging ---------------------------------------------------------
prefix      = "aksplat"
owner       = "platform-engineering-team" # a team, not an individual, for prod
cost_center = "platform-engineering"

additional_tags = {
  criticality = "high"
}

# --- Networking ---------------------------------------------------------------
# Prod owns 10.30.0.0/16 per docs/architecture.md's IP address plan. Subnet
# offsets (/20, /20, /24, /24) are identical across every environment.
vnet_address_space = "10.30.0.0/16"
subnet_cidrs = {
  aks_system        = "10.30.0.0/20"
  aks_user          = "10.30.16.0/20"
  private_endpoints = "10.30.32.0/24"
  appgw             = "10.30.33.0/24"
}

# Prod is the ONLY environment with private endpoints -- see
# docs/architecture.md's environment topology table. ACR and Key Vault are
# reachable exclusively through snet-private-endpoints once this is true.
enable_private_endpoints = true

# Irrelevant while private_cluster_enabled = true below (the module does not
# even emit this argument in that case), but kept populated in case of a
# documented, deliberate break-glass switch to a public API server. Replace
# with your real office/VPN egress CIDR if you ever do.
authorized_ip_ranges = []

# --- Observability --------------------------------------------------------
log_retention_days = 90
action_group_email_receivers = [
  # REQUIRED: add at least one real, monitored address before applying.
  # "platform-oncall@example.com",
]
enable_managed_prometheus = false
enable_managed_grafana    = false

# --- Azure Container Registry -----------------------------------------------
# Premium is REQUIRED in prod: it is the only tier that supports private
# endpoints, geo-replication (not used today, see docs/architecture.md's
# known-gaps table) and the untagged-manifest retention policy.
acr_sku                   = "Premium"
acr_retention_policy_days = 30

# --- AKS ----------------------------------------------------------------------
# Pin an explicit version here once you have decided one -- never leave this
# null in prod. Example: "1.29.7".
kubernetes_version = null

sku_tier                 = "Standard" # 99.95% SLA
private_cluster_enabled  = true       # API server reachable only via its private endpoint in snet-private-endpoints

system_node_vm_size = "Standard_D4s_v5"
system_node_count   = 3

user_node_vm_size   = "Standard_D4s_v5"
user_node_min_count = 3
user_node_max_count = 10

zones          = ["1", "2", "3"]
network_policy = "cilium" # eBPF dataplane, identity-based policy enforcement

# REQUIRED: replace with a real Entra ID group object ID before applying.
# Individual operator access to prod should always flow through group
# membership, never a personal grant.
admin_group_object_ids = []

automatic_upgrade_channel = "patch"
node_os_upgrade_channel   = "NodeImage"
maintenance_window_day    = "Sunday"
maintenance_window_hours  = [2, 3]

# --- Workload Identity ----------------------------------------------------
workloads = {
  "demo-app" = {
    namespace            = "apps"
    service_account_name = "demo-app"
  }
}

# --- Key Vault ------------------------------------------------------------
key_vault_sku_name                    = "premium"
key_vault_purge_protection_enabled    = true # irreversible once applied -- see docs/architecture.md and versions.tf
key_vault_soft_delete_retention_days  = 90   # Azure's maximum
key_vault_network_acls_default_action = "Deny"
key_vault_allowed_ip_rules            = []

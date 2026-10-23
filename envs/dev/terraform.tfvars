# =============================================================================
# envs/dev/terraform.tfvars -- dev environment shape
# =============================================================================
# Committed on purpose (see .gitignore's "Variable files" section): this file
# holds only non-sensitive environment shape (node counts, SKUs, CIDRs).
# Secrets never belong here -- they come from Key Vault or OIDC-issued tokens.
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
owner       = "ahmed.fakhfakh"
cost_center = "platform-engineering"

additional_tags = {}

# --- Networking ---------------------------------------------------------------
# Dev owns 10.10.0.0/16 per docs/architecture.md's IP address plan. Subnet
# offsets (/20, /20, /24, /24) are identical across every environment.
vnet_address_space = "10.10.0.0/16"
subnet_cidrs = {
  aks_system        = "10.10.0.0/20"
  aks_user          = "10.10.16.0/20"
  private_endpoints = "10.10.32.0/24"
  appgw             = "10.10.33.0/24"
}

# No private endpoints in dev -- see docs/architecture.md's environment
# topology table. ACR and Key Vault stay on their public, RBAC-protected
# data-plane endpoints.
enable_private_endpoints = false

# Empty = no IP restriction on the public API server. Replace with your own
# office/VPN egress CIDR (e.g. ["203.0.113.4/32"]) once you have one --
# leaving this empty means the API server is reachable from the whole
# internet (still gated by Azure RBAC for Kubernetes + Entra auth, but worth
# tightening).
authorized_ip_ranges = []

# --- Observability --------------------------------------------------------
log_retention_days           = 30
action_group_email_receivers = []
enable_managed_prometheus    = false
enable_managed_grafana       = false

# --- Azure Container Registry -----------------------------------------------
# Basic: no geo-replication, no private endpoints, no retention policy --
# matches dev's "no private endpoints, keep it cheap" posture.
acr_sku                   = "Basic"
acr_retention_policy_days = 7 # ignored at Basic; set for when you bump the SKU

# --- AKS ----------------------------------------------------------------------
kubernetes_version = null # let Azure pick the current default; automatic_upgrade_channel manages drift

sku_tier                 = "Free" # no uptime SLA -- see docs/architecture.md on why that's deliberate in dev
private_cluster_enabled  = false  # public API server; kubectl works without a VPN

system_node_vm_size = "Standard_B2s" # burstable, cheap -- system pool only runs CoreDNS/konnectivity/CSI
system_node_count   = 1

user_node_vm_size   = "Standard_D2s_v5"
user_node_min_count = 1
user_node_max_count = 2

zones          = [] # Standard_B2s is not available in every zone -- no zone pinning in dev
network_policy = "azure" # Cilium's dataplane needs node SKU/kernel combinations dev's B2s doesn't give it

admin_group_object_ids = [] # empty: a single operator typically holds Owner/Contributor on the dev RG

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
key_vault_sku_name                    = "standard"
key_vault_purge_protection_enabled    = false # dev vaults are created/destroyed routinely -- see versions.tf
key_vault_soft_delete_retention_days  = 7     # Azure's minimum; dev has no reason to hold onto a longer window
key_vault_network_acls_default_action = "Allow"
key_vault_allowed_ip_rules            = []

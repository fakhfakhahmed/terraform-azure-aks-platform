# =============================================================================
# envs/staging/terraform.tfvars -- staging environment shape
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
# Staging owns 10.20.0.0/16 per docs/architecture.md's IP address plan.
# Subnet offsets (/20, /20, /24, /24) are identical across every environment.
vnet_address_space = "10.20.0.0/16"
subnet_cidrs = {
  aks_system        = "10.20.0.0/20"
  aks_user          = "10.20.16.0/20"
  private_endpoints = "10.20.32.0/24"
  appgw             = "10.20.33.0/24"
}

# Staging mirrors prod's topology at smaller scale EXCEPT here: per
# docs/architecture.md's environment topology table, staging does NOT get
# private endpoints -- only prod does. ACR and Key Vault stay on their
# public, RBAC-protected data-plane endpoints.
enable_private_endpoints = false

# Empty = no IP restriction on the public API server. Replace with your real
# office/VPN egress CIDR (e.g. ["203.0.113.4/32"]) before treating staging as
# anything more than a scratch environment.
authorized_ip_ranges = []

# --- Observability --------------------------------------------------------
log_retention_days = 30
action_group_email_receivers = [
  # Add at least one real address here -- staging is where alerting itself
  # gets validated before it matters in prod.
]
enable_managed_prometheus = false
enable_managed_grafana    = false

# --- Azure Container Registry -----------------------------------------------
# Standard: larger storage/throughput than Basic, still no geo-replication or
# private endpoints -- matches staging's "mirror prod, smaller and cheaper"
# posture.
acr_sku                   = "Standard"
acr_retention_policy_days = 7 # ignored at Standard; set for when you bump to Premium

# --- AKS ----------------------------------------------------------------------
kubernetes_version = null # pin an explicit version (e.g. "1.29.7") once staging needs change-controlled upgrades

sku_tier                = "Standard" # 99.95% SLA -- staging should behave like prod here
private_cluster_enabled = false      # public API server; kubectl works without a VPN

system_node_vm_size = "Standard_D2s_v5"
system_node_count   = 2

user_node_vm_size   = "Standard_D4s_v5"
user_node_min_count = 2
user_node_max_count = 4

zones          = ["1", "2"] # two zones -- validates zone-aware scheduling ahead of prod's three
network_policy = "cilium"   # staging is where a Cilium NetworkPolicy change gets validated before prod

admin_group_object_ids = [] # add a real Entra group once more than one operator touches staging

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
key_vault_purge_protection_enabled    = true # mirrors prod's hardening -- see docs/architecture.md
key_vault_soft_delete_retention_days  = 30
key_vault_network_acls_default_action = "Allow"
key_vault_allowed_ip_rules            = []

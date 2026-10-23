# =============================================================================
# modules/network/variables.tf
# =============================================================================

variable "names" {
  description = <<-EOT
    The `names` map output by modules/naming (passed through unchanged, as
    `map(string)`). This module reads the keys: vnet, subnet_aks_system,
    subnet_aks_user, subnet_private_endpoints, subnet_appgw, nsg_aks_system,
    nsg_aks_user, nsg_private_endpoints, nat_gateway, nat_public_ip,
    route_table.

    Accepting the whole map (rather than one variable per name) keeps this
    module's interface stable as the naming convention grows new keys for
    other modules -- this module simply ignores keys it does not use.
  EOT
  type        = map(string)

  validation {
    condition = alltrue([
      for k in [
        "vnet", "subnet_aks_system", "subnet_aks_user",
        "subnet_private_endpoints", "subnet_appgw",
        "nsg_aks_system", "nsg_aks_user", "nsg_private_endpoints",
        "nat_gateway", "nat_public_ip", "route_table",
      ] : contains(keys(var.names), k)
    ])
    error_message = "names is missing one or more required keys. Pass through modules.naming.names unchanged -- see this variable's description for the full required key list."
  }
}

variable "resource_group_name" {
  description = "Resource group the network resources are created in. Composition (which resource group) is an environment-root decision, not this module's -- see design principle 4 in docs/architecture.md."
  type        = string
}

variable "location" {
  description = "Azure region for all resources in this module. Must match the resource group's region."
  type        = string
}

variable "tags" {
  description = "Tags applied to every taggable resource, typically module.naming.tags from the caller."
  type        = map(string)
  default     = {}
}

variable "vnet_address_space" {
  description = <<-EOT
    CIDR block for the VNet, e.g. "10.30.0.0/16". Per the IP address plan in
    docs/architecture.md, each environment gets a full /16 and the only thing
    that varies between environments is the second octet -- dev 10.10.0.0/16,
    staging 10.20.0.0/16, prod 10.30.0.0/16.
  EOT
  type        = string

  validation {
    condition     = can(cidrhost(var.vnet_address_space, 0))
    error_message = "vnet_address_space must be a valid CIDR block, e.g. \"10.30.0.0/16\"."
  }
}

variable "subnet_cidrs" {
  description = <<-EOT
    CIDR blocks for the four fixed subnets, keyed to match the IP address
    plan in docs/architecture.md (shown for prod):
      aks_system        -> 10.30.0.0/20   (4,091 usable -- system node pool NICs)
      aks_user          -> 10.30.16.0/20  (4,091 usable -- user node pool NICs)
      private_endpoints -> 10.30.32.0/24  (251 usable  -- private endpoint NICs)
      appgw             -> 10.30.33.0/24  (251 usable  -- reserved, no resources deployed)

    /20 node subnets are sized for a future migration off Azure CNI overlay to
    VNet-routable pod IPs (nodes x (max_pods + 1) addresses needed), not for
    today's node count -- see "Why /20 for node subnets" in
    docs/architecture.md. Do not shrink them to save address space.
  EOT
  type = object({
    aks_system        = string
    aks_user          = string
    private_endpoints = string
    appgw             = string
  })

  validation {
    condition = alltrue([
      can(cidrhost(var.subnet_cidrs.aks_system, 0)),
      can(cidrhost(var.subnet_cidrs.aks_user, 0)),
      can(cidrhost(var.subnet_cidrs.private_endpoints, 0)),
      can(cidrhost(var.subnet_cidrs.appgw, 0)),
    ])
    error_message = "Every entry in subnet_cidrs must be a valid CIDR block."
  }
}

variable "enable_private_dns_zones" {
  description = <<-EOT
    Create the three privatelink DNS zones (Key Vault, ACR, AKS) and link them
    to the VNet. Only meaningful alongside private endpoints, which this
    platform only deploys in prod (see "Environment topology differences" in
    docs/architecture.md) -- the caller decides per environment, this module
    does not hardcode an environment check.
  EOT
  type        = bool
  default     = true
}

variable "log_analytics_workspace_id" {
  description = "Resource ID of the Log Analytics workspace that NSG and public IP diagnostic settings are routed to."
  type        = string

  validation {
    condition     = can(regex("^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/.+/providers/Microsoft\\.OperationalInsights/workspaces/.+$", var.log_analytics_workspace_id))
    error_message = "log_analytics_workspace_id must be a full Log Analytics workspace resource ID."
  }
}

variable "enable_nat_gateway" {
  description = <<-EOT
    Attach a NAT Gateway (with a static Standard public IP) to the node
    subnets for deterministic, allow-listable egress. See "Why NAT Gateway
    rather than load-balancer outbound SNAT" in docs/architecture.md -- this
    platform enables it in every environment, including dev, so dev exercises
    the same egress semantics as prod. The variable exists for the rare case
    (a fully air-gapped lab, or a hub-and-spoke migration where egress moves
    to a firewall) where a caller needs to omit it.
  EOT
  type        = bool
  default     = true
}

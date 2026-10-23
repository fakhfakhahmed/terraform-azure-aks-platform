# =============================================================================
# modules/observability/variables.tf
# =============================================================================
# This module provisions the PLATFORM side of observability: Log Analytics,
# the Container-Insights-facing workspace, Application Insights, baseline
# scheduled-query alerts, and optionally managed Prometheus/Grafana. It does
# NOT define dashboards, scrape configs, or application-level alerting rules
# -- those live in the separate k8s-observability-stack repository
# (kube-prometheus-stack / Grafana dashboards as code), which this platform
# just gives a Log Analytics workspace and a Prometheus remote-write endpoint
# to target.
# =============================================================================

variable "resource_group_name" {
  description = "Resource group the observability stack is deployed into."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "tags" {
  description = "Tags merged onto every resource this module creates."
  type        = map(string)
  default     = {}
}

variable "name_prefix" {
  description = "Prefix used to build this module's resource names, e.g. \"aksplat-prod-weu\" -> \"log-aksplat-prod-weu\"."
  type        = string

  validation {
    condition     = length(var.name_prefix) > 0
    error_message = "name_prefix must not be empty."
  }
}

variable "log_retention_days" {
  description = "Log Analytics workspace retention. 30 days in dev/staging, 90 in prod per docs/architecture.md's environment topology table."
  type        = number

  validation {
    condition     = var.log_retention_days >= 30 && var.log_retention_days <= 730
    error_message = "log_retention_days must be between 30 and 730."
  }
}

variable "enable_managed_prometheus" {
  description = <<-EOT
    Creates an azurerm_monitor_workspace (Azure Monitor managed Prometheus)
    when true. Off by default: Container Insights already covers the
    portfolio demo's needs, and managed Prometheus bills on ingested sample
    volume -- see docs/architecture.md's "Known gaps" table. Turn this on in
    an environment that also runs kube-prometheus-stack configured to
    remote_write here, to demonstrate the hybrid platform-managed-storage /
    app-managed-scrape-config pattern.
  EOT
  type        = bool
  default     = false
}

variable "enable_managed_grafana" {
  description = "Creates an azurerm_dashboard_grafana (Azure Managed Grafana) when true, wired to the managed Prometheus workspace if that is also enabled. Off by default for the same cost reasons as enable_managed_prometheus."
  type        = bool
  default     = false
}

variable "action_group_email_receivers" {
  description = "Email addresses that receive alert notifications from this module's action group. Default [] means alerts fire but notify nobody -- set at least one address in staging/prod."
  type        = list(string)
  default     = []
}

variable "aks_cluster_id" {
  description = <<-EOT
    Resource ID of the AKS cluster to scope the baseline scheduled-query
    alerts (node not ready, pod restart rate, disk pressure) to. Pass null to
    skip creating those alerts entirely -- useful when this module is called
    BEFORE modules/aks exists yet (e.g. a first apply that only stands up the
    Log Analytics workspace AKS itself depends on), or when no cluster
    exists in this environment at all. When composing an environment, call
    this module's Log Analytics output into modules/aks, then pass
    modules/aks's `cluster_id` back into a SECOND reference to this module's
    alerts -- in practice, most environments simply apply twice (the alerts
    show up as "will be created" on the second plan) or pass
    `module.aks.cluster_id` directly, since Terraform resolves the ordering
    from the reference regardless of which module appears first in the file.
  EOT
  type        = string
  default     = null
}

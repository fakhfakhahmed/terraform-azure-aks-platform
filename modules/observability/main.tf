# =============================================================================
# modules/observability/main.tf
# =============================================================================
# This module provisions the PLATFORM side of observability (Log Analytics,
# Container Insights wiring, managed Prometheus/Grafana, baseline alerts). It
# intentionally does NOT define dashboards, scrape configs, or
# application-level alerting rules -- those live in the separate
# k8s-observability-stack repository (kube-prometheus-stack / Grafana
# dashboards as code), which this platform just gives a Log Analytics
# workspace and a Prometheus remote-write endpoint to target.
#
# Composition note: this module is typically called BEFORE modules/aks (the
# cluster needs `log_analytics_workspace_id` for its `oms_agent` block), and
# `aks_cluster_id` is then threaded back in via a direct reference to
# `module.aks.cluster_id` from the environment root -- Terraform resolves the
# create-ordering from that reference regardless of which module's block
# appears first in the file. See docs/architecture.md, "Module composition".
# =============================================================================

locals {
  tags = merge(
    var.tags,
    {
      module = "observability"
    }
  )

  create_alerts = var.aks_cluster_id != null

  # Action group short_name has a hard 12-character ARM limit.
  action_group_short_name = substr("aksplat-ag", 0, 12)
}

# -----------------------------------------------------------------------------
# Log Analytics workspace
# -----------------------------------------------------------------------------
# The single destination every other resource in this platform sends
# telemetry to: AKS's oms_agent (Container Insights), ACR and Key Vault
# diagnostic settings, and (via Application Insights below) application
# traces. One workspace per environment keeps correlation across those
# signals possible with a single KQL query spanning tables, instead of
# cross-workspace queries that Log Analytics makes needlessly awkward.
# -----------------------------------------------------------------------------

resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${var.name_prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location

  sku               = "PerGB2018"
  retention_in_days = var.log_retention_days

  tags = local.tags
}

# -----------------------------------------------------------------------------
# Application Insights (workspace-based)
# -----------------------------------------------------------------------------
# "workspace-based" (as opposed to the legacy "classic" mode) stores all
# Application Insights telemetry AS Log Analytics tables in the SAME
# workspace above, rather than in a separate, independently-billed Application
# Insights store. This is the only mode the azurerm provider's
# `application_type` + `workspace_id` combination supports going forward --
# classic App Insights resources are deprecated by Microsoft.
# -----------------------------------------------------------------------------

resource "azurerm_application_insights" "this" {
  name                = "appi-${var.name_prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location

  workspace_id     = azurerm_log_analytics_workspace.this.id
  application_type = "web"

  tags = local.tags
}

# -----------------------------------------------------------------------------
# Action group
# -----------------------------------------------------------------------------

resource "azurerm_monitor_action_group" "this" {
  name                = "ag-${var.name_prefix}"
  resource_group_name = var.resource_group_name
  short_name          = local.action_group_short_name

  dynamic "email_receiver" {
    for_each = { for idx, addr in var.action_group_email_receivers : idx => addr }

    content {
      name                    = "email-${email_receiver.key}"
      email_address           = email_receiver.value
      use_common_alert_schema = true
    }
  }

  tags = local.tags
}

# -----------------------------------------------------------------------------
# Baseline alerts -- scheduled KQL queries, not plain ARM metric alerts
# -----------------------------------------------------------------------------
# AKS does not expose "node ready" or "pod restart count" as ARM platform
# metrics (azurerm_monitor_metric_alert only sees metrics in the ARM metrics
# namespace, and these conditions live in Container-Insights-ingested log
# tables instead). azurerm_monitor_scheduled_query_rules_alert_v2 runs a KQL
# query against the Log Analytics workspace on a schedule and alerts on the
# result -- the correct primitive for exactly this class of condition.
#
# All three are guarded on `local.create_alerts` (aks_cluster_id != null):
# they are meaningless before a cluster exists, and this module is routinely
# applied once before modules/aks exists at all.
#
# These are a BASELINE, not the platform's complete alerting story -- see the
# top-of-file comment: workload-specific and SLO-driven alerting belongs in
# k8s-observability-stack.
# -----------------------------------------------------------------------------

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "node_not_ready" {
  count = local.create_alerts ? 1 : 0

  name                = "alert-${var.name_prefix}-node-not-ready"
  resource_group_name = var.resource_group_name
  location            = var.location

  evaluation_frequency = "PT5M"
  window_duration      = "PT15M"
  scopes               = [azurerm_log_analytics_workspace.this.id]
  severity             = 1 # 0=Critical .. 4=Verbose; 1=Error -- a node outage is not yet a full-cluster incident.

  criteria {
    query = <<-KQL
      KubeNodeInventory
      | where TimeGenerated > ago(15m)
      | summarize arg_max(TimeGenerated, Status) by Computer, ClusterId
      | where Status !has "Ready"
      | summarize NotReadyNodeCount = dcount(Computer) by ClusterId
    KQL

    time_aggregation_method = "Maximum"
    threshold               = 0
    operator                = "GreaterThan"

    resource_id_column = "ClusterId"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  auto_mitigation_enabled = true
  action {
    action_groups = [azurerm_monitor_action_group.this.id]
  }

  description = "Fires when any AKS node's last reported KubeNodeInventory status is not Ready. Baseline platform alert -- see modules/observability's top-of-file comment on scope."
  tags        = local.tags
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "pod_restart_rate" {
  count = local.create_alerts ? 1 : 0

  name                = "alert-${var.name_prefix}-pod-restart-rate"
  resource_group_name = var.resource_group_name
  location            = var.location

  evaluation_frequency = "PT5M"
  window_duration      = "PT15M"
  scopes               = [azurerm_log_analytics_workspace.this.id]
  severity             = 2 # Warning -- a crash loop is noteworthy before it is critical.

  criteria {
    query = <<-KQL
      KubePodInventory
      | where TimeGenerated > ago(15m)
      | summarize RestartCount = max(PodRestartCount) by PodUid = ContainerID, ClusterId
      | summarize TotalRestarts = sum(RestartCount) by ClusterId
    KQL

    time_aggregation_method = "Maximum"
    threshold               = 5
    operator                = "GreaterThan"

    resource_id_column = "ClusterId"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  auto_mitigation_enabled = true
  action {
    action_groups = [azurerm_monitor_action_group.this.id]
  }

  description = "Fires when summed pod restart counts across the cluster exceed 5 within a 15-minute window -- an early crash-loop signal. Baseline platform alert, tune the threshold per-workload in k8s-observability-stack as the real signal matures."
  tags        = local.tags
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "node_disk_pressure" {
  count = local.create_alerts ? 1 : 0

  name                = "alert-${var.name_prefix}-node-disk-pressure"
  resource_group_name = var.resource_group_name
  location            = var.location

  evaluation_frequency = "PT15M"
  window_duration      = "PT30M"
  scopes               = [azurerm_log_analytics_workspace.this.id]
  severity             = 2 # Warning -- actionable before it becomes eviction-triggering disk pressure.

  criteria {
    query = <<-KQL
      Perf
      | where TimeGenerated > ago(30m)
      | where ObjectName == "K8SNode" and CounterName == "disk usage percentage"
      | summarize AvgDiskUsedPercent = avg(CounterValue) by Computer, ClusterId = bag_pack("cluster", _ResourceId)
      | where AvgDiskUsedPercent > 85
      | summarize NodesUnderPressure = dcount(Computer) by tostring(ClusterId)
    KQL

    time_aggregation_method = "Maximum"
    threshold               = 0
    operator                = "GreaterThan"

    resource_id_column = "ClusterId"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  auto_mitigation_enabled = true
  action {
    action_groups = [azurerm_monitor_action_group.this.id]
  }

  description = "Fires when any node's disk usage averages above 85% over a 30-minute window -- the precursor to kubelet disk-pressure eviction. Baseline platform alert."
  tags        = local.tags
}

# -----------------------------------------------------------------------------
# Azure Monitor managed Prometheus (optional)
# -----------------------------------------------------------------------------
# A managed, horizontally-scaled remote_write target. Deliberately NOT paired
# with a Data Collection Rule/scrape config here -- what to scrape is an
# application-layer decision owned by k8s-observability-stack's
# kube-prometheus-stack deployment, which this module just gives an ingestion
# endpoint to point its remote_write at.
# -----------------------------------------------------------------------------

resource "azurerm_monitor_workspace" "this" {
  count = var.enable_managed_prometheus ? 1 : 0

  name                = "amw-${var.name_prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location

  tags = local.tags
}

# -----------------------------------------------------------------------------
# Azure Managed Grafana (optional)
# -----------------------------------------------------------------------------
# Dashboards themselves are NOT defined here -- see the top-of-file comment.
# This resource only stands up the Grafana instance and, when managed
# Prometheus is also enabled, wires it as a datasource integration so
# dashboards authored elsewhere (k8s-observability-stack, or by hand in the
# Grafana UI) have something to query immediately.
# -----------------------------------------------------------------------------

resource "azurerm_dashboard_grafana" "this" {
  count = var.enable_managed_grafana ? 1 : 0

  name                = "amg-${var.name_prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location

  grafana_major_version = 10

  # Public by default to keep the portfolio demo reachable without a VPN;
  # tighten to false alongside a private endpoint in a real production
  # tenant, the same public/private trade-off made for the AKS API server.
  public_network_access_enabled = true

  # Azure Managed Grafana requires a system-assigned identity at minimum to
  # read from the integrated Prometheus workspace via Azure RBAC rather than
  # a stored datasource credential.
  identity {
    type = "SystemAssigned"
  }

  dynamic "azure_monitor_workspace_integrations" {
    for_each = var.enable_managed_prometheus ? [1] : []

    content {
      azure_monitor_workspace_id = azurerm_monitor_workspace.this[0].id
    }
  }

  tags = local.tags
}

# Grafana's own managed identity needs "Monitoring Data Reader" on the
# Prometheus workspace to actually query it -- the
# azure_monitor_workspace_integrations block above wires up the association,
# but does not itself grant the RBAC role that makes queries succeed.
resource "azurerm_role_assignment" "grafana_prometheus_reader" {
  count = (var.enable_managed_grafana && var.enable_managed_prometheus) ? 1 : 0

  scope                = azurerm_monitor_workspace.this[0].id
  role_definition_name = "Monitoring Data Reader"
  principal_id         = azurerm_dashboard_grafana.this[0].identity[0].principal_id
  principal_type       = "ServicePrincipal"

  description = "Lets Azure Managed Grafana's own identity query the managed Prometheus workspace it is integrated with."

  skip_service_principal_aad_check = true
}

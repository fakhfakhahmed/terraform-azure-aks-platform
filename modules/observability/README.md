# modules/observability

Provisions the platform side of observability: a Log Analytics workspace, workspace-based
Application Insights, a baseline action group, three scheduled-query-rule alerts scoped to an AKS
cluster, and optional Azure Monitor managed Prometheus / Azure Managed Grafana.

This module intentionally does **not** define dashboards, scrape configs, or application-level
alerting rules — those live in the separate `k8s-observability-stack` repository
(kube-prometheus-stack / Grafana dashboards as code), which this platform just gives a Log
Analytics workspace and a Prometheus remote-write endpoint to target.

## Usage

```hcl
module "observability" {
  source = "../../modules/observability"

  resource_group_name = azurerm_resource_group.this.name
  location             = var.location
  tags                 = local.tags
  name_prefix          = "aksplat-${var.environment}-${local.region_short}"

  log_retention_days = var.log_retention_days # 30 dev/staging, 90 prod

  action_group_email_receivers = var.alert_email_receivers

  enable_managed_prometheus = var.enable_managed_prometheus
  enable_managed_grafana    = var.enable_managed_grafana

  # Null on the environment's first apply (before the cluster exists);
  # module.aks.cluster_id once the cluster is up. Terraform resolves
  # ordering from the reference, not from file position.
  aks_cluster_id = module.aks.cluster_id
}
```

## Design notes

- **Scheduled query rules, not plain metric alerts.** AKS does not expose "node ready" or "pod
  restart count" as ARM platform metrics — those conditions live in Container-Insights log tables
  (`KubeNodeInventory`, `KubePodInventory`, `Perf`). `azurerm_monitor_scheduled_query_rules_alert_v2`
  runs a KQL query against the workspace on a schedule, which is the correct primitive here; a
  bare `azurerm_monitor_metric_alert` cannot see these signals at all.
- **Alerts are guarded on `aks_cluster_id != null`.** This module is routinely applied once to
  create the Log Analytics workspace AKS itself needs before the cluster exists; the alerts
  simply do not exist until a cluster ID is supplied.
- **Workspace-based Application Insights.** `application_type = "web"` + `workspace_id` stores all
  App Insights telemetry as Log Analytics tables in the same workspace — the only mode Microsoft
  supports going forward; "classic" App Insights is deprecated.
- **Managed Prometheus/Grafana are both off by default.** Container Insights covers the portfolio
  demo; both add real ingestion/compute cost. Grafana's own managed identity is granted
  "Monitoring Data Reader" on the Prometheus workspace when both are enabled, since the
  `azure_monitor_workspace_integrations` block wires up the association but does not itself grant
  the RBAC role needed to query it.

## Requirements

| Name | Version |
|---|---|
| terraform | >= 1.9.0 |
| azurerm | ~> 4.0 |

## Providers

| Name | Version |
|---|---|
| azurerm | ~> 4.0 |

## Inputs

| Name | Description | Type | Default | Required |
|---|---|---|---|---|
| resource_group_name | Resource group | `string` | n/a | yes |
| location | Azure region | `string` | n/a | yes |
| tags | Tags merged onto every resource this module creates | `map(string)` | `{}` | no |
| name_prefix | Prefix used to build resource names | `string` | n/a | yes |
| log_retention_days | 30-730 | `number` | n/a | yes |
| enable_managed_prometheus | Create an Azure Monitor managed Prometheus workspace | `bool` | `false` | no |
| enable_managed_grafana | Create an Azure Managed Grafana instance | `bool` | `false` | no |
| action_group_email_receivers | Alert notification email addresses | `list(string)` | `[]` | no |
| aks_cluster_id | AKS cluster ID to scope baseline alerts to, or null to skip them | `string` | `null` | no |

## Outputs

| Name | Description |
|---|---|
| log_analytics_workspace_id | Workspace resource ID |
| log_analytics_workspace_name | Workspace name |
| app_insights_id | Application Insights resource ID |
| app_insights_connection_string | Connection string (sensitive) |
| action_group_id | Baseline action group resource ID |
| prometheus_workspace_id | Managed Prometheus workspace ID, or null |
| grafana_endpoint | Managed Grafana endpoint URL, or null |

## Resources

- `azurerm_log_analytics_workspace.this`
- `azurerm_application_insights.this`
- `azurerm_monitor_action_group.this`
- `azurerm_monitor_scheduled_query_rules_alert_v2.node_not_ready` (count, guarded on `aks_cluster_id`)
- `azurerm_monitor_scheduled_query_rules_alert_v2.pod_restart_rate` (count, guarded on `aks_cluster_id`)
- `azurerm_monitor_scheduled_query_rules_alert_v2.node_disk_pressure` (count, guarded on `aks_cluster_id`)
- `azurerm_monitor_workspace.this` (count, only when `enable_managed_prometheus`)
- `azurerm_dashboard_grafana.this` (count, only when `enable_managed_grafana`)
- `azurerm_role_assignment.grafana_prometheus_reader` (count, only when both are enabled)

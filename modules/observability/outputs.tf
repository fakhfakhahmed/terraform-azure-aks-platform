output "log_analytics_workspace_id" {
  description = "Resource ID of the Log Analytics workspace. Feed into modules/aks's `log_analytics_workspace_id`, and into ACR/Key Vault/NSG diagnostic settings."
  value       = azurerm_log_analytics_workspace.this.id
}

output "log_analytics_workspace_name" {
  description = "Name of the Log Analytics workspace."
  value       = azurerm_log_analytics_workspace.this.name
}

output "app_insights_id" {
  description = "Resource ID of the workspace-based Application Insights resource."
  value       = azurerm_application_insights.this.id
}

output "app_insights_connection_string" {
  description = "Application Insights connection string. Sensitive: contains an ingestion key that, while not a full-control credential, should not appear in logs or plan output."
  value       = azurerm_application_insights.this.connection_string
  sensitive   = true
}

output "action_group_id" {
  description = "Resource ID of the baseline action group, reusable by alerts defined outside this module (e.g. a workload-specific alert in the environment root)."
  value       = azurerm_monitor_action_group.this.id
}

output "prometheus_workspace_id" {
  description = "Resource ID of the Azure Monitor managed Prometheus workspace, or null when enable_managed_prometheus is false. This is the remote_write target k8s-observability-stack's kube-prometheus-stack deployment should be configured against."
  value       = var.enable_managed_prometheus ? azurerm_monitor_workspace.this[0].id : null
}

output "grafana_endpoint" {
  description = "The managed Grafana instance's endpoint URL, or null when enable_managed_grafana is false."
  value       = var.enable_managed_grafana ? azurerm_dashboard_grafana.this[0].endpoint : null
}

output "identity_ids" {
  description = "Map of workload key to the full Azure resource ID of its user-assigned identity."
  value       = { for k, v in azurerm_user_assigned_identity.workload : k => v.id }
}

output "principal_ids" {
  description = "Map of workload key to its identity's principal (object) ID. Feed this into modules/keyvault's `workload_principal_ids` for Key Vault Secrets User role assignments, or into any other module/role assignment the workload needs."
  value       = { for k, v in azurerm_user_assigned_identity.workload : k => v.principal_id }
}

output "client_ids" {
  description = "Map of workload key to its identity's client ID. This is the value rendered into the Kubernetes ServiceAccount annotation `azure.workload.identity/client-id` -- see kubernetes/serviceaccount.yaml and docs/architecture.md, '3. Workload Identity token exchange'."
  value       = { for k, v in azurerm_user_assigned_identity.workload : k => v.client_id }
}

# =============================================================================
# envs/prod/outputs.tf
# =============================================================================

output "resource_group_name" {
  description = "Name of prod's resource group."
  value       = azurerm_resource_group.this.name
}

output "cluster_name" {
  description = "Name of the AKS cluster, as consumed by scripts/connect-aks.*."
  value       = module.aks.cluster_name
}

output "aks_oidc_issuer_url" {
  description = "The cluster's public OIDC issuer URL. Public by design -- it serves only signing keys -- see docs/architecture.md, '3. Workload Identity token exchange'."
  value       = module.aks.oidc_issuer_url
}

output "node_resource_group" {
  description = "The auto-managed MC_* resource group holding node VMs, NICs, disks and the cluster-managed load balancer/public IP."
  value       = module.aks.node_resource_group
}

output "acr_login_server" {
  description = "ACR login server FQDN, used by `docker login`/`docker push` and as the image prefix in Kubernetes manifests. Resolves to the private endpoint's IP from inside the VNet, and is not publicly reachable in prod (public_network_access_enabled = false)."
  value       = module.acr.acr_login_server
}

output "key_vault_uri" {
  description = "The vault's data-plane URI, used by the Secrets Store CSI driver's SecretProviderClass. Reachable only via the private endpoint in prod (public_network_access_enabled = false)."
  value       = module.keyvault.key_vault_uri
}

output "vnet_id" {
  description = "Resource ID of prod's VNet."
  value       = module.network.vnet_id
}

output "log_analytics_workspace_id" {
  description = "Resource ID of the Log Analytics workspace Container Insights and every diagnostic setting in this environment feed."
  value       = module.observability.log_analytics_workspace_id
}

output "workload_identity_client_ids" {
  description = <<-EOT
    Map of workload key to its managed identity's client ID -- this is the
    value rendered into each Kubernetes ServiceAccount's
    `azure.workload.identity/client-id` annotation. See
    kubernetes/serviceaccount.yaml and docs/architecture.md,
    '3. Workload Identity token exchange'. Not secret: a client ID is a
    public identifier, meaningless without the matching federated credential.
  EOT
  value       = module.identity.client_ids
}

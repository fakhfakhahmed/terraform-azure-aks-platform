# =============================================================================
# modules/acr/outputs.tf
# =============================================================================

output "acr_id" {
  description = "Resource ID of the container registry. Consumed by modules/aks for the AcrPull role assignment against the cluster's kubelet identity."
  value       = azurerm_container_registry.this.id
}

output "acr_name" {
  description = "Name of the container registry."
  value       = azurerm_container_registry.this.name
}

output "acr_login_server" {
  description = "Login server FQDN (e.g. acraksplatprodweu.azurecr.io), used by `docker login` / `docker push` and as the image prefix in Kubernetes manifests."
  value       = azurerm_container_registry.this.login_server
}

output "cluster_id" {
  description = "Resource ID of the AKS cluster."
  value       = azurerm_kubernetes_cluster.this.id
}

output "cluster_name" {
  description = "Name of the AKS cluster, as consumed by scripts/connect-aks.* and env outputs."
  value       = azurerm_kubernetes_cluster.this.name
}

output "oidc_issuer_url" {
  description = "The cluster's public OIDC issuer URL. Feed this into modules/identity as the `issuer` on every federated identity credential -- see docs/architecture.md, '3. Workload Identity token exchange'."
  value       = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "kubelet_identity_object_id" {
  description = "Object ID of the cluster's kubelet identity. This is the principal that actually pulls container images -- any additional ACR access beyond `attached_acr_ids` must be granted to this, not to cluster_identity_principal_id."
  value       = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
}

output "cluster_identity_principal_id" {
  description = "Principal (object) ID of the cluster's control-plane user-assigned identity. Grant this identity roles that the control plane itself needs (e.g. Network Contributor on the VNet) -- it is distinct from, and must not be confused with, the kubelet identity above."
  value       = azurerm_user_assigned_identity.control_plane.principal_id
}

output "node_resource_group" {
  description = "The auto-managed resource group (MC_*) holding node VMs, NICs, disks, and the cluster-managed load balancer/public IP. Needed for diagnostics and for any NSG/UDR that must reference node-pool infrastructure directly."
  value       = azurerm_kubernetes_cluster.this.node_resource_group
}

output "cluster_fqdn" {
  description = "The API server's FQDN -- the private FQDN when private_cluster_enabled is true, otherwise the public FQDN. Used by scripts/connect-aks.* and kubeconfig generation."
  value       = var.private_cluster_enabled ? azurerm_kubernetes_cluster.this.private_fqdn : azurerm_kubernetes_cluster.this.fqdn
}

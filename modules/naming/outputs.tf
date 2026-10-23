# =============================================================================
# modules/naming/outputs.tf
# =============================================================================

output "names" {
  description = <<-EOT
    Map of every resource name this platform computes, keyed by logical
    resource. See main.tf for the convention. Consuming modules should
    destructure the keys they need, e.g. `module.naming.names["vnet"]`.
  EOT
  value       = local.names
}

output "tags" {
  description = "Common tag set (environment, project, owner, managed_by, cost_center, merged with additional_tags) to apply to every taggable resource."
  value       = local.tags
}

output "region_short" {
  description = "Abbreviated region token used throughout resource names, e.g. \"weu\" for westeurope."
  value       = local.region_short
}

# -----------------------------------------------------------------------------
# Convenience outputs
# -----------------------------------------------------------------------------
# The handful of names every other module needs are also exposed directly, so
# a caller wiring up `modules/network` or `modules/acr` does not have to write
# `module.naming.names["resource_group"]` for the two or three names it
# actually consumes. The full `names` map remains the canonical source for
# everything else.
# -----------------------------------------------------------------------------

output "resource_group_name" {
  description = "Convenience accessor for names[\"resource_group\"]."
  value       = local.names.resource_group
}

output "vnet_name" {
  description = "Convenience accessor for names[\"vnet\"]."
  value       = local.names.vnet
}

output "aks_name" {
  description = "Convenience accessor for names[\"aks\"]."
  value       = local.names.aks
}

output "acr_name" {
  description = "Convenience accessor for names[\"acr\"] (alphanumeric-only, globally-unique-shaped ACR name)."
  value       = local.names.acr
}

output "key_vault_name" {
  description = "Convenience accessor for names[\"key_vault\"]."
  value       = local.names.key_vault
}

output "log_analytics_name" {
  description = "Convenience accessor for names[\"log_analytics\"]."
  value       = local.names.log_analytics
}

# =============================================================================
# modules/identity/variables.tf
# =============================================================================
# One user-assigned managed identity plus one federated identity credential
# PER WORKLOAD, keyed by a stable map key rather than counted, so that adding
# or removing a workload touches exactly one entry in state -- the same
# for_each-over-a-map reasoning applied to the federated credentials in
# bootstrap/github-oidc.tf.
# =============================================================================

variable "resource_group_name" {
  description = "Resource group the workload identities are created in."
  type        = string
}

variable "location" {
  description = "Azure region for the managed identities."
  type        = string
}

variable "tags" {
  description = "Tags merged onto every identity this module creates."
  type        = map(string)
  default     = {}
}

variable "name_prefix" {
  description = "Prefix used to build each identity's resource name: \"id-${name_prefix}-${workload_key}\"."
  type        = string

  validation {
    condition     = length(var.name_prefix) > 0
    error_message = "name_prefix must not be empty."
  }
}

variable "oidc_issuer_url" {
  description = <<-EOT
    The AKS cluster's OIDC issuer URL (modules/aks output `oidc_issuer_url`).
    Used as the `issuer` on every federated identity credential this module
    creates. This module must therefore be composed AFTER modules/aks in the
    environment root -- see docs/architecture.md, "Ordering constraints that
    are real".
  EOT
  type        = string
}

variable "workloads" {
  description = <<-EOT
    Workloads to provision a managed identity and federated credential for,
    keyed by a stable, human-meaningful workload key (e.g. "demo-app",
    "external-dns"). Each entry binds exactly one Kubernetes ServiceAccount
    (namespace + name) to its own Azure identity -- see
    docs/architecture.md, "3. Workload Identity token exchange", for why the
    subject string this produces
    (system:serviceaccount:<namespace>:<service_account_name>) must match the
    deployed ServiceAccount byte-for-byte.
  EOT
  type = map(object({
    namespace            = string
    service_account_name = string
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, w in var.workloads : length(w.namespace) > 0 && length(w.service_account_name) > 0
    ])
    error_message = "Every workload entry must specify a non-empty namespace and service_account_name."
  }
}

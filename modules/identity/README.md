# modules/identity

Creates one Azure user-assigned managed identity and one federated identity credential per
workload, binding a Kubernetes ServiceAccount to an Azure identity with zero stored secrets. See
[docs/architecture.md](../../docs/architecture.md), "3. Workload Identity token exchange".

Must be composed **after** `modules/aks` in the environment root: the federated credential's
`issuer` is the cluster's `oidc_issuer_url`, which does not exist until the cluster does.

## Usage

```hcl
module "identity" {
  source = "../../modules/identity"

  resource_group_name = azurerm_resource_group.this.name
  location             = var.location
  tags                 = local.tags
  name_prefix          = "aksplat-${var.environment}"

  oidc_issuer_url = module.aks.oidc_issuer_url

  workloads = {
    demo-app = {
      namespace             = "apps"
      service_account_name  = "demo-app"
    }
    external-dns = {
      namespace             = "kube-system"
      service_account_name  = "external-dns"
    }
  }
}
```

The resulting `client_ids["demo-app"]` is rendered into the ServiceAccount annotation
`azure.workload.identity/client-id` in `kubernetes/serviceaccount.yaml`, and
`principal_ids["demo-app"]` is passed into `modules/keyvault`'s `workload_principal_ids` so the
workload can read secrets via the Secrets Store CSI driver.

## Design notes

- **Identity only, no roles.** This module answers "who is this workload" -- it grants no Azure
  RBAC roles itself. Role assignments live in the consuming module (e.g. `modules/keyvault`),
  keeping identity and authorization decoupled.
- **Subject matching is exact and case-sensitive.** `system:serviceaccount:<namespace>:<name>`
  must equal the deployed ServiceAccount byte-for-byte, or token exchange fails with
  `AADSTS70021`. See `docs/architecture.md`, "The two failure modes you will actually hit".
- **`for_each` over a map**, not `count`, so adding or removing one workload never reindexes or
  recreates another workload's identity.

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
| resource_group_name | Resource group for the identities | `string` | n/a | yes |
| location | Azure region | `string` | n/a | yes |
| tags | Tags merged onto every identity | `map(string)` | `{}` | no |
| name_prefix | Prefix used to build each identity's name | `string` | n/a | yes |
| oidc_issuer_url | AKS cluster OIDC issuer URL | `string` | n/a | yes |
| workloads | Map of workload key -> { namespace, service_account_name } | `map(object)` | `{}` | no |

## Outputs

| Name | Description |
|---|---|
| identity_ids | Map of workload key to managed identity resource ID |
| principal_ids | Map of workload key to managed identity principal ID |
| client_ids | Map of workload key to managed identity client ID |

## Resources

- `azurerm_user_assigned_identity.workload` (for_each over `workloads`)
- `azurerm_federated_identity_credential.workload` (for_each over `workloads`)

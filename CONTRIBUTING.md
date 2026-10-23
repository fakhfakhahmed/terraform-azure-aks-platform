# Contributing

Thanks for taking an interest in this repository. It is a personal platform
engineering project, but it is built to the standards of a shared production
codebase — which means the contribution rules below are not ceremony, they are
the reason the `main` branch stays safe to apply.

---

## ⚠️ Before anything else: this repository builds real infrastructure

Running `terraform apply` from this repository creates billable Azure
resources. Contributors do **not** need an Azure subscription to contribute —
every quality gate (`fmt`, `validate`, `tflint`, `checkov`, `conftest`) runs
entirely offline against the configuration. Only `plan` and `apply` need
credentials, and CI handles those.

If you do deploy, read [`docs/cost.md`](docs/cost.md) first and run
`make destroy-dev` when you are finished.

---

## Ground rules

1. **Nothing is applied without a plan a human has read.** The pipeline posts
   the plan to the pull request as a collapsible comment. The reviewer's job is
   to read the resources marked for *destroy* and *replace*, not just the
   additions.
2. **No secrets, ever.** No client secrets, no storage account keys, no
   connection strings, no real subscription or tenant IDs — not in code, not in
   `tfvars`, not in a test fixture, not in a screenshot. Use the placeholder
   `00000000-0000-0000-0000-000000000000`. `gitleaks` runs on every pull
   request and on a schedule; it is a safety net, not permission to be casual.
3. **Every security suppression carries a written justification.** A
   `#checkov:skip=` or a `.checkov.yml` entry without a paragraph explaining
   the risk, the compensating control, and the condition for removal will be
   rejected. See [`.checkov.yml`](.checkov.yml) for the expected format.
4. **Environment parity is deliberate, divergence is documented.** If `prod`
   differs from `dev`, the difference belongs in the environment's
   `terraform.tfvars` with an inline comment, not in bespoke module logic.

---

## Development workflow

### 1. Branch

```bash
git checkout -b feat/add-nat-gateway-flow-logs
```

Branch naming: `feat/`, `fix/`, `docs/`, `refactor/`, `chore/`, `ci/`.

### 2. Make the change

Infrastructure changes almost always touch three places. Keep them together in
one commit so the change is reviewable as a unit:

| Change | Also update |
|---|---|
| New module variable | `variables.tf` (with `description`, `type`, `validation`), the module `README.md` (regenerate with `make docs`), and every env that should set it |
| New resource in a module | `outputs.tf` if callers need a handle on it, and `policy/conftest/terraform.rego` if it is security-relevant |
| New environment-level behaviour | all three `envs/*/terraform.tfvars`, and the environment comparison table in the root `README.md` |
| New policy rule | a matching unit test in `policy/conftest/terraform_test.rego` |

### 3. Run the gates locally

```bash
make check
```

That runs, in order: `fmt-check`, `validate`, `lint`, `security` (checkov) and
`policy-test` (conftest unit tests). It is exactly what CI runs, so a green
`make check` means a green pipeline.

On Windows without `make`:

```powershell
terraform fmt -check -recursive .
.\scripts\preflight.ps1
checkov --config-file .checkov.yml
conftest verify --policy policy/conftest
```

### 4. Regenerate module documentation

Module `README.md` input/output tables are **generated**. Never hand-edit the
content between the `<!-- BEGIN_TF_DOCS -->` and `<!-- END_TF_DOCS -->`
markers — write prose outside them and run:

```bash
make docs
```

The `docs.yml` workflow will fail a pull request whose generated docs are stale.

### 5. Commit

[Conventional Commits](https://www.conventionalcommits.org/). The prefix is
what lets the change history be read at a glance months later:

```
feat(aks): add node OS upgrade maintenance window
fix(network): correct NAT gateway subnet association for the user pool
docs(adr): record the decision to use CNI overlay
refactor(keyvault): move role assignments behind for_each
ci: pin checkov-action to v12
chore(deps): bump azurerm to ~> 4.12
```

Scopes mirror the directory: `aks`, `network`, `acr`, `keyvault`, `identity`,
`observability`, `naming`, `bootstrap`, `dev`, `staging`, `prod`, `ci`, `docs`,
`policy`.

### 6. Open a pull request

Fill in the template. The **Terraform plan review checklist** is the part that
matters — in particular:

- [ ] I have read the list of resources marked for **destroy** and **replace**
- [ ] No `-target` was used to produce this plan
- [ ] Cost impact considered (`make cost-dev` / infracost comment)
- [ ] No `prevent_destroy` resource is being replaced
- [ ] Policy gates are green, or every failure has a justified suppression

---

## Terraform style

These are enforced by `terraform fmt`, `tflint` and review.

**Naming**

- `snake_case` for all Terraform identifiers (resources, variables, outputs,
  locals).
- Resource names describe the *role*, not the type: `azurerm_subnet.aks_system`,
  not `azurerm_subnet.subnet1`.
- Azure resource *names* come from the `naming` module. Do not hand-build a
  name string in a module — if the convention needs to change, it must change
  in one place.

**`for_each` over `count`**

Use `for_each` whenever the collection has stable identity. `count` keys state
by *index*, so removing the first element of a three-item list re-creates the
other two. `for_each` keys state by a string, so removing one item touches only
that item. `count` is acceptable for a boolean toggle
(`count = var.enabled ? 1 : 0`) and essentially nowhere else.

**Variables**

Every variable needs a `description` and an explicit `type`. Key inputs
(environment name, region, CIDRs, node counts, SKUs, retention days) need a
`validation` block with a message that tells the user what to do:

```hcl
variable "environment" {
  description = "Deployment environment. Drives naming, sizing and security posture."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}
```

**`locals` vs `variables`**

`variable` is the module's public interface — anything a caller should set.
`local` is derived or constant. If a caller never sets it, it is not a variable.

**`depends_on`**

Avoid it. Terraform infers ordering from references, and an explicit
`depends_on` on a module forces the whole module to be deferred, which produces
`(known after apply)` noise across unrelated resources. Reach for it only for
genuinely invisible dependencies — chiefly Azure RBAC role assignments that
must exist before a data-plane operation.

**`lifecycle`**

- `prevent_destroy` on stateful production resources (Key Vault, ACR, Log
  Analytics). It is a guardrail, not a lock: it fails the plan, which forces a
  reviewed code change.
- `ignore_changes` needs a comment saying *what* mutates the attribute out of
  band. An uncommented `ignore_changes` is a hidden drift generator.

**Tagging**

Every taggable resource is tagged from the merged `local.tags`. The required
tag set is `environment`, `project`, `owner`, `managed_by`, `cost_center` — it
is enforced by `policy/conftest/terraform.rego` and by Azure Policy, so an
untagged resource fails the pull request.

---

## Adding a module

Before you do: **do not make a module** for a single resource with no logic.
A module that wraps one `azurerm_resource_group` adds an indirection, a
versioning surface and a state address change, and buys nothing. Make a module
when it encapsulates a *decision* — a set of resources that must be configured
consistently together.

If it genuinely warrants one:

```
modules/<name>/
├── main.tf        # resources, with a `locals` block merging tags
├── variables.tf   # described, typed, validated
├── outputs.tf     # described; export IDs and names callers need
├── versions.tf    # required_version + required_providers
└── README.md      # prose + generated terraform-docs table
```

Then add it to the module catalogue table in the root `README.md`, add it to
`.github/dependabot.yml`, and call it from at least one environment.

---

## Adding a policy rule

1. Write the rule in `policy/conftest/terraform.rego`, against the *plan JSON*
   schema (`resource_changes[].change.after`), with a message that names the
   offending resource address.
2. Write at least two unit tests in `policy/conftest/terraform_test.rego`: one
   that must deny and one that must pass.
3. `make policy-test`.
4. Document it in the rules table in `policy/README.md`.

A rule without a test will be asked for one in review — an untested policy rule
is how a blocking gate silently stops blocking.

---

## Reporting a security issue

Please do not open a public issue for a security problem in this repository's
patterns or defaults. Open a GitHub security advisory, or contact the author
through the profile link on
[github.com/fakhfakhahmed](https://github.com/fakhfakhahmed).

---

## Code of conduct

Be straightforward and be kind. Critique the configuration, not the person.
Assume the author had a reason and ask what it was before asserting it is wrong
— in infrastructure code, the surprising line is usually load-bearing.

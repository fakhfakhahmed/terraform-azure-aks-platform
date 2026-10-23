# 0001 — Directory-per-environment instead of workspaces or a single parameterized root

## Status

Accepted

## Context

This platform needs three environments — dev, staging, prod — that share almost all of their
Terraform code but differ in node counts, SKUs, network isolation, policy strictness and approval
gates (see
[architecture.md — Environment topology differences](../architecture.md#environment-topology-differences)).
Three standard patterns exist for this in Terraform, and all three were considered:

1. **Terraform workspaces** (`terraform workspace new prod`) — one root module, one backend
   configuration, state partitioned by workspace name inside the same backend.
2. **A single parameterized root module** with an `environment` variable driving every
   environment-specific value, applied with different `-var-file`s but still one `main.tf` and,
   typically, one state file or a workspace-per-environment variant of it.
3. **A directory per environment** (`envs/dev`, `envs/staging`, `envs/prod`), each its own root
   module with its own `backend` block, its own state file, and its own `.tfvars`, all calling the
   same shared modules.

The three environments in this platform are not equally privileged. Prod requires two reviewer
approvals and has its destroy workflow blocked outright; dev requires none and is destroyed
routinely; staging sits in between. [Design principle #1](../architecture.md#design-principles)
states: "the environment directory is the unit of blast radius. One state file, one set of
credentials, one approval gate per environment."

## Decision

Use a directory per environment. `envs/dev/`, `envs/staging/` and `envs/prod/` are each
independent root modules with their own backend configuration (see
[state-management.md](../state-management.md)), their own state file in its own blob within the
shared storage account, and their own `.tfvars`. All three call the identical set of shared
modules (`modules/naming`, `modules/network`, `modules/aks`, `modules/identity`, `modules/keyvault`,
`modules/acr`, `modules/observability`) with different inputs — per
[design principle #5](../architecture.md#design-principles), "prod differs from dev by
configuration, not by code path."

Terraform workspaces were rejected because a workspace is a *state* partition, not a *blast-radius*
partition. All workspaces for a given root module share the same backend configuration and,
critically, the same `terraform apply` credentials and the same CI job definition unless the
workflow adds its own branching logic to tell them apart — at which point you have rebuilt
environment isolation on top of a mechanism designed for something else (cheaply testing a change
across parallel copies of the same infrastructure, e.g. ephemeral PR environments). Workspaces also
make an environment variable (`terraform.workspace`) implicit state that every module and every
`count`/`for_each` expression has to be aware of, which cuts against
[design principle #3](../architecture.md#design-principles) — a module should expose explicit
knobs, not read ambient context.

A single parameterized root with an `environment` variable was rejected for a sharper reason: it
makes it *possible*, by construction, for the same `terraform apply` invocation to touch prod
depending on which `-var-file` happens to be passed. The directory-per-environment structure makes
that mistake structurally unavailable — `terraform -chdir=envs/dev apply` cannot touch prod's
state because prod's state is not reachable from that directory's backend configuration at all.
The failure mode a parameterized root protects against with discipline (always double-check the
`-var-file` flag), directory-per-environment protects against with topology.

## Consequences

**What this buys:**

- A CI job's permissions are scoped to a single environment's directory and backend by
  construction. The GitHub Environment protection rule (see
  [ADR-0002](./0002-oidc-over-service-principal-secrets.md)) for `environment: prod` gates a token
  that is only ever used from `envs/prod`, because that is the only directory whose workflow step
  requests it.
- A reviewer looking at a pull request touching `envs/prod/main.tf` knows, without reading any
  other file, the full blast radius of that change: it is prod's resources and nothing else.
  `envs/dev/main.tf` carries no such weight.
- `prevent_destroy` on stateful prod resources ([design principle #5](../architecture.md#design-principles))
  is a difference in `.tf` code between `envs/prod` and the other two directories — acceptable
  because it is the *one* documented structural exception, not the general pattern.
- Each environment's state file is small and fast to plan against; there is no risk of a dev
  `plan` enumerating prod resources because they were never in the same state to begin with.

**What this costs:**

- Shared logic that is not expressible as a module input has to be copied across three
  `envs/<env>/main.tf` files, or extracted into a module. In practice this has not been a problem
  because [design principle #3](../architecture.md#design-principles) already pushes real logic
  into `modules/*`, leaving the environment roots as thin composition — see
  [architecture.md — Module composition](../architecture.md#module-composition).
- Adding a new environment means creating a new directory, a new backend key, and a new GitHub
  Environment, rather than adding one line to a map. This is an explicit cost accepted in exchange
  for the isolation above: a new environment *should* require a deliberate, reviewed setup step,
  not a one-line diff that can be merged without anyone registering that a new blast-radius
  boundary just came into existence.
- `terraform init` has to be run (or `-reconfigure`d) separately per environment directory. This is
  a minor ergonomic cost relative to workspaces, documented in
  [state-management.md](../state-management.md), and is paid once per environment setup rather
  than per `apply`.

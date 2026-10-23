# 0002 — GitHub OIDC federated credentials over a service-principal client secret

## Status

Accepted

## Context

CI needs to authenticate to Azure to run `terraform plan` and `terraform apply`. The conventional,
still extremely common approach is `az ad sp create-for-rbac --sdk-auth`, which creates a service
principal and prints a JSON blob containing a client secret, pasted once into a GitHub Actions
secret and referenced from every workflow thereafter.

[`bootstrap/github-oidc.tf`](../../bootstrap/github-oidc.tf) documents, in its header comment,
exactly what that approach costs:

- the secret is a **bearer credential** — whoever holds it *is* the service principal, from
  anywhere on the internet, until someone notices it was taken;
- it expires on a schedule nobody reliably tracks, and breaks deployments at the worst possible
  time when it does;
- it gets copied into forks, local `.env` files, screenshots, and support tickets, because that is
  what portable secrets do when humans handle them;
- a compromise leaves no distinguishing signal in the audit log — the login looks exactly like a
  legitimate one, because credential-wise, it is.

GitHub Actions can instead mint a short-lived OIDC ID token describing the exact job that is
running — which repository, which branch or GitHub Environment, which workflow — and Entra ID
federated identity credentials can be configured to trust that token for a specific application,
*without Entra ever holding or issuing a secret of its own* to GitHub.

## Decision

Use GitHub OIDC with Entra ID federated identity credentials
(`azuread_application_federated_identity_credential`), as implemented in
[`bootstrap/github-oidc.tf`](../../bootstrap/github-oidc.tf). No `azuread_application_password` or
equivalent secret resource exists anywhere in this repository, for any identity.

The mechanics, matched exactly against three JWT claims (`iss`, `aud`, `sub`), are diagrammed in
[architecture.md section 2](../architecture.md#2-github-oidc-to-azure-authentication-flow). The
decisive design choice inside that implementation is pinning the federated credential's `subject`
to GitHub's `environment:<name>` subject form rather than a branch name: a job only receives a
token carrying `sub = repo:<org>/<repo>:environment:prod` once GitHub's environment protection
rules (required reviewers, wait timers, allowed branches) have already admitted it. The approval
gate is therefore enforced **at token issuance**, inside GitHub's own infrastructure, rather than
by an `if:` condition in workflow YAML that anyone with write access to the repository could edit
around. You cannot obtain a prod-capable Azure token without first passing the prod approval gate,
regardless of what the workflow file says — a property a secret-based service principal cannot
replicate, because a static secret authorises the holder unconditionally, forever, until rotated.

Separately, repository values like `AZURE_CLIENT_ID` and `AZURE_TENANT_ID` are stored as GitHub
**variables**, not secrets — see
[architecture.md — Why repository variables, not secrets](../architecture.md#why-repository-variables-not-secrets).
They are public identifiers; masking them in CI logs provides no security benefit and actively
degrades debuggability.

## Consequences

**What this buys:**

- There is no long-lived Azure credential in GitHub's secret store, a developer's shell history, a
  `.env` file, or a CI log, for the Terraform-apply identity. A leaked repository or a compromised
  contributor account gives an attacker nothing by itself, because the credential is bound to
  GitHub's own assertion about where and under what approval the code is running.
- Revocation is structural rather than procedural: deleting the federated credential (or the
  GitHub Environment's protection rule) immediately and completely removes the trust relationship.
  There is no secret to rotate across every consumer, because there never was one.
- The `pull_request` federated credential subject is not issued by GitHub for forked-repository
  pull requests, which means an external contributor opening a PR cannot obtain any Azure token at
  all — a property that has to be built by hand (checking `github.event.pull_request.head.repo.fork`
  everywhere) when the trigger is a static secret available to any workflow run.
- Azure's `azure/login@v2` action and `azurerm`'s own OIDC support need zero custom code to consume
  this — it is a first-class, maintained integration, not a bespoke token-exchange script.

**What this costs:**

- The security boundary moves from "a secret exists or it doesn't" to "the `iss`/`sub`/`aud` triple
  matches exactly" — a subtler failure mode. A subject string typo produces an opaque
  `AADSTS70021: No matching federated identity record found` with no further detail, and this is,
  by a wide margin, the most common setup failure recorded in
  [getting-started.md — Troubleshooting](../getting-started.md#aadsts70021-no-matching-federated-identity-record-found).
  The comparison procedure to diagnose it is documented there because the error message alone does
  not point at the fix.
- OIDC federation only works for identities that can present a trusted, Entra-verifiable token —
  GitHub Actions, and a growing but still limited set of other platforms. A script run from a
  developer's laptop, or a third-party CI system without OIDC support, cannot use this mechanism
  and falls back to interactive `az login` (see [architecture.md — Data flows](../architecture.md#data-flows),
  flow 1), which is fine for a human but is not a substitute for automated pipelines.
- Azure limits an application to 20 federated identity credentials. This platform uses 5 (one
  branch, one pull-request, three environments) — comfortably under the limit, but the limit is
  the documented signal to split into per-environment application registrations if this platform
  ever needs many more environments or workflows than it does today
  ([`bootstrap/github-oidc.tf`](../../bootstrap/github-oidc.tf) comment on `federated_credentials`).

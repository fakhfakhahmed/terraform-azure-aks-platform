# ---------------------------------------------------------------------------
# TFLint configuration
# ---------------------------------------------------------------------------
# TFLint catches a class of problems that `terraform validate` cannot:
#   - provider-specific errors (an invalid VM SKU name, a malformed resource
#     name) that would otherwise only surface after a 10-minute apply,
#   - style and maintainability issues (undocumented variables, unused
#     declarations, unpinned module sources),
#   - deprecated syntax left behind by provider major upgrades.
#
# It is a BLOCKING gate in .github/workflows/terraform-plan.yml. Linting is
# cheap and runs before anything touches Azure, so it is the cheapest possible
# place to fail.
#
# Run locally:
#   tflint --init          # downloads the plugins declared below (once)
#   tflint --recursive --format compact
# ---------------------------------------------------------------------------

config {
  # Evaluate variables so rules can see their actual values. Without this,
  # rules that depend on variable defaults produce false negatives.
  call_module_type = "all"

  # Fail the run when the configuration itself is malformed rather than
  # silently linting nothing.
  force = false
}

# ---------------------------------------------------------------------------
# Plugins
# ---------------------------------------------------------------------------

plugin "terraform" {
  enabled = true
  # The bundled ruleset ships with TFLint; "recommended" turns on the
  # opinionated style/correctness rules rather than just the error-level ones.
  preset = "recommended"
}

plugin "azurerm" {
  enabled = true
  version = "0.27.0"
  source  = "github.com/terraform-linters/tflint-ruleset-azurerm"
}

# ---------------------------------------------------------------------------
# Core Terraform rules
# ---------------------------------------------------------------------------

# Every variable must carry a description. Modules are a public interface;
# an undocumented input is an undocumented API.
rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

# An untyped variable accepts anything, which defers the error from plan time
# to apply time -- exactly backwards.
rule "terraform_typed_variables" {
  enabled = true
}

# Enforce snake_case for resource/variable/output names so the codebase reads
# consistently and matches HashiCorp's own style guide.
rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}

# Catch leftovers after refactoring.
rule "terraform_unused_declarations" {
  enabled = true
}

rule "terraform_unused_required_providers" {
  enabled = true
}

# Require a required_providers block with version constraints in every module.
# Unpinned providers are how a Monday-morning CI run breaks for no reason.
rule "terraform_required_providers" {
  enabled = true
}

rule "terraform_required_version" {
  enabled = true
}

# Enforce the canonical file layout (main.tf / variables.tf / outputs.tf).
rule "terraform_standard_module_structure" {
  enabled = true
}

# `terraform fmt` compliance. Also checked separately in CI, but failing here
# gives a better error message with the exact file and line.
rule "terraform_deprecated_interpolation" {
  enabled = true
}

rule "terraform_deprecated_index" {
  enabled = true
}

rule "terraform_deprecated_lookup" {
  enabled = true
}

rule "terraform_comment_syntax" {
  enabled = true
}

# Local modules are referenced by relative path in this repo, so the
# "pin module source" rule would fire on every call. It is disabled here with
# a justification rather than left silently off.
#
# JUSTIFICATION: all module sources in this repository are relative local
# paths ("../../modules/aks"), which are versioned by the repository commit
# itself -- the module and its caller always move together. The rule exists
# for remote registry/git sources, which this repo does not use. If a module
# is ever extracted to its own registry entry, re-enable this immediately.
rule "terraform_module_pinned_source" {
  enabled = false
}

rule "terraform_module_version" {
  enabled = false
}

# ---------------------------------------------------------------------------
# azurerm ruleset
# ---------------------------------------------------------------------------
# The azurerm plugin's rules are enabled by its own defaults (invalid SKU
# names, invalid resource names, exceeding API length limits, deprecated
# arguments after the v4 major bump). They are left at defaults deliberately:
# hand-disabling provider correctness rules is how real bugs get shipped.
#
# The two below are called out explicitly because they are the ones most
# likely to fire on this codebase and are genuinely wanted.

rule "azurerm_kubernetes_cluster_invalid_name" {
  enabled = true
}

rule "azurerm_container_registry_invalid_name" {
  enabled = true
}

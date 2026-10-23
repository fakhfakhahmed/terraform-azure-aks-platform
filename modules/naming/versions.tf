# =============================================================================
# modules/naming/versions.tf
# =============================================================================
# This module is pure HCL -- string interpolation and lookups only, no
# resources and no provider calls. It therefore does not declare a
# `required_providers` block: doing so would force every caller to configure
# an azurerm provider just to compute a name, which is both unnecessary and a
# needless coupling (a future `modules/aws-naming` sibling, or a unit test
# harness, should be able to call this module with zero provider setup).
#
# The `required_version` floor is still declared and still matters: the
# cross-variable `validation` blocks in variables.tf (comparing `var.prefix`
# length against `var.environment` or similar derived checks) rely on
# Terraform >= 1.9's support for referencing other variables inside a
# validation condition.
# =============================================================================

terraform {
  required_version = ">= 1.9.0"
}

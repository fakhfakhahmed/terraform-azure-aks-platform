# =============================================================================
# terraform-azure-aks-platform -- developer entrypoint
# =============================================================================
# Every target here is a thin, auditable wrapper around the same commands CI
# runs. The point is that there is exactly ONE way to plan and apply this
# stack, whether a human or a pipeline is driving it.
#
# COST SAFETY: `apply-*` and `destroy-*` create and delete real, billable Azure
# resources. `apply-prod` is additionally guarded behind a typed confirmation
# and `destroy-prod` is refused outright. Nothing in CI calls these targets
# without passing a GitHub Environment approval gate first. See docs/cost.md.
#
# Windows note: this Makefile assumes a POSIX shell (Git Bash, WSL, or the
# `sh.exe` bundled with Git for Windows). If you do not have `make`, the
# PowerShell scripts under scripts/ provide the same operations natively --
# they are the primary interface on Windows and this Makefile is the parity
# copy, not the other way around.
# =============================================================================

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
TF              ?= terraform
ENVS            := dev staging prod
BACKEND_CONFIG  := backend.hcl
PLAN_FILE       ?= tfplan
TF_INIT_FLAGS   ?= -input=false
TF_PLAN_FLAGS   ?= -input=false -lock-timeout=5m
TF_APPLY_FLAGS  ?= -input=false -lock-timeout=5m

# ANSI colours. Defined with plain escapes rather than `tput` so the Makefile
# behaves identically under Git Bash on Windows, where TERM is often unset and
# tput is not on PATH. NO_COLOR=1 disables them (https://no-color.org).
ifdef NO_COLOR
  BOLD  :=
  RED   :=
  GREEN :=
  YEL   :=
  CYAN  :=
  RESET :=
else
  BOLD  := \033[1m
  RED   := \033[31m
  GREEN := \033[32m
  YEL   := \033[33m
  CYAN  := \033[36m
  RESET := \033[0m
endif

.PHONY: help
help: ## Show this help
	@printf "\n$(BOLD)terraform-azure-aks-platform$(RESET)\n"
	@printf "Modular, multi-environment Azure landing zone for AKS.\n\n"
	@printf "$(BOLD)Usage:$(RESET) make $(CYAN)<target>$(RESET)\n\n"
	@printf "$(BOLD)Quality gates$(RESET) (what CI runs on every pull request)\n"
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| grep -E '^(fmt|fmt-check|validate|lint|security|policy-test|docs|check):' \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  $(CYAN)%-18s$(RESET) %s\n", $$1, $$2}'
	@printf "\n$(BOLD)Bootstrap$(RESET) (run once per subscription)\n"
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| grep -E '^bootstrap-' \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  $(CYAN)%-18s$(RESET) %s\n", $$1, $$2}'
	@printf "\n$(BOLD)Per-environment$(RESET) (ENV is one of: $(ENVS))\n"
	@printf "  $(CYAN)%-18s$(RESET) %s\n" "init-ENV"    "terraform init with the env backend config"
	@printf "  $(CYAN)%-18s$(RESET) %s\n" "plan-ENV"    "terraform plan (read-only, nothing is applied)"
	@printf "  $(CYAN)%-18s$(RESET) %s\n" "policy-ENV"  "run conftest against the saved plan"
	@printf "  $(CYAN)%-18s$(RESET) %s\n" "output-ENV"  "show the environment outputs"
	@printf "  $(CYAN)%-18s$(RESET) %s\n" "connect-ENV" "fetch AKS credentials into kubeconfig"
	@printf "  $(YEL)%-18s$(RESET) %s\n"  "apply-ENV"   "APPLY the environment (BILLABLE)"
	@printf "  $(YEL)%-18s$(RESET) %s\n"  "destroy-ENV" "DESTROY the environment"
	@printf "\n$(BOLD)Other$(RESET)\n"
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| grep -E '^(preflight|cost-dev|clean|help):' \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  $(CYAN)%-18s$(RESET) %s\n", $$1, $$2}'
	@printf "\n$(YEL)Billable targets:$(RESET) apply-dev apply-staging apply-prod destroy-*\n"
	@printf "$(YEL)Run 'make destroy-dev' when you are finished experimenting.$(RESET)\n\n"

# =============================================================================
# Quality gates -- the exact checks CI runs on every pull request.
# =============================================================================

.PHONY: fmt
fmt: ## Rewrite all Terraform files to canonical format
	@printf "$(BOLD)==> terraform fmt (write)$(RESET)\n"
	@$(TF) fmt -recursive .

.PHONY: fmt-check
fmt-check: ## Verify formatting without writing (CI gate)
	@printf "$(BOLD)==> terraform fmt -check$(RESET)\n"
	@$(TF) fmt -check -recursive -diff .

.PHONY: validate
validate: ## terraform validate every env and every module
	@printf "$(BOLD)==> terraform validate$(RESET)\n"
	@set -e; \
	for d in bootstrap $(addprefix envs/,$(ENVS)) modules/*; do \
		if [ -f "$$d/versions.tf" ]; then \
			printf "  --> %s\n" "$$d"; \
			$(TF) -chdir="$$d" init -backend=false $(TF_INIT_FLAGS) >/dev/null; \
			$(TF) -chdir="$$d" validate -no-color; \
		fi; \
	done
	@printf "$(GREEN)validate: OK$(RESET)\n"

.PHONY: lint
lint: ## Run tflint across the repository
	@printf "$(BOLD)==> tflint$(RESET)\n"
	@command -v tflint >/dev/null 2>&1 || { \
		printf "$(RED)tflint not found.$(RESET) Install: https://github.com/terraform-linters/tflint\n"; exit 1; }
	@tflint --init
	@tflint --recursive --format compact
	@printf "$(GREEN)lint: OK$(RESET)\n"

.PHONY: security
security: ## Run the checkov static security gate
	@printf "$(BOLD)==> checkov$(RESET)\n"
	@command -v checkov >/dev/null 2>&1 || { \
		printf "$(RED)checkov not found.$(RESET) Install: pip install checkov\n"; exit 1; }
	@checkov --config-file .checkov.yml
	@printf "$(GREEN)checkov: OK$(RESET)\n"

.PHONY: policy-test
policy-test: ## Run the OPA/conftest policy unit tests
	@printf "$(BOLD)==> conftest verify$(RESET)\n"
	@command -v conftest >/dev/null 2>&1 || { \
		printf "$(RED)conftest not found.$(RESET) Install: https://www.conftest.dev/install/\n"; exit 1; }
	@conftest verify --policy policy/conftest
	@printf "$(GREEN)policy-test: OK$(RESET)\n"

.PHONY: docs
docs: ## Regenerate module READMEs with terraform-docs
	@printf "$(BOLD)==> terraform-docs$(RESET)\n"
	@command -v terraform-docs >/dev/null 2>&1 || { \
		printf "$(RED)terraform-docs not found.$(RESET) See https://terraform-docs.io/user-guide/installation/\n"; exit 1; }
	@terraform-docs --config .terraform-docs.yml ./modules
	@printf "$(GREEN)docs: regenerated$(RESET)\n"

.PHONY: check
check: fmt-check validate lint security policy-test ## Run every gate CI runs
	@printf "$(GREEN)$(BOLD)All gates passed.$(RESET)\n"

# =============================================================================
# Bootstrap -- creates the remote state backend and the GitHub OIDC identity.
# Run ONCE per subscription, by a human, with LOCAL state.
# See bootstrap/README.md for the chicken-and-egg explanation.
# =============================================================================

.PHONY: bootstrap-init
bootstrap-init: ## terraform init the bootstrap stack (local state)
	@$(TF) -chdir=bootstrap init $(TF_INIT_FLAGS)

.PHONY: bootstrap-plan
bootstrap-plan: ## Plan the bootstrap stack
	@$(TF) -chdir=bootstrap plan $(TF_PLAN_FLAGS) -out=$(PLAN_FILE)

.PHONY: bootstrap-apply
bootstrap-apply: ## Apply the bootstrap stack (state account + Entra OIDC app)
	@printf "$(YEL)This creates a storage account and an Entra ID application.$(RESET)\n"
	@$(TF) -chdir=bootstrap apply $(TF_APPLY_FLAGS)
	@printf "\n$(BOLD)Backend configuration for envs/<env>/backend.hcl:$(RESET)\n"
	@$(TF) -chdir=bootstrap output -raw backend_config_hcl
	@printf "\n\n$(BOLD)GitHub repository variables to set:$(RESET)\n"
	@$(TF) -chdir=bootstrap output -raw github_variables_cli

# =============================================================================
# Per-environment targets
# =============================================================================
# Generated from a single template so dev/staging/prod are byte-identical in
# behaviour. Any difference between environments lives in the Terraform code,
# never in the tooling -- that is the whole point of directory-per-environment
# (see docs/decisions/0001-directory-per-environment.md).
#
# `apply-*` is deliberately NOT generated here: production needs a stronger
# guard than a template can express, and an operator should never be able to
# apply prod by muscle memory.
# =============================================================================

define ENV_TARGETS

.PHONY: init-$(1)
init-$(1):
	@if [ ! -f "envs/$(1)/$$(BACKEND_CONFIG)" ]; then \
		printf "$$(RED)Missing envs/$(1)/$$(BACKEND_CONFIG)$$(RESET)\n"; \
		printf "Copy envs/$(1)/backend.hcl.example and fill in the values from\n"; \
		printf "the bootstrap outputs, or run: make bootstrap-apply\n"; \
		exit 1; \
	fi
	@printf "$$(BOLD)==> init $(1)$$(RESET)\n"
	@$$(TF) -chdir=envs/$(1) init -reconfigure $$(TF_INIT_FLAGS) -backend-config=$$(BACKEND_CONFIG)

.PHONY: plan-$(1)
plan-$(1):
	@printf "$$(BOLD)==> plan $(1)$$(RESET)\n"
	@$$(TF) -chdir=envs/$(1) plan $$(TF_PLAN_FLAGS) -out=$$(PLAN_FILE)
	@printf "$$(GREEN)Plan written to envs/$(1)/$$(PLAN_FILE). Nothing has been applied.$$(RESET)\n"

.PHONY: show-$(1)
show-$(1):
	@$$(TF) -chdir=envs/$(1) show -json $$(PLAN_FILE)

.PHONY: policy-$(1)
policy-$(1):
	@$$(TF) -chdir=envs/$(1) show -json $$(PLAN_FILE) > envs/$(1)/tfplan.json
	@conftest test --policy policy/conftest envs/$(1)/tfplan.json

.PHONY: output-$(1)
output-$(1):
	@$$(TF) -chdir=envs/$(1) output

.PHONY: connect-$(1)
connect-$(1):
	@bash scripts/connect-aks.sh $(1)

.PHONY: cost-$(1)
cost-$(1):
	@bash scripts/cost-estimate.sh $(1)

endef

$(foreach e,$(ENVS),$(eval $(call ENV_TARGETS,$(e))))

# -----------------------------------------------------------------------------
# apply-* / destroy-* -- written out explicitly, with escalating guards.
# -----------------------------------------------------------------------------

.PHONY: apply-dev
apply-dev: ## Apply the dev environment (BILLABLE)
	@printf "$(YEL)Applying dev. This creates billable Azure resources.$(RESET)\n"
	@printf "$(YEL)Run 'make destroy-dev' when you are finished.$(RESET)\n"
	@$(TF) -chdir=envs/dev apply $(TF_APPLY_FLAGS)

.PHONY: apply-staging
apply-staging: ## Apply the staging environment (BILLABLE)
	@printf "$(YEL)Applying staging. This creates billable Azure resources.$(RESET)\n"
	@$(TF) -chdir=envs/staging apply $(TF_APPLY_FLAGS)

.PHONY: apply-prod
apply-prod: ## Apply production -- requires a typed confirmation (BILLABLE)
	@printf "\n$(RED)$(BOLD)============================================================$(RESET)\n"
	@printf "$(RED)$(BOLD)  PRODUCTION APPLY$(RESET)\n"
	@printf "$(RED)$(BOLD)============================================================$(RESET)\n\n"
	@printf "Applying production from a workstation bypasses the GitHub\n"
	@printf "Environment approval gate, the plan-on-PR review and the audit\n"
	@printf "trail. The sanctioned path is:\n\n"
	@printf "    gh workflow run terraform-apply.yml -f environment=prod\n\n"
	@printf "This target exists only as a documented break-glass procedure.\n\n"
	@read -r -p "Type 'apply-prod' to continue: " confirm; \
	if [ "$$confirm" != "apply-prod" ]; then \
		printf "$(GREEN)Aborted. Nothing was changed.$(RESET)\n"; \
		exit 1; \
	fi; \
	printf "$(RED)Proceeding with production apply...$(RESET)\n"; \
	$(TF) -chdir=envs/prod apply $(TF_APPLY_FLAGS)

.PHONY: destroy-dev
destroy-dev: ## DESTROY every resource in the dev environment
	@printf "$(RED)$(BOLD)This destroys all dev infrastructure.$(RESET)\n"
	@$(TF) -chdir=envs/dev destroy $(TF_APPLY_FLAGS)

.PHONY: destroy-staging
destroy-staging: ## DESTROY every resource in the staging environment
	@printf "$(RED)$(BOLD)This destroys all staging infrastructure.$(RESET)\n"
	@read -r -p "Type 'destroy-staging' to continue: " confirm; \
	if [ "$$confirm" != "destroy-staging" ]; then \
		printf "$(GREEN)Aborted.$(RESET)\n"; exit 1; \
	fi; \
	$(TF) -chdir=envs/staging destroy $(TF_APPLY_FLAGS)

.PHONY: destroy-prod
destroy-prod: ## Blocked. Production teardown is a deliberate manual operation.
	@printf "$(RED)$(BOLD)Refusing to destroy production from a Makefile target.$(RESET)\n\n"
	@printf "Production carries prevent_destroy lifecycle blocks on the Key Vault,\n"
	@printf "the container registry and the Log Analytics workspace, so this would\n"
	@printf "fail partway through and leave the environment half-dismantled.\n\n"
	@printf "If teardown is genuinely intended, do it deliberately:\n"
	@printf "  1. Remove the prevent_destroy blocks in a reviewed pull request.\n"
	@printf "  2. Run the plan and have a second engineer read it.\n"
	@printf "  3. terraform -chdir=envs/prod destroy\n"
	@exit 1

# =============================================================================
# Convenience
# =============================================================================

.PHONY: preflight
preflight: ## Check required tooling is installed and you are logged in
	@bash scripts/preflight.sh

.PHONY: cost-dev
cost-dev: ## Estimate the monthly cost of the dev environment (infracost)
	@bash scripts/cost-estimate.sh dev

.PHONY: clean
clean: ## Remove local plan artefacts and provider caches
	@printf "$(BOLD)==> cleaning local artefacts$(RESET)\n"
	@find . -type d -name ".terraform" -prune -exec rm -rf {} + 2>/dev/null || true
	@find . -type f \( -name "tfplan" -o -name "tfplan.json" -o -name "tfdestroy" -o -name "plan.txt" \) -delete 2>/dev/null || true
	@printf "$(GREEN)clean: done$(RESET)\n"
	@printf "$(YEL)This removes LOCAL files only. Azure and remote state are untouched.$(RESET)\n"

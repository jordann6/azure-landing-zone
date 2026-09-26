TF ?= terraform
CHEAP_FLAGS := -var enable_firewall=false -var enable_bastion=false -var enable_private_endpoints=false

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  %-14s %s\n", $$1, $$2}'

# ---- static gates (same as CI, credential-free) ----------------------------

.PHONY: fmt
fmt: ## Terraform format check
	$(TF) -chdir=$(TF) fmt -check -recursive || terraform fmt -check -recursive terraform

.PHONY: validate
validate: ## Terraform init (no backend) + validate
	terraform -chdir=terraform init -backend=false && terraform -chdir=terraform validate

.PHONY: diagram
diagram: ## Regenerate docs/architecture.png
	python3 docs/diagram.py

# ---- deploy / test / destroy ----------------------------------------------
# Two-step deploy so the free governance/identity/logging/Key Vault layer stands
# up first and the HOURLY network layer (Azure Firewall + Bastion) is a separate,
# explicitly confirmed step. Azure Firewall bills ~$1.25/hr and Bastion ~$0.19/hr.
#
# These targets use interactive apply. Through the `!` bash line (no interactive
# prompts) run the same commands with -auto-approve and ABSOLUTE -chdir paths,
# e.g. terraform -chdir=/Users/jordannelson/azure-landing-zone/terraform apply \
#   -auto-approve $(CHEAP_FLAGS)  (see README "Deploy").

.PHONY: deploy
deploy: ## Stand up the FREE layer: MGs, Deny policies, CIS, identity, logging, Key Vault CMK
	@echo "==> az login / az account set must be done first."
	@echo "==> Set deployer_ip_cidrs to your public IP so the CMK can be created."
	terraform -chdir=terraform init
	terraform -chdir=terraform apply $(CHEAP_FLAGS)

.PHONY: deploy-network
deploy-network: ## Add the HOURLY layer: Azure Firewall + forced-egress UDR + Bastion + private endpoints
	@echo "==> HOURLY resources: Azure Firewall (~\$$1.25/hr) + Bastion (~\$$0.19/hr)."
	@echo "==> Projected demo-window cost is a few dollars; torn down by 'make destroy'."
	terraform -chdir=terraform apply

.PHONY: test
test: ## Prove the guardrails actually deny, not just that apply succeeded
	scripts/test-guardrails.sh

.PHONY: destroy
destroy: ## Tear everything down, then verify nothing hourly survives
	@echo "==> Azure Firewall and any Gateway take 10-30 min to delete; the RG goes last."
	terraform -chdir=terraform destroy
	@echo "==> Verifying teardown"
	scripts/verify-teardown.sh

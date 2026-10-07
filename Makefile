TF ?= terraform
CHEAP_FLAGS := -var enable_firewall=false -var enable_bastion=false -var enable_private_endpoints=false -var enable_fortigate=false

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  %-14s %s\n", $$1, $$2}'

# ---- static gates (same as CI, credential-free) ----------------------------

.PHONY: fmt
fmt: ## Terraform format check
	terraform fmt -check -recursive terraform
	terraform fmt -check -recursive workload
	terraform fmt -check -recursive portal
	terraform fmt -check -recursive compute
	terraform fmt -check -recursive bootstrap
	terraform fmt -check -recursive observability
	terraform fmt -check -recursive secrets

.PHONY: validate
validate: ## Terraform init (no backend) + validate, all seven roots
	terraform -chdir=terraform init -backend=false && terraform -chdir=terraform validate
	terraform -chdir=workload init -backend=false && terraform -chdir=workload validate
	terraform -chdir=portal init -backend=false && terraform -chdir=portal validate
	terraform -chdir=compute init -backend=false && terraform -chdir=compute validate
	terraform -chdir=bootstrap init -backend=false && terraform -chdir=bootstrap validate
	terraform -chdir=observability init -backend=false && terraform -chdir=observability validate
	terraform -chdir=secrets init -backend=false && terraform -chdir=secrets validate

.PHONY: diagram
diagram: ## Regenerate docs/architecture.png, workload-architecture.png, portal-architecture.png
	python3 docs/diagram.py
	python3 docs/workload.py
	python3 docs/portal.py

# ---- state backend (standing, never part of destroy) -------------------------
# bootstrap/ owns the storage account every root keeps state in. One-time move
# off the shared backend: bootstrap-state, apply the saved plan, migrate-state.

.PHONY: bootstrap-state
bootstrap-state: ## Saved plan for the hardened state backend (first apply runs against the old backend)
	scripts/migrate-state-backend.sh plan-bootstrap

.PHONY: migrate-state
migrate-state: ## Move every root's state into the new backend; fails on any resource-count mismatch
	scripts/migrate-state-backend.sh migrate

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

# Run before any host-encrypted VM or AKS deployment:
# ! az feature register --namespace Microsoft.Compute --name EncryptionAtHost
# ! az provider register --namespace Microsoft.Compute
.PHONY: compute-prereqs
compute-prereqs: ## Register the host-encryption subscription feature (no hourly resources)
	az feature register --namespace Microsoft.Compute --name EncryptionAtHost
	az provider register --namespace Microsoft.Compute

.PHONY: build-image
build-image: ## Bake the pinned baseline into the gallery; always remove build exemptions
	python3 scripts/build-image.py

.PHONY: deploy-compute test-compute destroy-compute
deploy-compute: ## Deploy only the private management VM from the gallery (hourly)
	python3 scripts/deploy-compute.py

test-compute: ## Prove the golden-image hardening on the live management VM
	scripts/test-compute.sh

destroy-compute: ## Destroy the management VM before its hub and gallery
	terraform -chdir=compute init -input=false
	terraform -chdir=compute plan -destroy -out=tfplan -input=false
	terraform -chdir=compute apply -input=false tfplan

.PHONY: deploy-network
deploy-network: ## Add the HOURLY layer: Azure Firewall + forced-egress UDR + Bastion + private endpoints
	@echo "==> HOURLY resources: Azure Firewall (~\$$1.25/hr) + Bastion (~\$$0.19/hr)."
	@echo "==> Projected demo-window cost is a few dollars; torn down by 'make destroy'."
	terraform -chdir=terraform apply

.PHONY: deploy-workload
deploy-workload: ## Prod paved road (HOURLY): private AKS + CMK etcd/disk + PostgreSQL HA + ACR, landing in prod 10.3
	@echo "==> Requires the base landing zone deployed WITH the hourly firewall (the egress path)."
	@echo "==> HOURLY: AKS nodes + PostgreSQL zone-redundant HA + ACR Premium (~\$$0.85/hr on top of the base)."
	@echo "==> Set deployer_ip_cidrs in workload/terraform.tfvars first (cp workload/example.tfvars ...)."
	terraform -chdir=workload init
	terraform -chdir=workload apply

.PHONY: deploy-portal
deploy-portal: ## Member portal (HOURLY): Front Door Premium + WAF, Container Apps x2 regions, SQL failover group, APIM, Logic App, External ID
	@echo "==> Requires the base landing zone applied with the portal policy carve-outs (ops_action_group_id output)."
	@echo "==> HOURLY: Front Door Premium (~\$$0.45/hr) + 2x SQL serverless + 2x Container Apps + APIM Consumption."
	terraform -chdir=portal init
	terraform -chdir=portal apply
	@echo "==> Next: scripts/portal-approve-private-links.sh, then scripts/portal-build-image.sh"

.PHONY: portal-smoke
portal-smoke: ## End-to-end portal check through Front Door, WAF, and APIM
	scripts/portal-smoke.sh

.PHONY: destroy-portal
destroy-portal: ## Tear down the member portal (run scripts/portal-external-id.ps1 -Teardown first)
	terraform -chdir=portal destroy

.PHONY: test
test: ## Prove the guardrails actually deny, not just that apply succeeded
	scripts/test-guardrails.sh

.PHONY: deploy-observability test-observability destroy-observability
deploy-observability: ## Control-plane change alerts + Defender findings export (free; needs the base deployed)
	terraform -chdir=observability init
	terraform -chdir=observability apply

test-observability: ## Prove the change alerts exist and fire (creates and deletes one NSG)
	scripts/test-observability.sh

destroy-observability: ## Remove the change alerts and findings export before the base
	terraform -chdir=observability init -input=false
	terraform -chdir=observability destroy

.PHONY: deploy-secrets test-secrets destroy-secrets
deploy-secrets: ## Secrets scanner identity (Key Vault Reader, metadata only), near-expiry alert, positive-control secret (free; needs the base)
	terraform -chdir=secrets init
	terraform -chdir=secrets apply

test-secrets: ## Prove metadata-only access, the seeded finding, the 403 on a value read, and the near-expiry alert
	scripts/test-secrets.sh

destroy-secrets: ## Remove the scanner identity, alert and control secret before the base
	terraform -chdir=secrets init -input=false
	terraform -chdir=secrets destroy

.PHONY: test-flow-logs
test-flow-logs: ## Prove VNet flow logs are configured and delivering (needs enable_flow_logs and time for analytics lag)
	scripts/test-flow-logs.sh

.PHONY: destroy-workload
destroy-workload: ## Tear down the prod workload paved road (AKS, PostgreSQL, ACR, backup) before the base
	@echo "==> A protected Backup vault can block deletion until retention clears; preserve recovery data and retry afterward."
	terraform -chdir=workload destroy

.PHONY: destroy
destroy: ## Tear down compute, workload and base, then verify even after a failure
	scripts/destroy-session.sh

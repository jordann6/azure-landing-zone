# Bespoke modules vs the Azure Landing Zone accelerator

This landing zone is built from bespoke Terraform modules, not the Microsoft
Azure Landing Zone (ALZ) accelerator or the ready-made Azure Verified Modules
(AVM) `terraform-azurerm-caf-enterprise-scale`. That is a deliberate choice, and
here is the reasoning.

## What the accelerator would give

The ALZ accelerator / AVM enterprise-scale module ships the whole Cloud Adoption
Framework hierarchy, dozens of built-in policy assignments, and connectivity and
management subscriptions in one large module. In a real enterprise with a
subscription-vending platform and a team to own it, that is the right call: you
inherit Microsoft's maintained policy set and get to production faster.

## Why bespoke here

1. **It is a portfolio artifact meant to be read.** Every management group, every
   Deny policy, and every network route in this repo is a resource I wrote and can
   explain line by line. A 2,000-line vendored module hides the decisions behind a
   variable file. The point of this project is to show the reasoning, not to prove
   I can set `enable = true`.
2. **Cost-bounded, deploy/destroy posture.** The accelerator assumes standing
   subscriptions and always-on connectivity. This zone is built to stand up, prove
   its guardrails, and be destroyed under a fixed budget, with every hourly
   resource behind a flag. That posture is easier to guarantee when I control the
   graph directly.
3. **Single-subscription reality.** Without an EA/MCA to vend subscriptions, the
   accelerator's subscription-per-archetype model does not apply cleanly. The
   bespoke version maps the same tiers onto management groups + resource groups and
   documents the intended subscription split (see `access-model.md`).
4. **One shared CI toolkit across three clouds.** The AWS, Azure, and GCP zones in
   this portfolio all wire into the same `platform-guardrails` reusable workflows.
   Bespoke Terraform keeps the three repos structurally parallel, which a
   cloud-specific accelerator would break.

## What I would change for production

At real scale I would adopt the AVM enterprise-scale module for the hierarchy and
the maintained policy baseline, keep these bespoke modules only for the parts that
are genuinely custom (the network inspection design, the CMK wiring, the CI
integration), and let a subscription-vending pipeline replace the single-sub
resource-group tiering. The design in this repo is deliberately close to the
accelerator's shape so that migration is additive, not a rewrite.

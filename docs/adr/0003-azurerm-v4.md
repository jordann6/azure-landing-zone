# ADR-0003: Move all roots to azurerm 4.x

- **Status:** accepted (code changed, live applies pending)
- **Date:** 2026-10-06

## Context

VNet-scoped flow logs, planned as the next parity item, need azurerm 4.x. Every root
was pinned `~> 3.100` (locked at 3.117.1).

## Decision

Pin `~> 4.0` in bootstrap, terraform (and its landing-zone module), workload and compute.

## Changes the upgrade required

| Where | v3 | v4 |
|-------|----|----|
| ACR | `encryption.enabled`, `retention_policy {}`, `trust_policy {}` | `enabled` removed, `retention_policy_in_days`, `trust_policy_enabled` |
| AKS | `node_os_channel_upgrade`, `automatic_channel_upgrade` | `node_os_upgrade_channel`, `automatic_upgrade_channel` |
| AKS | `enable_host_encryption` | `host_encryption_enabled` |
| AKS | `api_server_access_profile.vnet_integration_enabled` | `virtual_network_integration_enabled` |
| AKS | AAD RBAC `managed = true` | `managed` removed, `tenant_id` now required |
| Key Vault | `enable_rbac_authorization` | `rbac_authorization_enabled` |
| Activity log alert | `location` optional | `location = "global"` required |
| State storage account | `cross_tenant_replication_enabled` defaulted true | defaults false, now set explicitly |

## Verification

- `terraform validate` passes on all four roots.
- `bootstrap` is the only root with live state. Its plan under v4 is one in-place
  change (`cross_tenant_replication_enabled` true to false), which is the intended
  hardening for the state account. Under v3 the same plan was clean.
- `terraform`, `workload` and `compute` have empty state, so their plans are pure
  creates and cannot prove zero drift. The first deploy-demo-destroy session is the
  real test of the v4 renames.
- `workload` plans only after the base is deployed with `enable_firewall = true`.

## Known follow-ups

- `azurerm_monitor_diagnostic_setting` `metric` blocks are deprecated for
  `enabled_metric` (removal in v5). Warnings only.

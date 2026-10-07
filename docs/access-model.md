# Access model

Human identity for this landing zone: least-privilege persona groups bound at
management-group scope, so access inherits down the tier tree, with no standing
write to Prod. Implemented in `terraform/identity.tf`.

## Persona-by-scope matrix

| Persona (Entra group) | Scope | Role | Standing? | CIS control satisfied |
|---|---|---|---|---|
| `lz-admin` | root MG | Owner | Yes (break-glass-adjacent) | 1.x privileged access is inventoried and scoped |
| `lz-platform-eng` | Workloads MG | Contributor | Yes (non-prod) | 1.x least privilege by scope |
| `lz-platform-eng` | Prod MG | Reader (standing) + Contributor (PIM-eligible) | No standing prod write | 1.x just-in-time elevation, no standing prod write |
| `lz-junior-eng` | Dev MG | Reader | Yes | 1.x least privilege by scope |
| `lz-manager` | root MG | Reader | Yes | 1.x read-only oversight |
| `lz-finops` | root MG | Cost Management Reader | Yes | 10.x cost visibility without infra rights |
| `lz-security` | root MG | Security Reader | Yes | 2.x security oversight without write |
| `lz-break-glass` | root MG | Owner | Sealed (emergency only) | 1.x break-glass account, MFA, monitored |

## Just-in-time to Prod

`lz-platform-eng` holds only **Reader** at the Prod management group as a standing
grant. Write access to Prod is a **PIM-eligible** Contributor assignment
(`azurerm_pim_eligible_role_assignment.prod_write`): an engineer activates it
through Privileged Identity Management for a time-bound, approver-gated window,
and it expires automatically. There is no permanent Contributor or Owner on Prod
below the admin/break-glass tier.

## Intended subscription-per-tier design (not the demo)

The portfolio design is one subscription per tier under the management-group
hierarchy:

- **Platform MG**: management, connectivity, and identity subscriptions.
- **Workloads MG**: dev, test, and prod subscriptions (Prod governed more
  strictly by inherited policy).
- **Sandbox MG**: an isolated subscription.

This demo runs in a **single subscription** because there is no EA/MCA agreement
to vend subscriptions. The tiers are therefore represented by management groups
plus resource groups. Policy, RBAC and the CIS initiative attach at MG scope exactly
as they would with real subscriptions, but the one subscription sits under the
Workloads group, so only root and Workloads assignments reach it. The Dev, Test,
Prod and Sandbox assignments (including Prod's single-region policy and its
Reader plus PIM-eligible Contributor split) are wired with nothing beneath them,
so in this demo they are code, not enforcement. Resource groups separate the
tiers' resources but carry no tier policy. Moving to
real subscriptions is a matter of creating them and associating each to its MG;
no policy or identity code changes.

## Demo-tenant limits (honest)

Creating Entra groups needs tenant Graph permissions, and PIM needs an Entra ID
P2 license. Where the demo tenant lacks either, set `create_entra_identity = false`
(and `enable_pim = false`); the persona-by-scope design above still stands as the
documented target, and the rest of the landing zone deploys unchanged.

This deployment ran on a tenant with **no Entra ID P2**, so it was applied with
`enable_pim = false`: the seven persona groups and their MG-scoped RBAC are live,
but the JIT-to-Prod eligible assignment (`azurerm_pim_eligible_role_assignment.prod_write`)
was not created. The Prod row above therefore describes the target model, not a
standing assignment in this run.

# Member portal (`portal/`)

A member-facing workload that lands on the landing zone, built from the stack a
pharmacy cooperative actually runs rather than from Kubernetes: Front Door with
WAF, Container Apps in two regions, Azure SQL with a failover group, API
Management for partners, Entra External ID for member sign-in, a Logic App
integration, and Application Insights. It inherits everything from the base:
the management group policies, the central Log Analytics workspace, and the ops
action group.

## The request path

```
member ──HTTPS──▶ Front Door Premium (WAF: Default Rule Set 2.1, Bot Manager, per-IP rate limit)
                    │  health-probes /health in both regions every 30s
                    │  priority 1 = centralus, priority 2 = eastus2
                    ▼  Private Link (managed private endpoint, approved on the environment)
                  Container Apps environment (internal VIP, public network access disabled, no public IP)
                    │  app checks X-Azure-FDID = this Front Door profile
                    ▼  managed identity token (no password)
                  SQL failover group listener ──▶ current primary server (private endpoint, Entra-only auth)

partner ──key──▶ API Management (Consumption, rate limit) ──▶ Front Door ──▶ same path
Logic App (daily 6:00 CT) ──▶ Front Door /api/reports/daily
```

## Failover runs on two clocks

Stateless traffic and stateful data fail over at different speeds, so they are
handled separately and neither depends on the other.

- **The fast clock is Front Door.** It probes `/health` in each region every 30
  seconds. When the primary stops answering, traffic moves to the secondary
  within a few probe intervals. `scripts/portal-failover-drill.sh app` measures it.
- **The slow clock is the database.** The SQL failover group keeps a geo-secondary
  in eastus2 and publishes one read-write listener. Both regions' apps always
  connect to that listener, so when the primary database moves, the app tier
  follows without a config change. Automatic failover waits a 60-minute grace
  period (the minimum, to avoid flapping on a short blip); a planned failover is
  immediate. `scripts/portal-failover-drill.sh data` measures RTO and RPO.

## Decisions and trade-offs

| Decision | Why | Trade-off |
|---|---|---|
| Front Door **Premium** | Private Link origins and managed WAF rule sets are Premium-only. Lets the origin have no public ingress at all. | About $330/month base, billed hourly. Fine for deploy-demo-destroy; Standard plus an origin header check is the budget alternative. |
| **Container Apps**, internal, public access disabled | No public IP, so the base deny-public-IP policy holds without an exception. App Service would be the more familiar choice, but this subscription has zero App Service VM quota and Container Apps does not draw on it. | Approving the Front Door private endpoint is a separate step (script). |
| `azapi` for the environment, the origins, and External ID | azurerm 3.x has no `publicNetworkAccess` on the environment, rejects `managedEnvironments` as a Private Link target (tested), and has no External ID resource. | Two providers instead of one; azapi bodies are less type-checked. |
| **Named** Container Apps infrastructure resource groups | The platform creates them without our tags, so the base tag policies would deny them. Naming them lets the base exclude exactly those two groups from the tag rules, nothing else. | A list to keep in sync between `portal/` and `terraform/variables.tf`. |
| **Failover group listener** from both regions | The app never needs to know which database is primary. | Cross-region writes when the app and the primary are in different regions (a few ms of latency). |
| SQL **Entra-only**, app identity is the admin | No SQL login or password exists anywhere, including Terraform state. | The app holds admin on its own database. Production would create a contained user with read/write roles from a deployment job inside the VNet. |
| Data resource group tagged **phi** | The base policy then denies public network access on the SQL servers, so the classification enforces the control. | None; `public_network_access_enabled = false` is set explicitly so the policy passes. |
| API Management **Consumption** | Provisions in minutes, bills per call. | No VNet integration, so APIM reaches the backend through the public Front Door endpoint. Standard v2 with VNet integration is the production path. |
| **External ID** in its own tenant | Members are customers, not employees; keeps them out of the workforce directory. | The app registration and user flow live inside that tenant, so they are set up with Microsoft Graph PowerShell, not Terraform. |
| Front Door header check in the app | Defense in depth if the app is ever exposed another way. | Probes use `/livez`, the one path exempt from the check. |

## Observability

Everything lands in the base workspace (`log-alz-central`): Front Door access,
health-probe, and WAF logs; Container Apps logs; SQL audit events; Logic App run
history; Application Insights requests and dependencies.

| Alert | Fires when |
|---|---|
| Availability | The `/health` test fails from 2+ of 5 US locations |
| SLO fast burn | The last hour's availability failure rate is more than 14.4x the 0.1% error budget (99.9% SLO) |
| Front Door 5xx | More than 5% of requests return 5xx over 5 minutes |
| Origin health | A region fails Front Door health probes (fires during a failover, on purpose) |
| SQL failover | The failover group switches primary |
| Restarts | A region's app restarts more than 3 times in 15 minutes |
| WAF blocks | More than 100 blocked requests in 15 minutes |

The **Member portal operations** workbook shows availability by location, edge
traffic by status code, WAF blocks by rule, Deny policy events, and SQL failover
history on one page.

## Deploy

Credentialed steps run locally, plan before apply.

1. **Base carve-outs.** Apply `terraform/` so the External ID location exception,
   the named infrastructure-RG exclusions, and the `ops_action_group_id` output
   exist.
2. **Portal infrastructure.** `make deploy-portal` (copy `portal/example.tfvars`
   to `portal/terraform.tfvars` first). Starts on Microsoft's quickstart image.
3. **Approve Private Link.** `scripts/portal-approve-private-links.sh`.
4. **Build the app.** `scripts/portal-build-image.sh`, put the printed
   `app_image` in tfvars, re-apply.
5. **Member sign-in.** `pwsh scripts/portal-external-id.ps1`, put the printed
   `external_id_client_id` in tfvars, re-apply.
6. **Prove it.** `make portal-smoke`, then `scripts/portal-failover-drill.sh app`
   and `scripts/portal-failover-drill.sh data` (add `--failback` to move back).

## Cost

Roughly $1.50 to $2 per hour while up: Front Door Premium is most of it, then
two serverless SQL databases (the geo-secondary bills too), two Container Apps,
and small amounts for APIM calls, availability tests, and logs. External ID is
free under 50,000 monthly active users. A two-hour demo stays inside the
portfolio's single-digit-dollar ceiling.

## Destroy

1. `pwsh scripts/portal-external-id.ps1 -Teardown` (an External ID tenant cannot
   be deleted while it still holds the app and user flow).
2. `make destroy-portal`.

## Honest gaps

- **Not deployed yet.** Everything above is written and passes static checks;
  the drill numbers come from running it.
- **No hub egress inspection for the portal.** The portal VNets are not peered
  to the hub or routed through Azure Firewall; Container Apps forced egress
  needs its own firewall allowlist, a follow-up.
- **SQL admin breadth** (see the table).
- **APIM backend over the public Front Door endpoint** (Consumption tier).
- **Defender for SQL and vulnerability assessment** are paid plans, off.

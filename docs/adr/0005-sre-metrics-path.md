# ADR-0005: SLO metrics on managed Prometheus, dashboards on in-cluster Grafana

- **Status:** accepted
- **Date:** 2026-10-29

## Context

The SRE demo needs a request-level SLI for `slo-demo`, multiwindow burn-rate alerts
that page, and a dashboard to work the incident from. The cluster is private, with
local accounts off and every egress through the hub firewall. Sessions run for
hours and are then destroyed, so anything standing costs money for nothing. The
page has to fire even if the cluster is the thing that broke.

## Decision

1. **Managed Prometheus** (the `ama-metrics` add-on) scrapes the app's
   ServiceMonitor and remote-writes to an **Azure Monitor workspace** through a data
   collection endpoint and rule (`workload/sre-monitoring.tf`).
2. **Recording and alert rules run in the workspace** as Prometheus rule groups,
   bound to the base landing zone's `ag-<project>-ops` action group. Sev 1 is a page,
   Sev 3 a ticket; both deliver by email today ([slo.md](../slo.md)).
3. **Grafana runs in the cluster**, reconciled by Flux (`gitops/apps/grafana`), with
   the Azure Prometheus data source baked into a pinned image and a workload identity
   that holds only Monitoring Data Reader on the workspace and Secrets User on its
   own admin password.

## Alternatives rejected

| Option | Why not |
| ------ | ------- |
| Prometheus and Alertmanager in the cluster | Rules and paging would die with the cluster they watch, and the TSDB is one more stateful workload to back up. Off-cluster rule evaluation is the point. |
| Container Insights metrics and KQL log alerts | The SLI is a ratio of counters across windows. PromQL expresses that directly; the KQL equivalent is slower to evaluate and harder to read in a runbook. |
| Azure Managed Grafana | A separate billed resource and another identity and network path to manage for a stack that lives for hours. Self-hosted was the deliberate choice; it also shows the workload identity and Key Vault CSI pattern on one more consumer. |

## Consequences

- Grafana has no public endpoint. Viewing it takes Bastion Standard and the
  management VM ([grafana-access.md](../runbooks/grafana-access.md)). The SLO proofs
  do not depend on the UI: `scripts/drill-slo.sh` checks the data source and runs
  the dashboard's queries through Grafana's API and the workspace directly.
- The workspace query endpoint and ingestion depend on firewall rules. On
  2026-10-29 ingestion matched the broad AzureCloud network rule; it now matches the
  documented `AzureMonitor:443` rule. The second 2026-10-29 session confirmed it:
  2,025 connections on that rule, and ingestion, Container Insights and Policy
  all healthy.
- Proven 2026-10-29: 50% fault injected at 17:02:36, `SloFastBurn` fired at
  17:08:04 (evaluated 0.077 against 0.072), page email received by 17:10, resolved
  at 17:23:02 after the fault was removed.
- Revisit if the alerting needs routing beyond email (on-call rotation, paging
  service): that is an action group change, not a metrics path change.

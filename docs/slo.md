# slo-demo availability SLO

The service is `slo-demo` in the private AKS cluster (`gitops/apps/slo-demo`).
The rules live in `workload/sre-monitoring.tf` as Azure Monitor Prometheus rule
groups; the dashboard is `gitops/apps/grafana/dashboards/slo-demo.json`.

## SLI

The share of requests that did not fail on the server:

```
sum(rate(slo_demo_requests_total{namespace="slo-demo",code_class!="5xx"}[w]))
/
sum(rate(slo_demo_requests_total{namespace="slo-demo"}[w]))
```

- **Counted:** every request to the user routes (`/`, `/api/work`, and anything
  else, which collapses to one `other` label).
- **Not counted:** `/healthz`, `/readyz` and `/metrics`. The app does not
  instrument them, so probes and scrapes cannot pad the good side of the ratio.
- **Bad:** status 500 and above. A 4xx is the client's problem and is not budget
  spend.
- **Labels are bounded:** `route` has three values and `code_class` five, so
  cardinality is fixed whatever the traffic looks like.

The recording rules store the bad side, `slo:errors:ratio_rate<w>`, for w in 5m,
30m, 1h and 6h, plus `slo:requests:rate<w>`.

## Objective

**99.5% of requests succeed, over a rolling 30 days.** The error budget is 0.5%
of requests: at a steady 20 rps (51.8 million requests in 30 days), about
259,000 failed requests.

## Alerts

Multiwindow, multi-burn-rate, from chapter 5 of the Google SRE workbook. A burn
rate of 1 spends exactly the budget in 30 days.

| Alert | Condition | Severity | Means |
|---|---|---|---|
| `SloFastBurn` | 1h and 5m error ratio both over 14.4 x 0.5% = 7.2% | Sev 1, page | 2% of the month's budget gone in an hour |
| `SloSlowBurn` | 6h and 30m both over 6 x 0.5% = 3% | Sev 3, ticket | 5% of the budget gone in six hours |
| `SloNoTraffic` | request rate over 5m is zero (or absent) | Sev 3, ticket | the ratio is undefined; not a healthy reading |
| `SloTargetsDown` | no slo-demo scrape target up at any point in 3m | Sev 1, page | burn-rate alerts cannot fire without data |

The long window says the burn is real; the short window makes the alert stop
soon after recovery instead of an hour later. No rule uses `for`: the pairs do
not need it, and the two data-presence rules carry their hold time in the range
vector.

**Page and ticket today are both email** from `ag-<project>-ops` in the base
landing zone. Severity is the distinction, and the Azure Monitor alert history
(fired and resolved timestamps, alert ID) is the receipt. A real ticket
integration is a later addition.

## Missing data is not healthy

A ratio over zero requests has no value, and `rate()` over a dead target returns
nothing, so a burn-rate rule over missing data simply never fires. That is why
the two guards exist: no traffic is a ticket, no live target is a page.

## What the one-hour drill can and cannot show

The drill cannot show a 30-day objective being met. It shows the alerting path
working end to end: an injected failure crosses the fast-burn threshold, the page
arrives, the runbook finds the cause, and the alert resolves after recovery.

Time to fire depends on how long healthy traffic ran first, because the 1h window
has to average above 7.2%. With T minutes of healthy traffic before injecting
failure rate f, the 1h ratio crosses when f x t / (T + t) > 0.072, which for
f = 25% is t > 0.4 x T. Ten minutes of baseline gives about four minutes, plus
one or two evaluation intervals and alert delivery. `scripts/drill-slo.sh`
injects 25% by default and records the time to fire.

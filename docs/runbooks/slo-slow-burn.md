# Runbook: SloSlowBurn (Sev 3, ticket)

**Symptom.** The 5xx ratio is over 3% on both the 6h and 30m windows. Not an
emergency: at this rate the budget lasts about five days. Work it in hours.

1. Find when it started: the Burn rate panel's 6h line, or
   `slo:errors:ratio_rate6h` over the last day.
2. Line the start up with the Flux revision history and rollouts (see
   `slo-fast-burn.md`, check 3) and with node events.
3. Look for a pattern: one route, one pod or one node (`sum by (pod)` of
   `rate(slo_demo_requests_total{code_class="5xx"}[30m])`).

Typical causes are a partial regression, one unhealthy node, or a dependency
erroring intermittently. Fix through Git as for the fast burn, then confirm the
30m window drops below 3%. Escalate if budget spend continues past one business day.

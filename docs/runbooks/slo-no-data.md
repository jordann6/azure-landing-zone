# Runbook: SloNoTraffic and SloTargetsDown

**Symptom.** `SloNoTraffic` (Sev 3): zero requests in 5 minutes, so the error
ratio is undefined. `SloTargetsDown` (Sev 1): no slo-demo scrape target has been
up in 3 minutes. Neither is a healthy reading: the burn-rate alerts cannot fire
without data, so silence here would hide a full outage.

1. **Is the app running?**
   `k "kubectl get deploy,pods -n slo-demo"` (see `slo-fast-burn.md` for `k`).
2. **Is traffic arriving?** The load generator:
   `k "kubectl logs deploy/slo-loadgen -n slo-demo --tail=5"` (it logs sent and
   failed counts every 30s).
3. **Is the scraper running and seeing the target?**
   `k "kubectl get pods -n kube-system -l rsName=ama-metrics"` and
   `k "kubectl get servicemonitors.azmonitoring.coreos.com -n slo-demo"`. The
   ServiceMonitor must use the `azmonitoring.coreos.com` group; the managed
   collector ignores the OSS `monitoring.coreos.com` one.
4. **Is ingestion blocked?** ama-metrics remote-writes through the hub firewall.
   Denies show in Log Analytics:
   `AZFWApplicationRule | where TimeGenerated > ago(30m) | where Action == "Deny" | summarize count() by Fqdn`.

Fix the broken link (scale the app or load generator back through Git, restart
ama-metrics, add a missing FQDN to `rcg-aks-addons` in Terraform), then confirm
`up{namespace="slo-demo"}` is 1 for each pod and the request rate is nonzero.

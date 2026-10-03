# Saved KQL queries

Investigation queries for the central Log Analytics workspace
(`log-alz-central`). The alerts in `terraform/alerts.tf` fire on the first three;
these are what you run next.

| File | Answers |
|---|---|
| `policy-denies.kql` | What did the Deny policies block, and who tried it? |
| `keyvault-forbidden.kql` | Which identity was refused a secret or key, from where? |
| `firewall-denies.kql` | What did the hub firewall block, from which source? |
| `who-changed-what.kql` | Who created, changed, or deleted what this week? |
| `bastion-sessions.kql` | Who connected through Bastion, to which VM, and for how long? |

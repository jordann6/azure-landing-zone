# gitops/

Reconciled by the managed Flux extension (`workload/sre-gitops.tf`). Three
kustomizations, each with one owner:

| Kustomization | Path | Owns |
|---|---|---|
| `infra` | `gitops/infra` | `slo-demo` and `observability` namespaces, the `cmk-disk` StorageClass |
| `apps` | `gitops/apps` | slo-demo Deployment, Service, PDB, ServiceMonitor, load generator; Grafana |
| `data` | `gitops/data` | `slo-data` namespace, Postgres StatefulSet, writer, secret provider class |

`data` owns its own namespace on purpose: the restore drill suspends only that
kustomization, so Flux cannot recreate `slo-data` while AKS Backup restores it.

Values that exist only after `terraform apply` (`${ACR_LOGIN_SERVER}`,
`${KEY_VAULT_NAME}`, identity client IDs, the workspace query endpoint) are filled
by Flux post-build substitution. ConfigMaps that carry Grafana syntax (`$__...`)
are annotated `kustomize.toolkit.fluxcd.io/substitute: disabled`, because
substitution would otherwise blank those tokens.

Not in Git on purpose: the `slo-demo-fault` ConfigMap. `scripts/drill-slo.sh`
creates and deletes it to inject failure, and Flux leaves it alone because Flux
does not own it.

Images are pinned by digest in `apps/kustomization.yaml` and
`data/kustomization.yaml`. After the `SRE demo images` workflow runs, set them
with `scripts/sre-pin-images.sh`.

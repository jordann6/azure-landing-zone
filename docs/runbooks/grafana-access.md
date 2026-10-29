# Viewing the in-cluster Grafana

Grafana runs in `observability` behind an internal load balancer in the prod
VNet. There is no public IP, and the AKS API is private, so `kubectl
port-forward` from a laptop is not available. The path is the same one an
operator uses for any private admin UI: Bastion to the hub management VM, then an
SSH port forward over the peering.

Needs `bastion_sku = "Standard"` in `terraform/terraform.tfvars` (native-client
tunneling; Basic is browser-only) and the management VM (`make deploy-compute`).
Bastion IP-based tunnels cannot target a non-VM IP on a custom port, which is why
the hop goes through the VM.

```bash
source scripts/sre-lib.sh && load_outputs   # kx: runCommand REST, see slo-fast-burn.md
ILB=$(kx "kubectl get svc grafana -n observability -o jsonpath='{.status.loadBalancer.ingress[0].ip}'" | tail -1)
VM_ID=$(az vm show -g rg-alz-compute -n vm-alz-mgmt --query id -o tsv)
az network bastion ssh -n bas-alz-hub -g rg-alz-hub --target-resource-id "$VM_ID" \
  --auth-type ssh-key --username lzadmin --ssh-key ~/.ssh/alz-mgmt-session -- -L 3000:"$ILB":80
```

Then open http://localhost:3000 and sign in as `admin`. The password is in Key
Vault secret `grafana-admin-password`; read it with the operator's own access, it
is never printed by the scripts.

`make deploy-compute` discards the VM's SSH key after the apply. For a session
that uses this path, keep it with
`KEEP_SSH_KEY=~/.ssh/alz-mgmt-session make deploy-compute`, and delete that file
at teardown. The key is unique to the session's VM, which is destroyed with it.

None of the SLO proofs depend on this view: `scripts/drill-slo.sh` checks the
data source and dashboard through Grafana's API and runs the dashboard's queries
directly. The UI is for screenshots and for working the incident by eye.

# AKS required egress, allowed on the hub firewall. A private AKS cluster with
# outbound_type=userDefinedRouting sends all egress to the hub Azure Firewall, and
# it cannot provision (nodes cannot reach the control plane, MCR, or AKS packages)
# unless the firewall permits AKS's required destinations. This is the Azure analog
# of the AWS "hub firewall domain allowlist" that fronts the private EKS cluster.
#
# This rule collection group attaches to the base landing zone's firewall policy
# (published as firewall_policy_id), so the hub still owns the firewall while the
# workload contributes only the egress its cluster needs. The AzureKubernetesService
# FQDN tag covers the required HTTPS FQDNs; the network rules cover the tunnel/NTP.

resource "azurerm_firewall_policy_rule_collection_group" "aks_egress" {
  name               = "rcg-aks-egress"
  firewall_policy_id = local.fw_policy_id
  priority           = 400

  application_rule_collection {
    name     = "allow-aks-egress"
    priority = 400
    action   = "Allow"

    rule {
      name                  = "aks-required-fqdns"
      source_addresses      = [var.prod_cidr]
      destination_fqdn_tags = ["AzureKubernetesService"]

      protocols {
        type = "Https"
        port = 443
      }
      protocols {
        type = "Http"
        port = 80
      }
    }
  }

  network_rule_collection {
    name     = "allow-aks-network"
    priority = 410
    action   = "Allow"

    rule {
      name                  = "aks-tunnel-and-api"
      source_addresses      = [var.prod_cidr]
      destination_addresses = ["AzureCloud.${var.location}"]
      destination_ports     = ["1194", "9000", "443"]
      protocols             = ["TCP", "UDP"]
    }

    rule {
      name                  = "aks-ntp"
      source_addresses      = [var.prod_cidr]
      destination_addresses = ["*"]
      destination_ports     = ["123"]
      protocols             = ["UDP"]
    }
  }
}

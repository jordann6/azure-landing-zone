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

# Egress for the add-ons this cluster always runs, which the AzureKubernetesService
# FQDN tag does not cover (learn.microsoft.com/azure/aks/outbound-rules-control-egress):
# Container Insights and the Azure Monitor agent (oms_agent), and the Azure Policy
# add-on (azure_policy_enabled). Until these existed nothing on the firewall
# explicitly allowed those destinations; the live session checks whether the
# add-ons were reporting before and after.
resource "azurerm_firewall_policy_rule_collection_group" "aks_addons" {
  name               = "rcg-aks-addons"
  firewall_policy_id = local.fw_policy_id
  priority           = 410

  application_rule_collection {
    name     = "allow-aks-addons"
    priority = 410
    action   = "Allow"

    rule {
      name             = "azure-monitor"
      source_addresses = [var.prod_cidr]
      destination_fqdns = [
        "*.ods.opinsights.azure.com",
        "*.oms.opinsights.azure.com",
        "dc.services.visualstudio.com",
        "*.monitoring.azure.com",
        "login.microsoftonline.com",
        "global.handler.control.monitor.azure.com",
        "*.ingest.monitor.azure.com",
        "*.metrics.ingest.monitor.azure.com",
        "${var.location}.handler.control.monitor.azure.com",
      ]
      protocols {
        type = "Https"
        port = 443
      }
    }

    rule {
      name              = "azure-policy"
      source_addresses  = [var.prod_cidr]
      destination_fqdns = ["data.policy.core.windows.net", "store.policy.core.windows.net"]
      protocols {
        type = "Https"
        port = 443
      }
    }
  }

  # Azure rejects concurrent writes to one firewall policy.
  depends_on = [azurerm_firewall_policy_rule_collection_group.aks_egress]
}

# SRE demo egress, on with enable_sre_demo: the Flux extension and its Git source,
# the in-cluster Grafana's queries to the Azure Monitor workspace, and (with
# enable_aks_backup) the AKS Backup extension's documented destinations. Backup
# blob traffic itself goes to the private endpoint in sre-backup.tf.
resource "azurerm_firewall_policy_rule_collection_group" "sre" {
  count              = local.sre_count
  name               = "rcg-aks-sre-demo"
  firewall_policy_id = local.fw_policy_id
  priority           = 420

  application_rule_collection {
    name     = "allow-sre-demo"
    priority = 420
    action   = "Allow"

    rule {
      name             = "cluster-extensions"
      source_addresses = [var.prod_cidr]
      destination_fqdns = [
        "${var.location}.dp.kubernetesconfiguration.azure.com",
        "mcr.microsoft.com",
        "*.data.mcr.microsoft.com",
        "*.ingestion.msftcloudes.com",
        "*.microsoftmetrics.com",
      ]
      protocols {
        type = "Https"
        port = 443
      }
    }

    # Flux source-controller clones the public repo over HTTPS.
    rule {
      name              = "flux-git-source"
      source_addresses  = [var.prod_cidr]
      destination_fqdns = ["github.com"]
      protocols {
        type = "Https"
        port = 443
      }
    }

    # Grafana's PromQL queries go to the workspace query endpoint.
    rule {
      name              = "grafana-prometheus-query"
      source_addresses  = [var.prod_cidr]
      destination_fqdns = ["*.prometheus.monitor.azure.com"]
      protocols {
        type = "Https"
        port = 443
      }
    }

    dynamic "rule" {
      for_each = local.backup_count == 1 ? [1] : []
      content {
        name             = "aks-backup-extension"
        source_addresses = [var.prod_cidr]
        # The extension's documented list, verbatim
        # (learn.microsoft.com/azure/backup/azure-kubernetes-service-cluster-backup-concept).
        # It includes broad wildcards. The session runs with the full list, then
        # AZFWApplicationRule logs from the run show which names were actually
        # used, and the list is narrowed to those.
        destination_fqdns = [
          "*.microsoft.com",
          "mcr.microsoft.com",
          "data.mcr.microsoft.com",
          "crl.microsoft.com",
          "mscrl.microsoft.com",
          "oneocsp.microsoft.com",
          "*.azure.com",
          "management.azure.com",
          "gcs.prod.monitoring.core.windows.net",
          "*.prod.warm.ingest.monitor.core.windows.net",
          "*.blob.core.windows.net",
          "*.azmk8s.io",
          "ocsp.digicert.com",
          "cacerts.digicert.com",
          "crl3.digicert.com",
          "crl4.digicert.com",
          "ocsp.digicert.cn",
          "cacerts.digicert.cn",
          "cacerts.geotrust.com",
          "cdp.geotrust.com",
          "status.geotrust.com",
          "ocsp.msocsp.com",
          "*.azurecr.io",
          "docker.io",
          "*.dp.kubernetesconfiguration.azure.com",
        ]
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
  }

  depends_on = [azurerm_firewall_policy_rule_collection_group.aks_addons]
}

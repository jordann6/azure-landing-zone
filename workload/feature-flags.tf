# Feature flags for the optional layers. Postgres and its backup chain moved
# behind enable_postgres; the moved blocks keep existing state addresses, so a
# deploy with the flag on plans no replacement.

locals {
  pg_count     = var.enable_postgres ? 1 : 0
  sre_count    = var.enable_sre_demo ? 1 : 0
  backup_count = var.enable_sre_demo && var.enable_aks_backup ? 1 : 0

  # Namespaces the GitOps tree creates. The stateful one is separate so the
  # restore drill can delete and recover it without touching the app or Grafana.
  app_namespace  = "slo-demo"
  data_namespace = "slo-data"
  obs_namespace  = "observability"
}

moved {
  from = azurerm_user_assigned_identity.pg
  to   = azurerm_user_assigned_identity.pg[0]
}
moved {
  from = azurerm_role_assignment.pg_kms
  to   = azurerm_role_assignment.pg_kms[0]
}
moved {
  from = azurerm_private_dns_zone.pg
  to   = azurerm_private_dns_zone.pg[0]
}
moved {
  from = azurerm_private_dns_zone_virtual_network_link.pg
  to   = azurerm_private_dns_zone_virtual_network_link.pg[0]
}
moved {
  from = random_password.pg
  to   = random_password.pg[0]
}
moved {
  from = azurerm_key_vault_secret.pg_admin
  to   = azurerm_key_vault_secret.pg_admin[0]
}
moved {
  from = azurerm_postgresql_flexible_server.prod
  to   = azurerm_postgresql_flexible_server.prod[0]
}
moved {
  from = azurerm_postgresql_flexible_server_database.app
  to   = azurerm_postgresql_flexible_server_database.app[0]
}
moved {
  from = azurerm_monitor_diagnostic_setting.pg
  to   = azurerm_monitor_diagnostic_setting.pg[0]
}
moved {
  from = azurerm_role_assignment.backup_pg
  to   = azurerm_role_assignment.backup_pg[0]
}
moved {
  from = random_uuid.backup_instance
  to   = random_uuid.backup_instance[0]
}
moved {
  from = azapi_resource.backup_instance
  to   = azapi_resource.backup_instance[0]
}

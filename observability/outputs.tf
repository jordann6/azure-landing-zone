output "change_alert_names" {
  description = "Control-plane change alerts created in the logging resource group."
  value       = sort([for a in azurerm_monitor_activity_log_alert.change : a.name])
}

output "findings_export_enabled" {
  description = "Whether Defender for Cloud continuous export into the central workspace is on."
  value       = var.enable_findings_export
}

# Copy to terraform.tfvars (gitignored). Defaults deploy everything on the
# Microsoft quickstart image; after scripts/portal-build-image.sh, set app_image
# to the image it prints and re-apply. After scripts/portal-external-id.ps1,
# set external_id_client_id and re-apply.
# App tier regions (Container Apps) and data tier regions (Azure SQL) are set
# independently by capacity; see variables.tf.
primary_location       = "westus2"
secondary_location     = "eastus2"
sql_primary_location   = "centralus"
sql_secondary_location = "westus2"
# app_image             = "acralzportalxxxxx.azurecr.io/portal:<sha>"
# external_id_client_id = "00000000-0000-0000-0000-000000000000"
enable_apim        = true
enable_external_id = true

# APIM publisher email (required, no default).
alert_email = "you@example.com"

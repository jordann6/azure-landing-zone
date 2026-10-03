# Copy to terraform.tfvars (gitignored). Defaults deploy everything on the
# Microsoft quickstart image; after scripts/portal-build-image.sh, set app_image
# to the image it prints and re-apply. After scripts/portal-external-id.ps1,
# set external_id_client_id and re-apply.
primary_location   = "centralus"
secondary_location = "eastus2"
# app_image             = "acralzportalxxxxx.azurecr.io/portal:<sha>"
# external_id_client_id = "00000000-0000-0000-0000-000000000000"
enable_apim        = true
enable_external_id = true

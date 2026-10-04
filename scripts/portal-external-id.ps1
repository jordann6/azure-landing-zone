#Requires -Version 7
<#
.SYNOPSIS
  Set up member sign-in inside the Entra External ID tenant the portal created.

.DESCRIPTION
  Terraform creates the External ID tenant (an ARM resource). The app
  registration and the sign-up/sign-in user flow live inside that tenant's
  directory, so they are created here with Microsoft Graph PowerShell:

    1. App registration "Member Portal" (single-page app, redirect = portal URL)
    2. Its service principal
    3. A self-service sign-up/sign-in user flow (email + password, collects
       display name) with the app attached

  Idempotent: re-running finds the existing app and flow. -Teardown removes
  both, which must happen before Terraform can delete the tenant.

.EXAMPLE
  ./scripts/portal-external-id.ps1
  ./scripts/portal-external-id.ps1 -Teardown
#>
[CmdletBinding()]
param(
    [switch] $Teardown
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$appName = 'Member Portal'
$flowName = 'Member sign-up and sign-in'

function Get-TfOutput([string] $name) {
    (terraform -chdir="$root/portal" output -raw $name).Trim()
}

if (-not (Get-Module -ListAvailable Microsoft.Graph.Applications)) {
    Write-Host '==> Installing Microsoft.Graph modules for the current user'
    Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Applications -Scope CurrentUser -Force
}
Import-Module Microsoft.Graph.Authentication, Microsoft.Graph.Applications

$tenantId = Get-TfOutput 'external_id_tenant_id'
$portalUrl = Get-TfOutput 'portal_url'
if (-not $tenantId) { throw 'external_id_tenant_id is empty. Deploy portal/ with enable_external_id = true first.' }

Write-Host "==> Connecting to External ID tenant $tenantId (sign in with the account that created it)"
Connect-MgGraph -TenantId $tenantId -NoWelcome -Scopes @(
    'Application.ReadWrite.All',
    'EventListener.ReadWrite.All'
)

$app = Get-MgApplication -Filter "displayName eq '$appName'" | Select-Object -First 1
$flows = (Invoke-MgGraphRequest -Method GET -Uri 'v1.0/identity/authenticationEventsFlows').value |
    Where-Object { $_.displayName -eq $flowName }

if ($Teardown) {
    foreach ($flow in $flows) {
        Invoke-MgGraphRequest -Method DELETE -Uri "v1.0/identity/authenticationEventsFlows/$($flow.id)"
        Write-Host "  deleted user flow $($flow.id)"
    }
    if ($app) {
        Remove-MgApplication -ApplicationId $app.Id
        Write-Host "  deleted app registration $($app.AppId)"
    }
    Write-Host 'Done. Terraform can now destroy the External ID tenant.'
    return
}

# 1. App registration: a public single-page app using auth code + PKCE, so
#    there is no client secret to store.
if (-not $app) {
    $app = New-MgApplication -DisplayName $appName -SignInAudience 'AzureADMyOrg' -Spa @{
        RedirectUris = @($portalUrl)
    }
    Write-Host "  created app registration $($app.AppId)"
} else {
    Update-MgApplication -ApplicationId $app.Id -Spa @{ RedirectUris = @($portalUrl) }
    Write-Host "  app registration exists ($($app.AppId)); redirect URI refreshed"
}

# 2. Service principal (so users can sign in to the app in this tenant).
if (-not (Get-MgServicePrincipal -Filter "appId eq '$($app.AppId)'")) {
    New-MgServicePrincipal -AppId $app.AppId | Out-Null
    Write-Host '  created service principal'
}

# 3. Sign-up/sign-in user flow with the app attached.
if (-not $flows) {
    $body = @{
        '@odata.type'                  = '#microsoft.graph.externalUsersSelfServiceSignUpEventsFlow'
        displayName                    = $flowName
        conditions                     = @{
            applications = @{ includeApplications = @(@{ appId = $app.AppId }) }
        }
        onAuthenticationMethodLoadStart = @{
            '@odata.type'     = '#microsoft.graph.onAuthenticationMethodLoadStartExternalUsersSelfServiceSignUp'
            identityProviders = @(@{ id = 'EmailPassword-OAUTH' })
        }
        onInteractiveAuthFlowStart     = @{
            '@odata.type'   = '#microsoft.graph.onInteractiveAuthFlowStartExternalUsersSelfServiceSignUp'
            isSignUpAllowed = $true
        }
        onAttributeCollection          = @{
            '@odata.type'           = '#microsoft.graph.onAttributeCollectionExternalUsersSelfServiceSignUp'
            attributes              = @(
                @{ id = 'email'; displayName = 'Email Address'; description = 'Email address of the user'; userFlowAttributeType = 'builtIn'; dataType = 'string' },
                @{ id = 'displayName'; displayName = 'Display Name'; description = 'Display name of the user'; userFlowAttributeType = 'builtIn'; dataType = 'string' }
            )
            attributeCollectionPage = @{
                views = @(@{
                    inputs = @(
                        @{ attribute = 'email'; label = 'Email Address'; inputType = 'Text'; hidden = $true; editable = $false; writeToDirectory = $true; required = $true; validationRegEx = '^[a-zA-Z0-9.!#$%&''*+/=?^_`{|}~-]+@[a-zA-Z0-9-]+(?:.[a-zA-Z0-9-]+)*$' },
                        @{ attribute = 'displayName'; label = 'Display Name'; inputType = 'text'; hidden = $false; editable = $true; writeToDirectory = $true; required = $false; validationRegEx = '^[a-zA-Z_][0-9a-zA-Z_ ]*[0-9a-zA-Z_]+$' }
                    )
                })
            }
        }
    }
    $flow = Invoke-MgGraphRequest -Method POST -Uri 'v1.0/identity/authenticationEventsFlows' `
        -Body ($body | ConvertTo-Json -Depth 10) -ContentType 'application/json'
    Write-Host "  created user flow $($flow.id)"
} else {
    Write-Host '  user flow exists'
}

Write-Host ''
Write-Host '==> Add to portal/terraform.tfvars, then re-apply:'
Write-Host "external_id_client_id = `"$($app.AppId)`""

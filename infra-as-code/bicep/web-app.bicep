targetScope = 'resourceGroup'

/*
  Deploy a web app with a managed identity, diagnostic, and a private endpoint
*/

@description('This is the base name for each Azure resource name (6-8 chars)')
@minLength(6)
@maxLength(8)
param baseName string

@description('The region in which this architecture is deployed. Should match the region of the resource group.')
@minLength(1)
param location string = resourceGroup().location

@description('The name of the workload\'s existing Log Analytics workspace.')
@minLength(4)
param logAnalyticsWorkspaceName string

@description('The name of the web deploy file. The file should reside in a deploy container in the Azure Storage account. E.g. chatui.zip.')
@minLength(5)
param publishFileName string

@description('The name of the existing virtual network that this Web App instance will be deployed into for egress and a private endpoint for ingress.')
@minLength(1)
param virtualNetworkName string

@description('The name of the existing subnet in the virtual network that is where this web app will have its egress point.')
@minLength(1)
param appServicesSubnetName string

@description('The name of the subnet that private endpoints in the workload should surface in.')
@minLength(1)
param privateEndpointsSubnetName string

@description('The name of the existing Azure Storage account that the Azure Web App will be pulling code deployments from.')
@minLength(3)
param existingWebAppDeploymentStorageAccountName string

@description('The name of the existing Azure Application Insights instance that the Azure Web App will be using.')
@minLength(1)
param existingWebApplicationInsightsResourceName string

@description('The name of the existing Microsoft Foundry instance that the Azure Web App code will be calling for Foundry Agent Service agents.')
@minLength(2)
param existingFoundryResourceName string

@description('The name of the existing Foundry project name.')
@minLength(2)
param existingFoundryProjectName string

// variables
var appName = 'app-${baseName}'

// ---- Existing resources ----

@description('Existing Application Insights instance. Logs from the web app will be sent here.')
resource applicationInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: existingWebApplicationInsightsResourceName
}

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: virtualNetworkName

  resource appServicesSubnet 'subnets' existing = {
    name: appServicesSubnetName
  }
  resource privateEndpointsSubnet 'subnets' existing = {
    name: privateEndpointsSubnetName
  }
}

@description('Existing Azure Storage account. This is where the web app code is deployed from.')
resource webAppDeploymentStorageAccount 'Microsoft.Storage/storageAccounts@2024-01-01' existing = {
  name: existingWebAppDeploymentStorageAccountName
}

resource logWorkspace 'Microsoft.OperationalInsights/workspaces@2025-02-01' existing = {
  name: logAnalyticsWorkspaceName
}

@description('Built-in Role: [Storage Blob Data Reader](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles#storage-blob-data-reader)')
resource blobDataReaderRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
  scope: subscription()
}

@description('Built-in Role: [Azure AI User](https://learn.microsoft.com/azure/ai-foundry/concepts/rbac-azure-ai-foundry?pivots=fdp-project#azure-ai-user)')
resource azureAiUserRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: '53ca6127-db72-4b80-b1b0-d745d6d5456d'
  scope: subscription()
}

// If your web app/API code is going to be creating agents dynamically, you will need to assign a role such as this to App Service managed identity.
/*@description('Built-in Role: [Azure AI Project Manager](https://learn.microsoft.com/azure/ai-foundry/concepts/rbac-azure-ai-foundry?pivots=fdp-project#azure-ai-user)')
resource azureAiProjectManagerRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: 'eadc314b-1a2d-4efa-be10-5d325db5065e'
  scope: subscription()
}*/

resource appServiceExistingPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' existing = {
  name: 'privatelink.azurewebsites.net'
}

@description('Existing Foundry account. This account is where the agents hosted in Foundry Agent Service will be deployed. The web app code calls to these agents.')
resource foundry 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: existingFoundryResourceName

  resource project 'projects' existing = {
    name: existingFoundryProjectName
  }
}

// ---- New resources ----

@description('Managed Identity for App Service')
resource appServiceManagedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: 'id-${appName}'
  location: location
}

@description('Grant the App Service managed identity storage data reader role permissions')
resource blobDataReaderRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: webAppDeploymentStorageAccount
  name: guid(webAppDeploymentStorageAccount.id, appServiceManagedIdentity.id, blobDataReaderRole.id)
  properties: {
    roleDefinitionId: blobDataReaderRole.id
    principalType: 'ServicePrincipal'
    principalId: appServiceManagedIdentity.properties.principalId
  }
}

@description('Grant the App Service managed identity Azure AI user role permission so it can call into the Foundry-hosted agent.')
resource azureAiUserRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: foundry
  name: guid(foundry.id, appServiceManagedIdentity.id, azureAiUserRole.id)
  properties: {
    roleDefinitionId: azureAiUserRole.id
    principalType: 'ServicePrincipal'
    principalId: appServiceManagedIdentity.properties.principalId
  }
}

/*@description('Grant the App Service managed identity Azure AI manager role permission so it create the Foundry-hosted agent. Only needed if your code creates agents directly.')
resource azureAiManagerRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: foundry
  name: guid(foundry.id, appServiceManagedIdentity.id, azureAiProjectManagerRole.id)
  properties: {
    roleDefinitionId: azureAiProjectManagerRole.id
    principalType: 'ServicePrincipal'
    principalId: appServiceManagedIdentity.properties.principalId
  }
}*/

@description('Linux, PremiumV3 App Service Plan to host the chat web application.')
resource appServicePlan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: 'asp-${appName}${uniqueString(subscription().subscriptionId)}'
  location: location
  kind: 'linux'
  sku: {
    name: 'P1V3' // Some subscriptions do not have quota to premium web apps. If you encounter an error, request quota or to unblock yourself use 'S1' and set 'zoneRedundant' to 'false.'
                 // az appservice list-locations --linux-workers-enabled --sku P1V3
    capacity: 3
  }
  properties: {
    zoneRedundant: true // Some subscriptions do not have quota to support zone redundancy. If you encounter an error, set this to false.
    reserved: true
  }
}

@description('This is the web app that contains the chat UI application.')
resource webApp 'Microsoft.Web/sites@2024-04-01' = {
  name: appName
  location: location
  kind: 'app,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${appServiceManagedIdentity.id}': {}
    }
  }
  properties: {
    enabled: true
    serverFarmId: appServicePlan.id
    virtualNetworkSubnetId: virtualNetwork::appServicesSubnet.id
    httpsOnly: true
    #disable-next-line BCP037 // This is a valid property, just not part of the schema https://github.com/Azure/bicep-types-az/issues/2204
    sshEnabled: false
    autoGeneratedDomainNameLabelScope: 'SubscriptionReuse'
    vnetContentShareEnabled: true
    vnetImagePullEnabled: true
    publicNetworkAccess: 'Disabled'
    keyVaultReferenceIdentity: appServiceManagedIdentity.id
    endToEndEncryptionEnabled: true
    vnetRouteAllEnabled: true
    hostNamesDisabled: false
    clientAffinityEnabled: false
    siteConfig: {
      ftpsState: 'Disabled'
      vnetRouteAllEnabled: true
      http20Enabled: false
      publicNetworkAccess: 'Disabled'
      alwaysOn: true
      linuxFxVersion: 'DOTNETCORE|8.0'
      netFrameworkVersion: null
      windowsFxVersion: null
    }
  }
  dependsOn: [
    blobDataReaderRoleAssignment
  ]

  @description('Default configuration for the web app.')
  resource appsettings 'config' = {
    name: 'appsettings'
    properties: {
      WEBSITE_RUN_FROM_PACKAGE: '${webAppDeploymentStorageAccount.properties.primaryEndpoints.blob}deploy/${publishFileName}'
      WEBSITE_RUN_FROM_PACKAGE_BLOB_MI_RESOURCE_ID: appServiceManagedIdentity.id
      APPLICATIONINSIGHTS_CONNECTION_STRING: applicationInsights.properties.ConnectionString
      AZURE_CLIENT_ID: appServiceManagedIdentity.properties.clientId
      ApplicationInsightsAgent_EXTENSION_VERSION: '~3'
      AIProjectEndpoint:  foundry::project.properties.endpoints['AI Foundry API']
      AIAgentId: 'Not yet set' // Will be set once the agent is created
      XDT_MicrosoftApplicationInsights_Mode: 'Recommended'
    }
  }

  @description('Disable SCM publishing integration.')
  resource scm 'basicPublishingCredentialsPolicies' = {
    name: 'scm'
    properties: {
      allow: false
    }
  }

  @description('Disable FTP publishing integration.')
  resource ftp 'basicPublishingCredentialsPolicies' = {
    name: 'ftp'
    properties: {
      allow: false
    }
  }
}

@description('Enable App Service Azure Diagnostic')
resource azureDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'default'
  scope: webApp
  properties: {
    workspaceId: logWorkspace.id
    logs: [
      {
        category: 'AppServiceHTTPLogs'
        enabled: true
      }
      {
        category: 'AppServiceConsoleLogs'
        enabled: true
      }
      {
        category: 'AppServiceAppLogs'
        enabled: true
      }
      {
        category: 'AppServicePlatformLogs'
        enabled: true
      }
      {
        category: 'AppServiceAuditLogs'
        enabled: true
      }
      {
        category: 'AppServiceIPSecAuditLogs'
        enabled: true
      }
      {
        category: 'AppServiceAuthenticationLogs'
        enabled: true
      }
    ]
  }
}

resource appServicePrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-front-end-web-app'
  location: location
  properties: {
    subnet: {
      id: virtualNetwork::privateEndpointsSubnet.id
    }
    customNetworkInterfaceName: 'nic-front-end-web-app'
    privateLinkServiceConnections: [
      {
        name: 'front-end-web-app'
        properties: {
          privateLinkServiceId: webApp.id
          groupIds: [
            'sites'
          ]
        }
      }
    ]
  }

  resource appServiceDnsZoneGroup 'privateDnsZoneGroups' = {
    name: 'front-end-web-app'
    properties: {
      privateDnsZoneConfigs: [
        {
          name: 'web-app'
          properties: {
            privateDnsZoneId: appServiceExistingPrivateDnsZone.id
          }
        }
      ]
    }
  }
}

// App service plan auto scale settings
resource appServicePlanAutoScaleSettings 'Microsoft.Insights/autoscalesettings@2022-10-01' = {
  name: '${appServicePlan.name}-autoscale'
  location: location
  properties: {
    enabled: true
    targetResourceUri: appServicePlan.id
    profiles: [
      {
        name: 'Scale out condition'
        capacity: {
          maximum: '5'
          default: '3'
          minimum: '3'
        }
        rules: [
          {
            scaleAction: {
              type: 'ChangeCount'
              direction: 'Increase'
              cooldown: 'PT5M'
              value: '1'
            }
            metricTrigger: {
              metricName: 'CpuPercentage'
              metricNamespace: 'microsoft.web/serverfarms'
              operator: 'GreaterThan'
              timeAggregation: 'Average'
              threshold: 70
              metricResourceUri: appServicePlan.id
              timeWindow: 'PT10M'
              timeGrain: 'PT1M'
              statistic: 'Average'
            }
          }
        ]
      }
    ]
  }
  dependsOn: [
    webApp
  ]
}

// ---- Outputs ----

@description('The name of the app service plan.')
output appServicePlanName string = appServicePlan.name

@description('The name of the web app.')
output appName string = webApp.name

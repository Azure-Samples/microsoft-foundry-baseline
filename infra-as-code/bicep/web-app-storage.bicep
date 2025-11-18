targetScope = 'resourceGroup'

/*
  Deploy an Azure Storage account used for the web app with private endpoint and private DNS zone
*/

@description('The region in which this architecture is deployed. Should match the region of the resource group.')
@minLength(1)
param location string = resourceGroup().location

@description('This is the base name for each Azure resource name (6-8 chars)')
@minLength(6)
@maxLength(8)
param baseName string

@description('The name of the workload\'s existing Log Analytics workspace.')
@minLength(4)
param logAnalyticsWorkspaceName string

@description('The name of the workload\'s virtual network in this resource group, the Azure Storage private endpoint will be deployed into a subnet in here.')
@minLength(1)
param virtualNetworkName string

@description('The name for the subnet that private endpoints in the workload should surface in.')
@minLength(1)
param privateEndpointsSubnetName string

@description('Assign your user some roles to support access to the Foundry Agent Service dependencies for troubleshooting post deployment')
@maxLength(36)
@minLength(36)
param debugUserPrincipalId string

// ---- Existing resources ----

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: virtualNetworkName

  resource privateEndpointsSubnet 'subnets' existing = {
    name: privateEndpointsSubnetName
  }
}

resource logWorkspace 'Microsoft.OperationalInsights/workspaces@2025-02-01' existing = {
  name: logAnalyticsWorkspaceName
}

resource blobStorageLinkedPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' existing = {
  name: 'privatelink.blob.${environment().suffixes.storage}'
}

@description('Built-in Role: [Storage Blob Data Contributor](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles#storage-blob-data-contributor)')
resource storageBlobDataContributorRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
  scope: subscription()
}

// ---- New resources ----

@description('Deploy a storage account for the web app to use as a deployment source for its web application code. Will be exposed only via private endpoint.')
resource appDeployStorage 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: 'stwebapp${baseName}'
  location: location
  sku: {
    name: 'Standard_ZRS'  // This SKU has limited regional availability https://github.com/MicrosoftDocs/azure-docs/blob/main/includes/storage-redundancy-standard-zrs.md, if you would like to deploy this implementation to a region outside this list, you'll need to choose a storage SKU that is supported but still meets your workload's non-functional requirements.
  }
  kind: 'StorageV2'
  properties: {
    allowedCopyScope: 'AAD'
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    allowCrossTenantReplication: false
    encryption: {
      keySource: 'Microsoft.Storage'
      requireInfrastructureEncryption: false // This app service code host doesn't require double encryption, but if your scenario does, please enable.
      services: {
        blob: {
          enabled: true
          keyType: 'Account'
        }
        file: {
          enabled: true
          keyType: 'Account'
        }
      }
    }
    minimumTlsVersion: 'TLS1_2'
    isHnsEnabled: false
    isSftpEnabled: false
    defaultToOAuthAuthentication: true
    isLocalUserEnabled: false
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
      ipRules: []
      virtualNetworkRules: []
    }
    supportsHttpsTrafficOnly: true
  }

  resource blobService 'blobServices' = {
    name: 'default'

    // Storage container in which the Chat UI App's "Run from Zip" will be sourced
    resource deployContainer 'containers' = {
      name: 'deploy'
      properties: {
        publicAccess: 'None'
      }
    }
  }
}

@description('Enable App Service deployment Azure Storage Account blob diagnostic settings')
resource azureDiagnosticsBlob 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'default'
  scope: appDeployStorage::blobService
  properties: {
    workspaceId: logWorkspace.id
    logs: [
      {
        category: 'StorageRead'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
      {
        category: 'StorageWrite'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
      {
        category: 'StorageDelete'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
    ]
  }
}

@description('Assign your user the ability to manage application deployment files in blob storage.')
resource blobStorageContributorForUserRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: appDeployStorage::blobService::deployContainer
  name: guid(appDeployStorage::blobService::deployContainer.id, debugUserPrincipalId, storageBlobDataContributorRole.id)
  properties: {
    roleDefinitionId: storageBlobDataContributorRole.id
    principalType: 'User'
    principalId: debugUserPrincipalId // Part of the deployment guide requires you to upload the web app to this storage container. Assigning that data plane permission here. Ideally your CD pipeline would have this permission instead.
  }
}

resource webAppStoragePrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-web-app-storage'
  location: location
  properties: {
    subnet: {
      id: virtualNetwork::privateEndpointsSubnet.id
    }
    customNetworkInterfaceName: 'nic-web-app-storage'
    privateLinkServiceConnections: [
      {
        name: 'pe-web-app-storage'
        properties: {
          privateLinkServiceId: appDeployStorage.id
          groupIds: [
            'blob'
          ]
        }
      }
    ]
  }

  resource appDeployStorageDnsZoneGroup 'privateDnsZoneGroups' = {
    name: 'web-app-storage'
    properties: {
      privateDnsZoneConfigs: [
        {
          name: 'web-app-storage'
          properties: {
            privateDnsZoneId: blobStorageLinkedPrivateDnsZone.id
          }
        }
      ]
    }
  }
}

// ---- Outputs ----

@description('The name of the appDeploy Azure Storage account.')
output appDeployStorageName string = appDeployStorage.name

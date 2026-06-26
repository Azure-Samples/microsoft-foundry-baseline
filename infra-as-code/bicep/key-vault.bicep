targetScope = 'resourceGroup'

/*
  Deploy Key Vault with private endpoint and private DNS zone
*/

@description('This is the base name for each Azure resource name (6-8 chars)')
@minLength(6)
@maxLength(8)
param baseName string

@description('The region in which this architecture is deployed. Should match the region of the resource group.')
@minLength(1)
param location string = resourceGroup().location

@description('The certificate data for app gateway TLS termination. The value is base64 encoded')
@secure()
param appGatewayListenerCertificate string

@description('The name of the existing virtual network. This Key Vault will expose a private endpoint into this network.')
@minLength(1)
param virtualNetworkName string

@description('The name for the subnet that private endpoints in the workload should surface in.')
@minLength(1)
param privateEndpointsSubnetName string

@description('The name of the workload\'s existing Log Analytics workspace.')
@minLength(4)
param logAnalyticsWorkspaceName string

// ---- Existing resources ----

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2025-07-01' existing =  {
  name: virtualNetworkName

  resource privateEndpointsSubnet 'subnets' existing = {
    name: privateEndpointsSubnetName
  }
}

resource logWorkspace 'Microsoft.OperationalInsights/workspaces@2025-02-01' existing = {
  name: logAnalyticsWorkspaceName
}

@description('Azure Key Vault private DNS zone')
resource existingKeyVaultPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' existing = {
  name: 'privatelink.vaultcore.azure.net' // Cannot use 'privatelink.${environment().suffixes.keyvaultDns}', per https://github.com/Azure/bicep/issues/9708
}

// ---- New resources ----

resource keyVault 'Microsoft.KeyVault/vaults@2026-02-01' = {
  name: 'kv-${baseName}'
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices' // Required for AppGW communication
      ipRules: []
      virtualNetworkRules: []
    }
    publicNetworkAccess: 'Disabled'
    tenantId: subscription().tenantId
    enableRbacAuthorization: true      // Using RBAC
    enabledForDeployment: true         // VMs can retrieve certificates
    enabledForTemplateDeployment: true // ARM can retrieve values
    accessPolicies: []                 // Using RBAC
    enabledForDiskEncryption: false
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    createMode: 'default'              // Creating or updating the Key Vault (not recovering)
  }

  resource kvsGatewayPublicCert 'secrets' = {
    name: 'gateway-public-cert'
    properties: {
      value: appGatewayListenerCertificate
      contentType: 'application/x-pkcs12'
      attributes: {
        enabled: true
      }
    }
  }
}

@description('Enable Azure Diagnostics for Key Vault')
resource azureDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'default'
  scope: keyVault
  properties: {
    workspaceId: logWorkspace.id
    logs: [
      {
        category: 'AuditEvent'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
      {
        category: 'AzurePolicyEvaluationDetails'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
    ]
  }
}

// Private endpoints

resource keyVaultPrivateEndpoint 'Microsoft.Network/privateEndpoints@2025-07-01' = {
  name: 'pe-key-vault'
  location: location
  properties: {
    subnet: {
      id: virtualNetwork::privateEndpointsSubnet.id
    }
    customNetworkInterfaceName: 'nic-${keyVault.name}'
    privateLinkServiceConnections: [
      {
        name: 'key-vault'
        properties: {
          privateLinkServiceId: keyVault.id
          groupIds: [
            'vault'
          ]
        }
      }
    ]
  }

  resource keyVaultDnsZoneGroup 'privateDnsZoneGroups' = {
    name: 'key-vault'
    properties: {
      privateDnsZoneConfigs: [
        {
          name: 'key-vault'
          properties: {
            privateDnsZoneId: existingKeyVaultPrivateDnsZone.id
          }
        }
      ]
    }
  }
}

// ---- Outputs ----

@description('The name of the Key Vault.')
output keyVaultName string = keyVault.name

@description('Name of the secret holding the cert.')
output gatewayCertSecretKey string = keyVault::kvsGatewayPublicCert.name

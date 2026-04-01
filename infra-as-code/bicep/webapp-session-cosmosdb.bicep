targetScope = 'resourceGroup'

/*
  Deploy a dedicated Azure Cosmos DB account for the chat web app's persistent session store.
  This is separate from the Foundry Agent Service's Cosmos DB account — keeping the web app's
  conversation data isolated for independent scaling, blast-radius isolation, and compliance
  boundary control.
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

@description('The resource ID for the subnet that private endpoints in the workload should surface in.')
@minLength(1)
param privateEndpointSubnetResourceId string

@description('The principal ID of the web app managed identity that needs data plane access to read and write session documents.')
@minLength(36)
param webAppManagedIdentityPrincipalId string

// ---- Existing resources ----

@description('Existing private DNS zone for Cosmos DB. Used by the private endpoint to register DNS records.')
resource cosmosDbLinkedPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' existing = {
  name: 'privatelink.documents.azure.com'
}

@description('Existing Log Analytics workspace for diagnostic log collection.')
resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2025-02-01' existing = {
  name: logAnalyticsWorkspaceName
}

// ---- New resources ----

@description('Deploy a dedicated Azure Cosmos DB account for the chat web app. Used to persist conversation sessions so any App Service instance can serve any request without cookie affinity.')
resource cosmosDbAccount 'Microsoft.DocumentDB/databaseAccounts@2024-12-01-preview' = {
  name: 'cdb-webapp-sessions-${baseName}'
  location: location
  kind: 'GlobalDocumentDB'
  properties: {
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    disableLocalAuth: true
    enableAutomaticFailover: false
    enableMultipleWriteLocations: false
    minimalTlsVersion: 'Tls12'
    publicNetworkAccess: 'Disabled'
    enableFreeTier: false
    ipRules: []
    virtualNetworkRules: []
    networkAclBypass: 'None'
    networkAclBypassResourceIds: []
    diagnosticLogSettings: {
      enableFullTextQuery: 'False'
    }
    enableBurstCapacity: false
    locations: [
      {
        locationName: location
        failoverPriority: 0
        isZoneRedundant: false // Production readiness change: Some subscriptions do not have quota to support zone redundancy in their selected region. Before going to production, test this capability and if not available, work with Microsoft support to ensure you have capacity in your region and enable this. The session store's availability zone configuration should match the App Service Plan to ensure data plane resilience pairs with compute.
      }
    ]
    databaseAccountOfferType: 'Standard'
    backupPolicy: {
      type: 'Continuous'
      continuousModeProperties: {
        tier: 'Continuous7Days'
      }
    }
  }

  @description('Built-in Cosmos DB Data Contributor role for granting data access to Entra identities.')
  resource dataContributorRole 'sqlRoleDefinitions' existing = {
    name: '00000000-0000-0000-0000-000000000002'
  }

  @description('Grant the web app managed identity read/write access to session documents.')
  resource webAppToCosmos 'sqlRoleAssignments' = {
    name: guid(webAppManagedIdentityPrincipalId, dataContributorRole.id, cosmosDbAccount.id)
    properties: {
      roleDefinitionId: cosmosDbAccount::dataContributorRole.id
      principalId: webAppManagedIdentityPrincipalId
      scope: cosmosDbAccount.id
    }
  }
}

@description('Database for the chat web app conversation sessions.')
resource sessionsDatabase 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-12-01-preview' = {
  parent: cosmosDbAccount
  name: 'chatui'
  properties: {
    resource: {
      id: 'chatui'
    }
  }
}

@description('Container for chat session documents. Partitioned by sessionId.')
resource sessionsContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-12-01-preview' = {
  parent: sessionsDatabase
  name: 'sessions'
  properties: {
    resource: {
      id: 'sessions'
      partitionKey: {
        paths: ['/sessionId']
        kind: 'Hash'
        version: 2
      }
      defaultTtl: -1 // TTL enabled at the container level but no default expiry — items live until
                      // explicitly deleted or given a per-item `ttl` value. For production workloads,
                      // consider setting a reasonable default (e.g., 86400 for 24h or 604800 for 7 days)
                      // to prevent unbounded growth from abandoned sessions.
    }
  }
}

@description('Capture platform logs for the Cosmos DB account.')
resource azureDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'default'
  scope: cosmosDbAccount
  properties: {
    workspaceId: logAnalyticsWorkspace.id
    logs: [
      {
        category: 'DataPlaneRequests'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
      {
        category: 'PartitionKeyRUConsumption'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
      {
        category: 'ControlPlaneRequests'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
    ]
  }
}

// Private endpoint

@description('Private endpoint for the Cosmos DB account, keeping data plane traffic within the virtual network.')
resource cosmosDbPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-webapp-session-cosmosdb'
  location: resourceGroup().location
  properties: {
    subnet: {
      id: privateEndpointSubnetResourceId
    }
    customNetworkInterfaceName: 'nic-webapp-session-cosmosdb'
    privateLinkServiceConnections: [
      {
        name: 'webapp-session-cosmosdb'
        properties: {
          privateLinkServiceId: cosmosDbAccount.id
          groupIds: [
            'Sql'
          ]
        }
      }
    ]
  }

  resource dnsGroup 'privateDnsZoneGroups' = {
    name: 'webapp-session-cosmosdb'
    properties: {
      privateDnsZoneConfigs: [
        {
          name: 'webapp-session-cosmosdb'
          properties: {
            privateDnsZoneId: cosmosDbLinkedPrivateDnsZone.id
          }
        }
      ]
    }
  }
}

// ---- Outputs ----

@description('The name of the Cosmos DB account.')
output cosmosDbAccountName string = cosmosDbAccount.name

@description('The endpoint URL of the Cosmos DB account.')
output cosmosDbEndpoint string = cosmosDbAccount.properties.documentEndpoint

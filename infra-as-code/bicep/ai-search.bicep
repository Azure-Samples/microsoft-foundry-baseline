targetScope = 'resourceGroup'

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

@description('Assign your user some roles to support access to the Azure AI Foundry Agent dependencies for troubleshooting post deployment')
@maxLength(36)
@minLength(36)
param debugUserPrincipalId string

// ---- Existing resources ----

resource aiSearchLinkedPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' existing = {
  name: 'privatelink.search.windows.net'
}

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2025-02-01' existing = {
  name: logAnalyticsWorkspaceName
}

resource azureAISearchIndexDataContributorRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: '8ebe5a00-799e-43f5-93ac-243d3dce84a7'
  scope: subscription()
}

// ---- New resources ----

resource azureAiSearchService 'Microsoft.Search/searchServices@2025-02-01-preview' = {
  name: 'ais-ai-agent-vector-store-${baseName}'
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'standard'
  }
  properties: {
    disableLocalAuth: true
    authOptions: null
    hostingMode: 'default'
    partitionCount: 1 // Production readiness change: This can be updated based on the expected data volume and query load.
    replicaCount: 3   // 3 replicas are required for 99.9% availability for read/write operations
    semanticSearch: 'disabled'
    publicNetworkAccess: 'disabled'
    networkRuleSet: {
      bypass: 'None'
      ipRules: []
    }
  }
}

// Role assignments

@description('Assign your user the Azure AI Search Index Data Contributor role to support troubleshooting post deployment. Not needed for normal operation.')
resource debugUserAISearchIndexDataContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(debugUserPrincipalId, azureAISearchIndexDataContributorRole.id, azureAiSearchService.id)
  scope: azureAiSearchService
  properties: {
    roleDefinitionId: azureAISearchIndexDataContributorRole.id
    principalId: debugUserPrincipalId
    principalType: 'User'
  }
}

// Azure diagnostics

@description('Capture Azure Diagnostics for the Azure AI Search Service.')
resource azureDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'default'
  scope: azureAiSearchService
  properties: {
    workspaceId: logAnalyticsWorkspace.id
    logs: [
      {
        category: 'OperationLogs'
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

resource aiSearchPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-ai-agent-search'
  location: location
  properties: {
    subnet: {
      id: privateEndpointSubnetResourceId
    }
    customNetworkInterfaceName: 'nic-ai-agent-search'
    privateLinkServiceConnections: [
      {
        name: 'ai-agent-search'
        properties: {
          privateLinkServiceId: azureAiSearchService.id
          groupIds: [
            'searchService'
          ]
        }
      }
    ]
  }

  resource dnsGroup 'privateDnsZoneGroups' = {
    name: 'ai-agent-search'
    properties: {
      privateDnsZoneConfigs: [
        {
          name: 'ai-agent-search'
          properties: {
            privateDnsZoneId: aiSearchLinkedPrivateDnsZone.id
          }
        }
      ]
    }
  }
}

// Prevent Accidental Changes

resource azureAiSearchServiceLocks 'Microsoft.Authorization/locks@2020-05-01' = {
  scope: azureAiSearchService
  name: '${azureAiSearchService.name}-lock'
  properties: {
    level: 'CanNotDelete'
    notes: 'Prevent deleting; recovery not practical. Hard dependency for your AI Foundry Agent Service.'
    owners: []
  }
}

// ---- Outputs ----

output aiSearchName string = azureAiSearchService.name

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

@description('The resource ID for the subnet that the Foundry agents will egress through.')
@minLength(1)
param agentSubnetResourceId string

@description('The resource ID for the subnet that private endpoints in the workload should surface in.')
@minLength(1)
param privateEndpointSubnetResourceId string

@description('Your principal ID. Allows you to access the Foundry portal for post-deployment verification of functionality.')
@maxLength(36)
@minLength(36)
param foundryPortalUserPrincipalId string

var foundryName = 'aif${baseName}'

// ---- Existing resources ----

@description('Existing: Private DNS zone for Azure AI services using the cognitive services FQDN.')
resource cognitiveServicesLinkedPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' existing = {
  name: 'privatelink.cognitiveservices.azure.com'
}

@description('Existing: Private DNS zone for Azure AI services using the Azure AI services FQDN.')
resource foundryLinkedPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' existing = {
  name: 'privatelink.services.ai.azure.com'
}

@description('Existing: Private DNS zone for Azure AI services using the Azure AI OpenAI FQDN.')
resource azureOpenAiLinkedPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' existing = {
  name: 'privatelink.openai.azure.com'
}

@description('Existing: Built-in Cognitive Services User role.')
resource cognitiveServicesUserRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: 'a97b65f3-24c7-4388-baec-2e87135dc908'
  scope: subscription()
}

@description('Existing: Log sink for Azure Diagnostics.')
resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2025-02-01' existing = {
  name: logAnalyticsWorkspaceName
}

// ---- New resources ----

@description('Deploy Microsoft Foundry (account) with Foundry Agent Service capability.')
resource foundry 'Microsoft.CognitiveServices/accounts@2025-10-01-preview' = {
  name: foundryName
  location: location
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    customSubDomainName: foundryName
    allowProjectManagement: true // Foundry account + projects
    disableLocalAuth: true
    networkAcls: {
      bypass: 'None'
      ipRules: []
      defaultAction: 'Deny'
      virtualNetworkRules: []
    }
    publicNetworkAccess: 'Disabled'
    #disable-next-line BCP036
    networkInjections: [
      {
        scenario: 'agent'
        subnetArmId: agentSubnetResourceId  // Report this, schema issue and IP address range issue
        useMicrosoftManagedNetwork: false
      }
    ]
  }

  @description('Models are managed at the account level. Deploy the GPT model that will be used for the Foundry agent logic.')
  resource model 'deployments' = {
    name: 'agent-model'
    sku: {
      capacity: 50
      name: 'DataZoneStandard' // Production readiness, use provisioned deployments with automatic spillover https://learn.microsoft.com/azure/ai-services/openai/how-to/spillover-traffic-management.
    }
    properties: {
      model: {
        format: 'OpenAI'
        name: 'gpt-4o'
        version: '2024-11-20'  // Use a model version available in your region.
      }
      versionUpgradeOption: 'NoAutoUpgrade' // Production deployments should not auto-upgrade models.  Testing compatibility is important.
      raiPolicyName: 'Microsoft.DefaultV2'  // If this isn't strict enough for your use case, create a custom RAI policy.
    }
  }
}

// Role assignments

@description('Assign yourself to have access to the Foundry portal.')
resource cognitiveServicesUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(foundry.id, cognitiveServicesUserRole.id, foundryPortalUserPrincipalId)
  scope: foundry
  properties: {
    roleDefinitionId: cognitiveServicesUserRole.id
    principalId: foundryPortalUserPrincipalId
    principalType: 'User'
  }
}

// Private endpoints

@description('Connect the Foundry account\'s endpoints to your existing private DNS zones.')
resource foundryPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-foundry'
  location: location
  properties: {
    subnet: {
      id: privateEndpointSubnetResourceId
    }
    customNetworkInterfaceName: 'nic-foundry'
    privateLinkServiceConnections: [
      {
        name: 'aifoundry'
        properties: {
          privateLinkServiceId: foundry.id
          groupIds: [
            'account'
          ]
        }
      }
    ]
  }

  resource dnsGroup 'privateDnsZoneGroups' = {
    name: 'aifoundry'
    properties: {
      privateDnsZoneConfigs: [
        {
          name: 'aifoundry'
          properties: {
            privateDnsZoneId: foundryLinkedPrivateDnsZone.id
          }
        }
        {
          name: 'azureopenai'
          properties: {
            privateDnsZoneId: azureOpenAiLinkedPrivateDnsZone.id
          }
        }
        {
          name: 'cognitiveservices'
          properties: {
            privateDnsZoneId: cognitiveServicesLinkedPrivateDnsZone.id
          }
        }
      ]
    }
  }
}

// Azure diagnostics

@description('Enable logging on the Foundry account.')
resource azureDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'default'
  scope: foundry
  properties: {
    workspaceId: logAnalyticsWorkspace.id
    logs: [
      {
        category: 'Audit'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
      {
        category: 'RequestResponse'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
      {
        category: 'AzureOpenAIRequestUsage'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
      {
        category: 'Trace'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
    ]
  }
}

// ---- Outputs ----

@description('The name of the Microsoft Foundry account.')
output foundryName string = foundry.name

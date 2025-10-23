targetScope = 'resourceGroup'

@description('The region in which this architecture is deployed. Should match the region of the resource group.')
@minLength(1)
param location string = resourceGroup().location

@description('This is the base name for each Azure resource name (6-8 chars)')
@minLength(6)
@maxLength(8)
param baseName string

@description('Assign your user some roles to support access to the Azure AI Foundry Agent dependencies for troubleshooting post deployment')
@maxLength(36)
@minLength(36)
param debugUserPrincipalId string

@description('The name of the workload\'s existing Log Analytics workspace.')
@minLength(4)
param logAnalyticsWorkspaceName string

@description('The resource ID for the subnet that private endpoints in the workload should surface in.')
@minLength(1)
param privateEndpointSubnetResourceId string

// ---- New resources ----

@description('Deploy Azure Storage account for the Azure AI Foundry Agent Service (dependency). This is used for binaries uploaded within threads or as "knowledge" uploaded as part of an agent.')
module deployAgentStorageAccount 'ai-agent-blob-storage.bicep' = {
  name: 'agentStorageAccountDeploy'
  scope: resourceGroup()
  params: {
    location: location
    baseName: baseName
    logAnalyticsWorkspaceName: logAnalyticsWorkspaceName
    debugUserPrincipalId: debugUserPrincipalId
    privateEndpointSubnetResourceId: privateEndpointSubnetResourceId
  }
}

@description('Deploy Azure Cosmos DB account for the Azure AI Foundry Agent Service (dependency). This is used for storing agent definitions and threads.')
module deployCosmosDbThreadStorageAccount 'cosmos-db.bicep' = {
  name: 'cosmosDbThreadStorageAccountDeploy'
  scope: resourceGroup()
  params: {
    location: location
    baseName: baseName
    logAnalyticsWorkspaceName: logAnalyticsWorkspaceName
    debugUserPrincipalId: debugUserPrincipalId
    privateEndpointSubnetResourceId: privateEndpointSubnetResourceId
  }
}

@description('Deploy Azure AI Search instance for the Azure AI Foundry Agent Service (dependency). This is used when a user uploads a file to the agent, and the agent needs to search for information in that file.')
module deployAzureAISearchService 'ai-search.bicep' = {
  name: 'aiSearchServiceDeploy'
  scope: resourceGroup()
  params: {
    location: location
    baseName: baseName
    logAnalyticsWorkspaceName: logAnalyticsWorkspaceName
    debugUserPrincipalId: debugUserPrincipalId
    privateEndpointSubnetResourceId: privateEndpointSubnetResourceId
  }
}

// ---- Outputs ----

output cosmosDbAccountName string = deployCosmosDbThreadStorageAccount.outputs.cosmosDbAccountName
output storageAccountName string = deployAgentStorageAccount.outputs.storageAccountName
output aiSearchName string = deployAzureAISearchService.outputs.aiSearchName

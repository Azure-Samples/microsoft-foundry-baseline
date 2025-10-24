targetScope = 'resourceGroup'

@description('The region in which this architecture is deployed. Should match the region of the resource group.')
@minLength(1)
param location string = resourceGroup().location

@description('The existing Azure AI Foundry account. This project will become a child resource of this account.')
@minLength(2)
param existingAiFoundryName string

@description('The existing Azure Cosmos DB account that is going to be used as the Azure AI Foundry Agent thread storage database (dependency).')
@minLength(3)
param existingCosmosDbAccountName string

@description('The existing Azure Storage account that is going to be used as the Azure AI Foundry Agent blob store (dependency).')
@minLength(3)
param existingStorageAccountName string

@description('The existing Azure AI Search account that is going to be used as the Azure AI Foundry Agent vector store (dependency).')
@minLength(1)
param existingAISearchAccountName string

@description('The existing Bing grounding data account that is available to Azure AI Foundry Agent agents in this project.')
@minLength(1)
param existingBingAccountName string

@description('The existing Application Insights instance to log token usage in this project.')
@minLength(1)
param existingWebApplicationInsightsResourceName string

@description('The existing User Managed Identity for the AI Foundry project.')
@minLength(1)
param existingAgentUserManagedIdentityName string

// ---- Existing resources ----

@description('Existing Agent User Managed Identity for the AI Foundry Project.')
resource agentUserManagedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2025-01-31-preview' existing = {
  name: existingAgentUserManagedIdentityName
}

@description('The internal ID of the project is used in the Azure Storage blob containers and in the Cosmos DB collections.')
#disable-next-line BCP053
var workspaceId = aiFoundry::project.properties.internalId
var workspaceIdAsGuid = '${substring(workspaceId, 0, 8)}-${substring(workspaceId, 8, 4)}-${substring(workspaceId, 12, 4)}-${substring(workspaceId, 16, 4)}-${substring(workspaceId, 20, 12)}'

var scopeUserContainerId = '/subscriptions/${subscription().subscriptionId}/resourceGroups/${resourceGroup().name}/providers/Microsoft.DocumentDB/databaseAccounts/${cosmosDbAccount.name}/dbs/enterprise_memory/colls/${workspaceIdAsGuid}-thread-message-store'
var scopeSystemContainerId = '/subscriptions/${subscription().subscriptionId}/resourceGroups/${resourceGroup().name}/providers/Microsoft.DocumentDB/databaseAccounts/${cosmosDbAccount.name}/dbs/enterprise_memory/colls/${workspaceIdAsGuid}-system-thread-message-store'
var scopeEntityContainerId = '/subscriptions/${subscription().subscriptionId}/resourceGroups/${resourceGroup().name}/providers/Microsoft.DocumentDB/databaseAccounts/${cosmosDbAccount.name}/dbs/enterprise_memory/colls/${workspaceIdAsGuid}-agent-entity-store'

@description('Existing Azure Cosmos DB account. Will be assigning Data Contributor role to the Azure AI Foundry project\'s identity.')
resource cosmosDbAccount 'Microsoft.DocumentDB/databaseAccounts@2024-12-01-preview' existing = {
  name: existingCosmosDbAccountName

  @description('Built-in Cosmos DB Data Contributor role that can be assigned to Entra identities to grant data access on a Cosmos DB database.')
  resource dataContributorRole 'sqlRoleDefinitions' existing = {
    name: '00000000-0000-0000-0000-000000000002'
  }
}

resource agentStorageAccount 'Microsoft.Storage/storageAccounts@2024-01-01' existing = {
  name: existingStorageAccountName
}

resource azureAISearchService 'Microsoft.Search/searchServices@2025-02-01-preview' existing = {
  name: existingAISearchAccountName
}

// Storage Blob Data Owner Role
resource storageBlobDataOwnerRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
  scope: subscription()
}

#disable-next-line BCP081
resource bingAccount 'Microsoft.Bing/accounts@2025-05-01-preview' existing = {
  name: existingBingAccountName
}

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: existingWebApplicationInsightsResourceName
}

// ---- New resources ----

@description('Existing Azure AI Foundry account. The project will be created as a child resource of this account.')
resource aiFoundry 'Microsoft.CognitiveServices/accounts@2025-06-01' existing  = {
  name: existingAiFoundryName

  resource project 'projects' = {
    name: 'projchat'
    location: location
    identity: {
      type: 'UserAssigned'
      userAssignedIdentities: {
        '${agentUserManagedIdentity.id}': {}
      }
    }
    properties: {
      description: 'Chat using internet data in your Azure AI Foundry Agent.'
      displayName: 'Chat with Internet Data'
    }

    @description('Create project connection to CosmosDB (thread storage); dependency for Azure AI Foundry Agent Service.')
    resource threadStorageConnection 'connections' = {
      name: cosmosDbAccount.name
      properties: {
        authType: 'AAD'
        category: 'CosmosDb'
        target: cosmosDbAccount.properties.documentEndpoint
        metadata: {
          ApiType: 'Azure'
          ResourceId: cosmosDbAccount.id
          location: cosmosDbAccount.location
        }
      }
      dependsOn: []
    }

    @description('Create project connection to the Azure Storage account; dependency for Azure AI Foundry Agent Service.')
    resource storageConnection 'connections' = {
      name: agentStorageAccount.name
      properties: {
        authType: 'AAD'
        category: 'AzureStorageAccount'
        target: agentStorageAccount.properties.primaryEndpoints.blob
        metadata: {
          ApiType: 'Azure'
          ResourceId: agentStorageAccount.id
          location: agentStorageAccount.location
        }
      }
      dependsOn: [
        projectBlobDataOwnerConditionalAssignment
        threadStorageConnection // Single thread these connections, else conflict errors tend to happen
      ]
    }

    @description('Create project connection to Azure AI Search; dependency for Azure AI Foundry Agent Service.')
    resource aiSearchConnection 'connections' = {
      name: azureAISearchService.name
      properties: {
        category: 'CognitiveSearch'
        target: azureAISearchService.properties.endpoint
        authType: 'AAD'
        metadata: {
          ApiType: 'Azure'
          ResourceId: azureAISearchService.id
          location: azureAISearchService.location
        }
      }
      dependsOn: [
        storageConnection // Single thread these connections, else conflict errors tend to happen
      ]
    }

    @description('Connect this project to application insights for visualization of token usage.')
    resource applicationInsightsConnection 'connections' = {
      name:'appInsights-connection'
      properties: {
        authType: 'ApiKey'
        category: 'AppInsights'
        credentials: {
          key: applicationInsights.properties.ConnectionString
        }
        isSharedToAll: false
        target: applicationInsights.id
        metadata: {
          ApiType: 'Azure'
          ResourceId: applicationInsights.id
          location: applicationInsights.location
        }
      }
      dependsOn: [
        aiSearchConnection // Single thread these connections, else conflict errors tend to happen
      ]
    }

    @description('Create the Azure AI Foundry Agent Service capability.')
    resource aiAgentService 'capabilityHosts' = {
      name: 'projectagents'
      properties: {
        capabilityHostKind: 'Agents'
        vectorStoreConnections: ['${aiSearchConnection.name}']
        storageConnections: ['${storageConnection.name}']
        threadStorageConnections: ['${threadStorageConnection.name}']
      }
      dependsOn: [
        applicationInsightsConnection  // Single thread changes to the project, else conflict errors tend to happen
      ]
    }

    @description('Create project connection to Bing grounding data. Useful for future agents that get created.')
    resource bingGroundingConnection 'connections' = {
      name: replace(existingBingAccountName, '-', '')
      properties: {
        authType: 'ApiKey'
        target: bingAccount.properties.endpoint
        category: 'GroundingWithBingSearch'
        metadata: {
          type: 'bing_grounding'
          ApiType: 'Azure'
          ResourceId: bingAccount.id
          location: bingAccount.location
        }
        credentials: {
          key: bingAccount.listKeys().key1
        }
        isSharedToAll: false
      }
      dependsOn: [
        aiAgentService  // Deploy after the Foundry Agent Service is provisioned, not a dependency.
      ]
    }
  }
}

// Role assignments

@description('Grant the AI Foundry Project managed identity Storage Account Blob Data Owner user role permissions.')
module projectBlobDataOwnerConditionalAssignment './modules/storageAccountRoleAssignment.bicep' = {
  name: 'projectBlobDataOwnerConditionalAssignmentDeploy'
  params: {
    roleDefinitionId: storageBlobDataOwnerRole.id
    principalId: agentUserManagedIdentity.properties.principalId
    existingStorageAccountName: existingStorageAccountName
    conditionVersion: '2.0'
    condition: '((!(ActionMatches{\'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/tags/read\'})  AND  !(ActionMatches{\'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/filter/action\'}) AND  !(ActionMatches{\'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/tags/write\'}) ) OR (@Resource[Microsoft.Storage/storageAccounts/blobServices/containers:name] StringStartsWithIgnoreCase \'${workspaceIdAsGuid}\'))'
  }
}

// Sql Role Assignments

@description('Assign the project\'s managed identity the ability to read and write data in this collection within enterprise_memory database.')
module projectUserThreadContainerWriterSqlAssignment './modules/cosmosdbSqlRoleAssignment.bicep' = {
  name: 'projectUserThreadContainerWriterSqlAssignmentDeploy'
  params: {
    roleDefinitionId: cosmosDbAccount::dataContributorRole.id
    principalId: agentUserManagedIdentity.properties.principalId
    existingCosmosDbAccountName: existingCosmosDbAccountName
    existingCosmosDbName: 'enterprise_memory'
    existingCosmosCollectionTypeName: 'user'
    scopeUserContainerId: scopeUserContainerId
  }
  dependsOn: [
    aiFoundry::project::aiAgentService
  ]
}

@description('Assign the project\'s managed identity the ability to read and write data in this collection within enterprise_memory database.')
module projectSystemThreadContainerWriterSqlAssignment './modules/cosmosdbSqlRoleAssignment.bicep' = {
  name: 'projectSystemThreadContainerWriterSqlAssignmentDeploy'
  params: {
    roleDefinitionId: cosmosDbAccount::dataContributorRole.id
    principalId: agentUserManagedIdentity.properties.principalId
    existingCosmosDbAccountName: existingCosmosDbAccountName
    existingCosmosDbName: 'enterprise_memory'
    existingCosmosCollectionTypeName: 'system'
    scopeUserContainerId: scopeSystemContainerId
  }
  dependsOn: [
    aiFoundry::project::aiAgentService
    projectUserThreadContainerWriterSqlAssignment // Single thread applying these permissions.
  ]
}

@description('Assign the project\'s managed identity the ability to read and write data in this collection within enterprise_memory database.')
module projectEntityContainerWriterSqlAssignment './modules/cosmosdbSqlRoleAssignment.bicep' = {
  name: 'projectEntityContainerWriterSqlAssignmentDeploy'
  params: {
    roleDefinitionId: cosmosDbAccount::dataContributorRole.id
    principalId: agentUserManagedIdentity.properties.principalId
    existingCosmosDbAccountName: existingCosmosDbAccountName
    existingCosmosDbName: 'enterprise_memory'
    existingCosmosCollectionTypeName: 'entities'
    scopeUserContainerId: scopeEntityContainerId
  }
  dependsOn: [
    aiFoundry::project::aiAgentService
    projectSystemThreadContainerWriterSqlAssignment // Single thread applying these permissions.
  ]
}
  
// ---- Outputs ----

output aiAgentProjectName string = aiFoundry::project.name

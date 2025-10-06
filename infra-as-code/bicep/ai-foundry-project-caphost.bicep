targetScope = 'resourceGroup'

@description('The existing Azure AI Foundry account. This project will become a child resource of this account.')
@minLength(2)
param existingAiFoundryName string

@description('The existing Azure AI Foundry project name.')
@minLength(2)
param existingAiFoundryProjectName string

@description('The existing Azure AI Foundry project principal id.')
@minLength(8)
param existingAiFoundryPrincipalId string

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

// ---- Existing resources ----

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

  @description('Assign the project\'s managed identity the ability to read and write data in this collection within enterprise_memory database.')
  resource projectUserThreadContainerWriter 'sqlRoleAssignments' = {
    name: guid(aiFoundry::project.id, cosmosDbAccount::dataContributorRole.id, 'enterprise_memory', 'user', existingAiFoundryPrincipalId)
    properties: {
      roleDefinitionId: cosmosDbAccount::dataContributorRole.id
      principalId: aiFoundry::project.identity.principalId
      scope: scopeUserContainerId
    }
    dependsOn: [
      aiFoundry::project::aiAgentService
    ]
  }

  @description('Assign the project\'s managed identity the ability to read and write data in this collection within enterprise_memory database.')
  resource projectSystemThreadContainerWriter 'sqlRoleAssignments' = {
    name: guid(aiFoundry::project.id, cosmosDbAccount::dataContributorRole.id, 'enterprise_memory', 'system', existingAiFoundryPrincipalId)
    properties: {
      roleDefinitionId: cosmosDbAccount::dataContributorRole.id
      principalId: aiFoundry::project.identity.principalId
      scope: scopeSystemContainerId
    }
    dependsOn: [
      cosmosDbAccount::projectUserThreadContainerWriter // Single thread applying these permissions.
      aiFoundry::project::aiAgentService
    ]
  }

  @description('Assign the project\'s managed identity the ability to read and write data in this collection within enterprise_memory database.')
  resource projectEntityContainerWriter 'sqlRoleAssignments' = {
    name: guid(aiFoundry::project.id, cosmosDbAccount::dataContributorRole.id, 'enterprise_memory', 'entities', existingAiFoundryPrincipalId)
    properties: {
      roleDefinitionId: cosmosDbAccount::dataContributorRole.id
      principalId: aiFoundry::project.identity.principalId
      scope: scopeEntityContainerId
    }
    dependsOn: [
      cosmosDbAccount::projectSystemThreadContainerWriter // Single thread applying these permissions.
      aiFoundry::project::aiAgentService
    ]
  }
}

resource agentStorageAccount 'Microsoft.Storage/storageAccounts@2024-01-01' existing = {
  name: existingStorageAccountName
}

resource azureAISearchService 'Microsoft.Search/searchServices@2025-02-01-preview' existing = {
  name: existingAISearchAccountName
}

resource azureAISearchServiceContributorRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: '7ca78c08-252a-4471-8644-bb5ff32d4ba0'
  scope: subscription()
}

resource azureAISearchIndexDataContributorRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: '8ebe5a00-799e-43f5-93ac-243d3dce84a7'
  scope: subscription()
}

// Storage Blob Data Contributor
resource storageBlobDataContributorRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
  scope: subscription()
}

// Storage Blob Data Owner Role
resource storageBlobDataOwnerRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
  scope: subscription()
}

resource cosmosDbOperatorRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: '230815da-be43-4aae-9cb4-875f7bd000aa'
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

  resource project 'projects' existing = {
    name: existingAiFoundryProjectName

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
      dependsOn: [
        projectDbCosmosDbOperatorAssignment
      ]
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
        projectBlobDataContributorAssignment
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
        projectAISearchIndexDataContributorAssignment
        projectAISearchContributorAssignment
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

resource projectDbCosmosDbOperatorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aiFoundry::project.id, cosmosDbOperatorRole.id, cosmosDbAccount.id, existingAiFoundryPrincipalId)
  scope: cosmosDbAccount
  properties: {
    roleDefinitionId: cosmosDbOperatorRole.id
    principalId: aiFoundry::project.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource projectBlobDataContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aiFoundry::project.id, storageBlobDataContributorRole.id, agentStorageAccount.id, existingAiFoundryPrincipalId)
  scope: agentStorageAccount
  properties: {
    roleDefinitionId: storageBlobDataContributorRole.id
    principalId: aiFoundry::project.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource projectBlobDataOwnerConditionalAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aiFoundry::project.id, storageBlobDataOwnerRole.id, agentStorageAccount.id, existingAiFoundryPrincipalId)
  scope: agentStorageAccount
  properties: {
    principalId: aiFoundry::project.identity.principalId
    roleDefinitionId: storageBlobDataOwnerRole.id
    principalType: 'ServicePrincipal'
    conditionVersion: '2.0'
    condition: '((!(ActionMatches{\'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/tags/read\'})  AND  !(ActionMatches{\'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/filter/action\'}) AND  !(ActionMatches{\'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/tags/write\'}) ) OR (@Resource[Microsoft.Storage/storageAccounts/blobServices/containers:name] StringStartsWithIgnoreCase \'${workspaceIdAsGuid}\'))'
  }
}

resource projectAISearchContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aiFoundry::project.id, azureAISearchServiceContributorRole.id, azureAISearchService.id, existingAiFoundryPrincipalId)
  scope: azureAISearchService
  properties: {
    roleDefinitionId: azureAISearchServiceContributorRole.id
    principalId: aiFoundry::project.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource projectAISearchIndexDataContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aiFoundry::project.id, azureAISearchIndexDataContributorRole.id, azureAISearchService.id, existingAiFoundryPrincipalId)
  scope: azureAISearchService
  properties: {
    roleDefinitionId: azureAISearchIndexDataContributorRole.id
    principalId: aiFoundry::project.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ---- Outputs ----

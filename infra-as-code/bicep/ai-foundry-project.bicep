targetScope = 'resourceGroup'

@description('The region in which this architecture is deployed. Should match the region of the resource group.')
@minLength(1)
param location string = resourceGroup().location

@description('The existing Microsoft Foundry account. This project will become a child resource of this account.')
@minLength(2)
param existingFoundryName string

@description('The existing Azure Cosmos DB account that is going to be used as the Foundry Agent Service thread storage database (dependency).')
@minLength(3)
param existingCosmosDbAccountName string

@description('The existing Azure Storage account that is going to be used as the Foundry Agent Service blob store (dependency).')
@minLength(3)
param existingStorageAccountName string

@description('The existing Azure AI Search account that is going to be used as the Foundry Agent Service vector store (dependency).')
@minLength(1)
param existingAISearchAccountName string

@description('The existing Bing grounding data account that is available to Foundry Agent Service agents in this project.')
@minLength(1)
param existingBingAccountName string

@description('The existing Application Insights instance to log token usage in this project.')
@minLength(1)
param existingWebApplicationInsightsResourceName string

// ---- Existing resources ----

@description('The internal ID of the project is used in the Azure Storage blob containers and in the Cosmos DB collections.')
#disable-next-line BCP053
var workspaceId = foundry::project.properties.internalId
var workspaceIdAsGuid = '${substring(workspaceId, 0, 8)}-${substring(workspaceId, 8, 4)}-${substring(workspaceId, 12, 4)}-${substring(workspaceId, 16, 4)}-${substring(workspaceId, 20, 12)}'

var scopeAllContainers = '/subscriptions/${subscription().subscriptionId}/resourceGroups/${resourceGroup().name}/providers/Microsoft.DocumentDB/databaseAccounts/${cosmosDbAccount.name}/dbs/enterprise_memory'

// Storage Blob Data Owner Role
resource storageBlobDataOwnerRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
  scope: subscription()
}

// Storage Blob Data Contributor
resource storageBlobDataContributorRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
  scope: subscription()
}

// Cosmos DB Account Operator Role
resource cosmosDbOperatorRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: '230815da-be43-4aae-9cb4-875f7bd000aa'
  scope: subscription()
}

@description('Existing Azure Cosmos DB account. Will be assigning Data Contributor role to the Foundry project\'s identity.')
resource cosmosDbAccount 'Microsoft.DocumentDB/databaseAccounts@2024-12-01-preview' existing = {
  name: existingCosmosDbAccountName

  @description('Built-in Cosmos DB Data Contributor role that can be assigned to Entra identities to grant data access on a Cosmos DB database.')
  resource dataContributorRole 'sqlRoleDefinitions' existing = {
    name: '00000000-0000-0000-0000-000000000002'
  }
}

resource azureAISearchServiceContributorRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: '7ca78c08-252a-4471-8644-bb5ff32d4ba0'
  scope: subscription()
}

resource azureAISearchIndexDataContributorRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: '8ebe5a00-799e-43f5-93ac-243d3dce84a7'
  scope: subscription()
}

resource agentStorageAccount 'Microsoft.Storage/storageAccounts@2024-01-01' existing = {
  name: existingStorageAccountName
}

resource azureAISearchService 'Microsoft.Search/searchServices@2025-02-01-preview' existing = {
  name: existingAISearchAccountName
}

#disable-next-line BCP081
resource bingAccount 'Microsoft.Bing/accounts@2025-05-01-preview' existing = {
  name: existingBingAccountName
}

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: existingWebApplicationInsightsResourceName
}

// ---- New resources ----

@description('Existing Foundry account. The project will be created as a child resource of this account.')
resource foundry 'Microsoft.CognitiveServices/accounts@2025-10-01-preview' existing  = {
  name: existingFoundryName

  resource project 'projects' = {
    name: 'projchat'
    location: location
    // This project uses a System Assigned Managed Identity instead of a User Assigned Managed Identity.
    // At the time of this writing, the Foundry Agent Service does not support application creation when
    // the project is configured with a User Assigned Managed Identity. When UMI support becomes available,
    // consider reverting to UserAssigned to align with identity best practices for this architecture.
    identity: {
      type: 'SystemAssigned'
    }
    properties: {
      description: 'Chat using internet data in your Foundry Agent.'
      displayName: 'Chat with Internet Data'
    }

    @description('Create project connection to CosmosDB (thread storage); dependency for Foundry Agent Service.')
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

    @description('Create project connection to the Azure Storage account; dependency for Foundry Agent Service.')
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

    @description('Create project connection to Azure AI Search; dependency for Foundry Agent Service.')
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

    @description('Create the Foundry Agent Service capability host.')
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

// Role assignments for the Foundry project's System Assigned Managed Identity.
// These grants are required because the project uses SystemAssigned identity (see identity note above).
// When reverting to UserAssigned, replace 'foundry::project.identity.principalId' with the UMI principal
// and restore the UMI role assignments that were removed from the dependency modules.

@description('Grant the Foundry project managed identity Storage Account Blob Data Contributor user role permissions.')
module projectBlobDataContributorAssignment './modules/storageAccountRoleAssignment.bicep' = {
  name: 'projectBlobDataContributorAssignmentDeploy'
  params: {
    roleDefinitionId: storageBlobDataContributorRole.id
    principalId: foundry::project.identity.principalId
    existingStorageAccountName: agentStorageAccount.name
  }
}

@description('Grant the Foundry application agent identity the Storage Account Blob Data Owner user role permissions.')
module projectBlobDataOwnerConditionalAssignment './modules/storageAccountRoleAssignment.bicep' = {
  name: 'projectBlobDataOwnerConditionalAssignmentDeploy'
  params: {
    roleDefinitionId: storageBlobDataOwnerRole.id
    principalId: foundry::project.identity.principalId
    existingStorageAccountName: agentStorageAccount.name
    conditionVersion: '2.0'
    condition: '((!(ActionMatches{\'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/tags/read\'})  AND  !(ActionMatches{\'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/filter/action\'}) AND  !(ActionMatches{\'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/tags/write\'}) ) OR (@Resource[Microsoft.Storage/storageAccounts/blobServices/containers:name] StringStartsWithIgnoreCase \'${workspaceIdAsGuid}\'))'
  }
}

@description('Grant the Foundry application agent identity AI Search Contributor user role permissions.')
module projectAISearchContributorAssignment './modules/aiSearchRoleAssignment.bicep' = {
  name: 'projectAISearchContributorAssignmentDeploy'
  params: {
    roleDefinitionId: azureAISearchServiceContributorRole.id
    principalId: foundry::project.identity.principalId
    existingAISearchAccountName: existingAISearchAccountName
  }
}

@description('Grant the Foundry application agent identity AI Search Data Contributor user role permissions.')
module projectAISearchIndexDataContributorAssignment './modules/aiSearchRoleAssignment.bicep' = {
  name: 'projectAISearchIndexDataContributorAssignmentDeploy'
  params: {
    roleDefinitionId: azureAISearchIndexDataContributorRole.id
    principalId: foundry::project.identity.principalId
    existingAISearchAccountName: existingAISearchAccountName
  }
}

@description('Grant the Foundry application agent identity Cosmos DB Db Operator user role permissions.')
module projectDbCosmosDbOperatorAssignment './modules/cosmosdbRoleAssignment.bicep' = {
  name: 'projectDbCosmosDbOperatorAssignmentDeploy'
  params: {
    roleDefinitionId: cosmosDbOperatorRole.id
    principalId: foundry::project.identity.principalId
    existingCosmosDbAccountName: cosmosDbAccount.name
  }
}

// Sql Role Assignments

@description('Assign the Foundry application agent identity the ability to read and write data in all collections within enterprise_memory database.')
module projectContainersWriterSqlAssignment './modules/cosmosdbSqlRoleAssignment.bicep' = {
  name: 'projectContainersWriterSqlAssignmentDeploy'
  params: {
    roleDefinitionId: cosmosDbAccount::dataContributorRole.id
    principalId: foundry::project.identity.principalId
    existingCosmosDbAccountName: cosmosDbAccount.name
    existingCosmosDbName: 'enterprise_memory'
    existingCosmosCollectionTypeName: 'containers'
    scopeUserContainerId: scopeAllContainers
  }
}
  
// ---- Outputs ----

output aiAgentProjectName string = foundry::project.name

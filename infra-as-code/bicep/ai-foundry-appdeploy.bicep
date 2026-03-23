targetScope = 'resourceGroup'

@description('This is the base name for each Azure resource name (6-8 chars)')
@minLength(6)
@maxLength(8)
param baseName string

@description('The existing Agent version to target by the Foundry AI Agent Service application deployment.')
@minLength(1)
param agentVersion string = '1'

// ---- Existing resources ----

@description('Built-in Role: [Azure AI User](https://learn.microsoft.com/azure/ai-foundry/concepts/rbac-azure-ai-foundry?pivots=fdp-project#azure-ai-user)')
resource azureAiUserRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: '53ca6127-db72-4b80-b1b0-d745d6d5456d'
  scope: subscription()
}

@description('Existing App Service managed identity. Needs Azure AI User role on the Foundry project and Agent Application to invoke the published agent.')
resource appServiceManagedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' existing = {
  name: 'id-app-${baseName}'
}

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
  name: 'cdb-ai-agent-threads-${baseName}'

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

resource agentStorageAccount 'Microsoft.Storage/storageAccounts@2025-06-01' existing = {
  name: 'stagent${baseName}'
}

resource azureAiSearchService 'Microsoft.Search/searchServices@2025-02-01-preview' existing = {
  name: 'ais-ai-agent-vector-store-${baseName}'
}

@description('The internal ID of the project is used in the Azure Storage blob containers and in the Cosmos DB collections.')
#disable-next-line BCP053
var workspaceId = foundry::project.properties.internalId
var workspaceIdAsGuid = '${substring(workspaceId, 0, 8)}-${substring(workspaceId, 8, 4)}-${substring(workspaceId, 12, 4)}-${substring(workspaceId, 16, 4)}-${substring(workspaceId, 20, 12)}'

var scopeAllContainers = '/subscriptions/${subscription().subscriptionId}/resourceGroups/${resourceGroup().name}/providers/Microsoft.DocumentDB/databaseAccounts/${cosmosDbAccount.name}/dbs/enterprise_memory'

// ---- New resources ----

@description('Existing Foundry account.')
resource foundry 'Microsoft.CognitiveServices/accounts@2025-10-01-preview' existing  = {
  name: 'aif${baseName}'

  @description('Existing Foundry project. The application and deployment will be created as a child resource of this project.')
  resource project 'projects' existing = {
    name: 'projchat'

    @description('Create agent application in Foundry Agent Service.')
    resource application 'applications' = {
      name: 'appchat'
      properties: {
        agents: [
          {
            agentName: 'baseline-chatbot-agent'
          }
        ]
        #disable-next-line BCP078
        authorizationPolicy: {
          authorizationScheme: 'Default'
        }
        displayName: 'Example of an Agent Application that exposes a Foundry agent chat interface through a service endpoint'
        trafficRoutingPolicy: {
          protocol: 'FixedRatio'
          rules: [
            {
              deploymentId: ''
              description: 'Default rule routing all traffic'
              ruleId: 'default'
              trafficPercentage: 100
            }
          ]
        }
      }

      @description('Create agent application deployment in Foundry Agent Service.')
      resource deploymentApp 'agentDeployments' = {
        name: 'agentdeploychat'
        properties: {
          agents: [
            {
              agentName: 'baseline-chatbot-agent'
              agentVersion: agentVersion
            }
          ]
          displayName: 'Example of an agent deployment that runs an Agent Application referencing a specific agent version.'
          deploymentType: 'Managed' // prompt-based agent deployment
          protocols: [
            {
              protocol: 'Responses'
              version: '1.0'
            }
          ]
        }
        dependsOn: [
          agentBlobDataContributorAssignment
          agentBlobDataOwnerConditionalAssignment

          agentAISearchContributorAssignment
          agentAISearchIndexDataContributorAssignment

          agentDbCosmosDbOperatorAssignment
          agentContainersWriterSqlAssignment
        ]
      }
    }
  }
}

// Role assignments

@description('Grant the Foundry application agent identity Storage Account Blob Data Contributor user role permissions.')
module agentBlobDataContributorAssignment './modules/storageAccountRoleAssignment.bicep' = {
  name: 'agentBlobDataContributorAssignmentDeploy'
  params: {
    roleDefinitionId: storageBlobDataContributorRole.id
    principalId: foundry::project::application.properties.defaultInstanceIdentity.clientId
    existingStorageAccountName: agentStorageAccount.name
  }
}

@description('Grant the Foundry application agent identity the Storage Account Blob Data Owner user role permissions.')
module agentBlobDataOwnerConditionalAssignment './modules/storageAccountRoleAssignment.bicep' = {
  name: 'agentBlobDataOwnerConditionalAssignmentDeploy'
  params: {
    roleDefinitionId: storageBlobDataOwnerRole.id
    principalId: foundry::project::application.properties.defaultInstanceIdentity.clientId
    existingStorageAccountName: agentStorageAccount.name
    conditionVersion: '2.0'
    condition: '((!(ActionMatches{\'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/tags/read\'})  AND  !(ActionMatches{\'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/filter/action\'}) AND  !(ActionMatches{\'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/tags/write\'}) ) OR (@Resource[Microsoft.Storage/storageAccounts/blobServices/containers:name] StringStartsWithIgnoreCase \'${workspaceIdAsGuid}\'))'
  }
}

@description('Grant the Foundry application agent identity AI Search Contributor user role permissions.')
module agentAISearchContributorAssignment './modules/aiSearchRoleAssignment.bicep' = {
  name: 'agentAISearchContributorAssignmentDeploy'
  params: {
    roleDefinitionId: azureAISearchServiceContributorRole.id
    principalId: foundry::project::application.properties.defaultInstanceIdentity.clientId
    existingAISearchAccountName: azureAiSearchService.name
  }
}

@description('Grant the Foundry application agent identity AI Search Data Contributor user role permissions.')
module agentAISearchIndexDataContributorAssignment './modules/aiSearchRoleAssignment.bicep' = {
  name: 'agentAISearchIndexDataContributorAssignmentDeploy'
  params: {
    roleDefinitionId: azureAISearchIndexDataContributorRole.id
    principalId: foundry::project::application.properties.defaultInstanceIdentity.clientId
    existingAISearchAccountName: azureAiSearchService.name
  }
}

@description('Grant the Foundry application agent identity Cosmos DB Db Operator user role permissions.')
module agentDbCosmosDbOperatorAssignment './modules/cosmosdbRoleAssignment.bicep' = {
  name: 'agentDbCosmosDbOperatorAssignmentDeploy'
  params: {
    roleDefinitionId: cosmosDbOperatorRole.id
    principalId: foundry::project::application.properties.defaultInstanceIdentity.clientId
    existingCosmosDbAccountName: cosmosDbAccount.name
  }
}

// Sql Role Assignments

@description('Assign the Foundry application agent identity the ability to read and write data in all collections within enterprise_memory database.')
module agentContainersWriterSqlAssignment './modules/cosmosdbSqlRoleAssignment.bicep' = {
  name: 'agentContainersWriterSqlAssignmentDeploy'
  params: {
    roleDefinitionId: cosmosDbAccount::dataContributorRole.id
    principalId: foundry::project::application.properties.defaultInstanceIdentity.clientId
    existingCosmosDbAccountName: cosmosDbAccount.name
    existingCosmosDbName: 'enterprise_memory'
    existingCosmosCollectionTypeName: 'containers'
    scopeUserContainerId: scopeAllContainers
  }
}

@description('Grant the App Service managed identity Azure AI User role on the Foundry project. Required for Microsoft.MachineLearningServices/workspaces/agents/action when invoking a published agent.')
resource azureAiUserProjectRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: foundry::project
  name: guid(foundry::project.id, appServiceManagedIdentity.id, azureAiUserRole.id)
  properties: {
    roleDefinitionId: azureAiUserRole.id
    principalType: 'ServicePrincipal'
    principalId: appServiceManagedIdentity.properties.principalId
  }
}

@description('Grant the App Service managed identity Azure AI User role on the Agent Application for least-privilege invocation via the Responses API.')
resource azureAiUserAppRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: foundry::project::application
  name: guid(foundry::project::application.id, appServiceManagedIdentity.id, azureAiUserRole.id)
  properties: {
    roleDefinitionId: azureAiUserRole.id
    principalType: 'ServicePrincipal'
    principalId: appServiceManagedIdentity.properties.principalId
  }
}

// ---- Outputs ----
output agentApplicationBaseUrl string = foundry::project::application.properties.baseUrl

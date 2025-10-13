/*
  This template creates a sql role assignment for a managed identity to access dbs and containers in Cosmos Db.

  To ensure that each deployment has a unique role assignment ID, you can use the guid() function with a seed value that is based in part on the
  managed identity's principal ID. However, because Azure Resource Manager requires each resource's name to be available at the beginning of the deployment,
  you can't use this approach in the same Bicep file that defines the managed identity. This sample uses a Bicep module to work around this issue.
*/
@description('The Id of the role definition.')
param roleDefinitionId string

@description('The principalId property of the managed identity.')
param principalId string

@description('The existing Azure AI Foundry Project Id.')
@minLength(2)
param existingAiFoundryProjectId string

@description('The name of the existing Cosmos Db resource.')
param existingCosmosDbAccountName string

@description('The Cosmos Db name of the sql role assignment.')
param existingCosmosDbName string

@description('The Cosmos Db csontainer type name of the sql role assignment.')
param existingCosmosCollectionTypeName string

@description('The Id of the Scope of the sql role assignment.')
param scopeUserContainerId string

// ---- Existing resources ----
resource cosmosDbAccount 'Microsoft.DocumentDB/databaseAccounts@2025-05-01-preview' existing = {
  name: existingCosmosDbAccountName
}

// ---- Role assignment ----
@description('Assign the project\'s managed identity the ability to read and write data in this collection within enterprise_memory database.')
resource sqlRoleAssignment 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2025-05-01-preview' = {
  name: guid(resourceGroup().id, existingAiFoundryProjectId, principalId, roleDefinitionId, existingCosmosDbName, existingCosmosCollectionTypeName)
  parent: cosmosDbAccount
  properties: {
    roleDefinitionId: roleDefinitionId
    principalId: principalId
    scope: scopeUserContainerId
  }
}

/*
  This template creates a role assignment for a managed identity to access dbs in Cosmos Db.

  To ensure that each deployment has a unique role assignment ID, you can use the guid() function with a seed value that is based in part on the
  managed identity's principal ID. However, because Azure Resource Manager requires each resource's name to be available at the beginning of the deployment,
  you can't use this approach in the same Bicep file that defines the managed identity. This sample uses a Bicep module to work around this issue.
*/
@description('The Id of the role definition.')
param roleDefinitionId string

@description('The principalId property of the managed identity.')
param principalId string

@description('The name of the existing Cosmos Db resource.')
param existingCosmosDbAccountName string

// ---- Existing resources ----
resource cosmosDbAccount 'Microsoft.DocumentDB/databaseAccounts@2025-05-01-preview' existing = {
  name: existingCosmosDbAccountName
}

// ---- Role assignment ----
resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(cosmosDbAccount.id, principalId, roleDefinitionId)
  scope: cosmosDbAccount
  properties: {
    roleDefinitionId: roleDefinitionId
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

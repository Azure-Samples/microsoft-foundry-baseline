/*
  This template creates a role assignment for a managed identity to access blobs in Storage Account.

  To ensure that each deployment has a unique role assignment ID, you can use the guid() function with a seed value that is based in part on the
  managed identity's principal ID. However, because Azure Resource Manager requires each resource's name to be available at the beginning of the deployment,
  you can't use this approach in the same Bicep file that defines the managed identity. This sample uses a Bicep module to work around this issue.
*/
@description('The Id of the role definition.')
param roleDefinitionId string

@description('The principalId property of the managed identity.')
param principalId string

@description('The existing Azure Storage account that is going to be used as the Foundry Agent Service blob store (dependency).')
@minLength(3)
param existingStorageAccountName string

@description('The Azure Storage account role assignment conditions version.')
param conditionVersion string = ''

@description('The Azure Storage account role assignment conditions.')
param condition string = ''

// ---- Existing resources ----
resource agentStorageAccount 'Microsoft.Storage/storageAccounts@2025-01-01' existing = {
  name: existingStorageAccountName
}

// ---- Role assignment ----
resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(agentStorageAccount.id, principalId, roleDefinitionId)
  scope: agentStorageAccount
  properties: {
    roleDefinitionId: roleDefinitionId
    principalId: principalId
    principalType: 'ServicePrincipal'
    conditionVersion: conditionVersion != '' ? conditionVersion : null
    condition: condition != '' ? condition : null
  }
}

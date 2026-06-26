/*
  This template creates a role assignment for a managed identity to access secrets in Key Vault.

  To ensure that each deployment has a unique role assignment ID, you can use the guid() function with a seed value that is based in part on the
  managed identity's principal ID. However, because Azure Resource Manager requires each resource's name to be available at the beginning of the deployment,
  you can't use this approach in the same Bicep file that defines the managed identity. This sample uses a Bicep module to work around this issue.
*/
@description('The Id of the role definition.')
param roleDefinitionId string

@description('The principalId property of the managed identity.')
param principalId string

@description('The name of the Key Vault resource.')
param keyVaultName string

// ---- Existing resources ----
resource keyVault 'Microsoft.KeyVault/vaults@2026-02-01' existing = {
  name: keyVaultName
}

// ---- Role assignment ----
resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, principalId, roleDefinitionId)
  scope: keyVault
  properties: {
    roleDefinitionId: roleDefinitionId
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

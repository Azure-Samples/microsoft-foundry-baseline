/*
  This template creates a role assignment for a managed identity to access indexes in AI Search.

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

@description('The existing Azure AI Search account that is going to be used as the Azure AI Foundry Agent vector store (dependency).')
@minLength(1)
param existingAISearchAccountName string

// ---- Existing resources ----
resource azureAISearchService 'Microsoft.Search/searchServices@2025-02-01-preview' existing = {
  name: existingAISearchAccountName
}

// ---- Role assignment ----
resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, existingAiFoundryProjectId, azureAISearchService.id, principalId, roleDefinitionId)
  scope: azureAISearchService
  properties: {
    roleDefinitionId: roleDefinitionId
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

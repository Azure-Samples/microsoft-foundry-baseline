targetScope = 'resourceGroup'

@description('The region in which this architecture is deployed. Should match the region of the resource group.')
@minLength(1)
param location string = resourceGroup().location

@description('This is the base name for each Azure resource name (6-8 chars)')
@minLength(6)
@maxLength(8)
param baseName string

// ---- Existing resources ----

// ---- New resources ----

@description('The agent User Managed Identity for the AI Foundry Project.')
resource agentUserManagedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2025-01-31-preview' = {
  name: 'mi-agent-${baseName}'
  location: location
}

// Role assignments

// ---- Outputs ----

output agentUserManagedIdentityName string = agentUserManagedIdentity.name

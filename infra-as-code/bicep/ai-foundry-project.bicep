targetScope = 'resourceGroup'

@description('The region in which this architecture is deployed. Should match the region of the resource group.')
@minLength(1)
param location string = resourceGroup().location

@description('The existing Azure AI Foundry account. This project will become a child resource of this account.')
@minLength(2)
param existingAiFoundryName string

// ---- New resources ----

@description('Existing Azure AI Foundry account. The project will be created as a child resource of this account.')
resource aiFoundry 'Microsoft.CognitiveServices/accounts@2025-06-01' existing  = {
  name: existingAiFoundryName

  resource project 'projects' = {
    name: 'projchat'
    location: location
    identity: {
      type: 'SystemAssigned'
    }
    properties: {
      description: 'Chat using internet data in your Azure AI Foundry Agent.'
      displayName: 'Chat with Internet Data'
    }
  }
}

// ---- Outputs ----

output aiAgentProjectName string = aiFoundry::project.name
output aiAgentProjectPrincipalId string = aiFoundry::project.identity.principalId

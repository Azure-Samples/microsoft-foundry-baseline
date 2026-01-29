targetScope = 'resourceGroup'

@description('This is the base name for each Azure resource name (6-8 chars)')
@minLength(6)
@maxLength(8)
param baseName string

@description('The existing Agent version to target by the Foundry AI Agent Service application deployment.')
@minLength(1)
param agentVersion string = '1'

// ---- Existing resources ----

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
      }
    }
  }
}

// ---- Outputs ----
output agentApplicationBaseUrl string = foundry::project::application.properties.baseUrl

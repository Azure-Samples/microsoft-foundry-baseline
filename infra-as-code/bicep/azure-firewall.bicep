targetScope = 'resourceGroup'

@description('The region in which this architecture is deployed. Should match the region of the resource group.')
@minLength(1)
param location string = resourceGroup().location

@description('The name of the workload\'s virtual network in this resource group. Azure Firewall and it\'s management NIC will be deployed into this network.')
@minLength(1)
param virtualNetworkName string

@description('The name of the workload\'s existing Log Analytics workspace.')
@minLength(4)
param logAnalyticsWorkspaceName string

@description('The name of the subnet containing the Foundry agents. Must be in the same virtual network that is provided.')
@minLength(8)
param agentsEgressSubnetName string

@description('The name of the subnet containing your jump boxes. Must be in the same virtual network that is provided.')
@minLength(8)
param jumpBoxesSubnetName string

// ---- Existing resources ----

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2025-02-01' existing = {
  name: logAnalyticsWorkspaceName
}

@description('Existing virtual network.')
resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: virtualNetworkName

  resource agentsEgressSubnet 'subnets' existing = {
    name: agentsEgressSubnetName
  }

  resource jumpBoxesSubnet 'subnets' existing = {
    name: jumpBoxesSubnetName
  }

  resource firewallManagementSubnet 'subnets' existing = {
    name: 'AzureFirewallManagementSubnet'
  }

  resource firewall 'subnets' existing = {
    name: 'AzureFirewallSubnet'
  }
}

// ---- New resources ----

@description('The public IP address for all traffic egressing from the firewall. You can add more addresses if needed to reduce the chance for port exhaustion.')
resource publicIpForAzureFirewallEgress 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-firewall-egress-00'
  location: location
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  zones: pickZones('Microsoft.Network', 'publicIPAddresses', location, 3)
  properties: {
    publicIPAddressVersion: 'IPv4'
    publicIPAllocationMethod: 'Static'
    idleTimeoutInMinutes: 4
  }
}

@description('The public IP address for the Azure Firewall control plane.')
resource publicIpForAzureFirewallManagement 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-firewall-mgmt-00'
  location: location
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  zones: pickZones('Microsoft.Network', 'publicIPAddresses', location, 3)
  properties: {
    publicIPAddressVersion: 'IPv4'
    publicIPAllocationMethod: 'Static'
    idleTimeoutInMinutes: 4
  }
}

@description('The firewall rules assigned to our egress firewall.')
resource azureFirewallPolicy 'Microsoft.Network/firewallPolicies@2024-05-01' = {
  name: 'fw-egress-policy'
  location: location
  properties: {
    sku: {
      tier: 'Basic'
    }
    threatIntelMode: 'Alert'
  }

  @description('Add rules for the jump boxes subnet. Extend to support other subnets as needed.')
  resource networkRules 'ruleCollectionGroups' = {
    name: 'DefaultNetworkRuleCollectionGroup'
    properties: {
      priority: 200
      ruleCollections: [
        {
          ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
          name: 'jump-box-egress'
          priority: 1000
          action: {
            type: 'Allow'
          }
          rules: [
            {
              ruleType: 'NetworkRule'
              name: 'allow-dependencies'
              ipProtocols: ['Any']
              sourceAddresses: ['${virtualNetwork::jumpBoxesSubnet.properties.addressPrefix}']
              destinationAddresses: ['*'] // Production readiness change: tighten destination address to ensure egress traffic is restricted to the minimal required spaces.
              destinationPorts: ['*']
            }
          ]
        }
      ]
    }
  }

  @description('Add rules for the Foundry Agent Service egress and jump boxes subnets. Extend to support other subnets as needed.')
  resource applicationRules 'ruleCollectionGroups' = {
    name: 'DefaultApplicationRuleCollectionGroup'
    properties: {
      priority: 300
      ruleCollections: [
        {
          ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
          name: 'agent-egress'
          priority: 1000
          action: {
            type: 'Allow'
          }
          rules: [
            {
              ruleType: 'ApplicationRule'
              name: 'allow-dependencies'
              protocols: [
                {
                  protocolType: 'Https'
                  port: 443
                }
              ]
              fqdnTags: []
              webCategories: []
              targetFqdns: [
                 '*'
                 // 'api.example.org' // Production readiness change: refine your target FQDNs to restrict egress traffic exclusively to the external services and endpoints your agent depends on.
              ]
              targetUrls: []
              terminateTLS: false
              sourceAddresses: ['${virtualNetwork::agentsEgressSubnet.properties.addressPrefix}']
              destinationAddresses: []
              httpHeadersToInsert: []
            }
          ]
        }
        {
          ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
          name: 'jump-box-egress'
          priority: 1100
          action: {
            type: 'Allow'
          }
          rules: [
            {
              ruleType: 'ApplicationRule'
              name: 'allow-dependencies'
              protocols: [
                {
                  protocolType: 'Https'
                  port: 443
                }
                {
                  protocolType: 'Http'
                  port: 80
                }
              ]
              fqdnTags: []
              webCategories: []
              targetFqdns: ['*'] // Production readiness change: specify target FQDNs to ensure only approved resources can be accessed from your jumpbox.
              targetUrls: []
              terminateTLS: false
              sourceAddresses: ['${virtualNetwork::jumpBoxesSubnet.properties.addressPrefix}']
              destinationAddresses: []
              httpHeadersToInsert: []
            }
          ]
        }
      ]
    }
    dependsOn: [
      networkRules
    ]
  }
}

@description('Our workload\'s egress firewall. This is used to control outbound traffic from the workload to the Internet.')
resource azureFirewall 'Microsoft.Network/azureFirewalls@2024-05-01' = {
  name: 'fw-egress'
  location: location
  zones: pickZones('Microsoft.Network', 'azureFirewalls', location, 3)
  properties: {
    sku: {
      name: 'AZFW_VNet'
      tier: 'Basic'
    }
    threatIntelMode: 'Alert'
    additionalProperties: {}
    managementIpConfiguration: {
      name: publicIpForAzureFirewallManagement.name
      properties: {
        publicIPAddress: {
          id: publicIpForAzureFirewallManagement.id
        }
        subnet: {
          id: virtualNetwork::firewallManagementSubnet.id
        }
      }
    }
    ipConfigurations: [
      {
        name: publicIpForAzureFirewallEgress.name
        properties: {
          publicIPAddress: {
            id: publicIpForAzureFirewallEgress.id
          }
          subnet: {
            id: virtualNetwork::firewall.id
          }
        }
      }
    ]
    firewallPolicy: {
      id: azureFirewallPolicy.id
    }
  }
  dependsOn: [
    azureFirewallPolicy::applicationRules
    azureFirewallPolicy::networkRules
  ]
}

resource egressRouteTable 'Microsoft.Network/routeTables@2024-05-01' existing = {
  name: 'udr-internet-to-firewall'

  resource internetToFirewall 'routes' = {
    name: 'internet-to-firewall'
    properties: {
      addressPrefix: '0.0.0.0/0'
      nextHopType: 'VirtualAppliance'
      nextHopIpAddress: azureFirewall.properties.ipConfigurations[0].properties.privateIPAddress
    }
  }
}

// Azure diagnostics

resource azureDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'default'
  scope: azureFirewall
  properties: {
    workspaceId: logAnalyticsWorkspace.id
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        category: 'AzureFirewallApplicationRule'
        enabled: true
        retentionPolicy: {
          days: 0
          enabled: false
        }
      }
      {
        category: 'AzureFirewallNetworkRule'
        enabled: true
        retentionPolicy: {
          days: 0
          enabled: false
        }
      }
      {
        category: 'AzureFirewallDnsProxy'
        enabled: true
        retentionPolicy: {
          days: 0
          enabled: false
        }
      }
      {
        category: 'AZFWNetworkRule'
        enabled: true
        retentionPolicy: {
          days: 0
          enabled: false
        }
      }
      {
        category: 'AZFWApplicationRule'
        enabled: true
        retentionPolicy: {
          days: 0
          enabled: false
        }
      }
      {
        category: 'AZFWNatRule'
        enabled: true
        retentionPolicy: {
          days: 0
          enabled: false
        }
      }
      {
        category: 'AZFWThreatIntel'
        enabled: true
        retentionPolicy: {
          days: 0
          enabled: false
        }
      }
      {
        category: 'AZFWIdpsSignature'
        enabled: true
        retentionPolicy: {
          days: 0
          enabled: false
        }
      }
      {
        category: 'AZFWDnsQuery'
        enabled: true
        retentionPolicy: {
          days: 0
          enabled: false
        }
      }
      {
        category: 'AZFWFqdnResolveFailure'
        enabled: true
        retentionPolicy: {
          days: 0
          enabled: false
        }
      }
      {
        category: 'AZFWFatFlow'
        enabled: true
        retentionPolicy: {
          days: 0
          enabled: false
        }
      }
      {
        category: 'AZFWFlowTrace'
        enabled: true
        retentionPolicy: {
          days: 0
          enabled: false
        }
      }
      {
        category: 'AZFWApplicationRuleAggregation'
        enabled: true
        retentionPolicy: {
          days: 0
          enabled: false
        }
      }
      {
        category: 'AZFWNetworkRuleAggregation'
        enabled: true
        retentionPolicy: {
          days: 0
          enabled: false
        }
      }
      {
        category: 'AZFWNatRuleAggregation'
        enabled: true
        retentionPolicy: {
          days: 0
          enabled: false
        }
      }
    ]
  }
}

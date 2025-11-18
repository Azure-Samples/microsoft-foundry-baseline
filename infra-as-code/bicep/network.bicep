targetScope = 'resourceGroup'

/*
  Establish the private network for the workload.
*/

@description('The region in which this architecture is deployed. Should match the region of the resource group.')
@minLength(1)
param location string = resourceGroup().location

// Foundry Agent Service currently has a limitation on subnet prefixes.
// 10.x was not supported, as such 192.168.x.x was used.
var virtualNetworkAddressPrefix = '192.168.0.0/16'
var appGatewaySubnetPrefix = '192.168.1.0/24'
var appServicesSubnetPrefix = '192.168.0.0/24'
var privateEndpointsSubnetPrefix = '192.168.2.0/27'
var buildAgentsSubnetPrefix = '192.168.2.32/27'
var bastionSubnetPrefix = '192.168.2.64/26'
var jumpBoxSubnetPrefix = '192.168.2.128/28'
var aiAgentsEgressSubnetPrefix = '192.168.3.0/24'
var azureFirewallSubnetPrefix = '192.168.4.0/26'
var azureFirewallManagementSubnetPrefix = '192.168.4.64/26'

var enableDdosProtection = false // Production readiness change: protect your public IPs in this architecture with DDoS protection by setting this to true.

// ---- New resources ----

// DDoS Protection Plan
// Cost optimization: DDoS protection plans are relatively expensive. If deploying this as part of
// a POC and your environment can be down during a targeted DDoS attack, consider not deploying
// this resource by setting `enableDdosProtection` to false.
resource ddosProtectionPlan 'Microsoft.Network/ddosProtectionPlans@2024-01-01' = if (enableDdosProtection) {
  name: 'ddos-workload'
  location: location
  properties: {}
}

@description('Virtual Network for the workload. Contains subnets for App Gateway, App Service Plan, Private Endpoints, Build Agents, Bastion Host, Jump Box, and Foundry Agents Service.')
resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-workload'
  location: location
  properties: {
    enableDdosProtection: enableDdosProtection
    ddosProtectionPlan: enableDdosProtection ? { id: ddosProtectionPlan.id } : null
    encryption: {
      enabled: false
      enforcement: 'AllowUnencrypted'
    }
    addressSpace: {
      addressPrefixes: [
        virtualNetworkAddressPrefix
      ]
    }
    subnets: [
      {
        // App services plan subnet
        name: 'snet-appServicePlan'
        properties: {
          defaultOutboundAccess: false
          addressPrefix: appServicesSubnetPrefix
          delegations: [
            {
              name: 'delegation'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
          networkSecurityGroup: {
            id: appServiceSubnetNsg.id
          }
        }
      }
      {
        // App Gateway subnet
        name: 'snet-appGateway'
        properties: {
          defaultOutboundAccess: false
          addressPrefix: appGatewaySubnetPrefix
          delegations: []
          networkSecurityGroup: {
            id: appGatewaySubnetNsg.id
          }
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
        }
      }
      {
        // Private endpoints subnet
        name: 'snet-privateEndpoints'
        properties: {
          addressPrefix: privateEndpointsSubnetPrefix
          delegations: []
          networkSecurityGroup: {
            id: privateEndpointsSubnetNsg.id
          }
          privateEndpointNetworkPolicies: 'Enabled' // Route Table and NSGs
          privateLinkServiceNetworkPolicies: 'Enabled'
          defaultOutboundAccess: false // This subnet should never be the source of egress traffic.
          routeTable: {
            id: egressRouteTable.id
          }
        }
      }
      {
        // Build agents subnet
        name: 'snet-buildAgents'
        properties: {
          addressPrefix: buildAgentsSubnetPrefix
          delegations: []
          networkSecurityGroup: {
            id: buildAgentsSubnetNsg.id
          }
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
          defaultOutboundAccess: false // Force your build agent traffic through your firewall.
          routeTable: {
            id: egressRouteTable.id
          }
        }
      }
      {
        // Azure Bastion subnet
        name: 'AzureBastionSubnet'
        properties: {
          addressPrefix: bastionSubnetPrefix
          delegations: []
          networkSecurityGroup: {
            id: bastionSubnetNsg.id
          }
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
          defaultOutboundAccess: false
        }
      }
      {
        // Jump box virtual machine subnet
        name: 'snet-jumpBoxes'
        properties: {
          addressPrefix: jumpBoxSubnetPrefix
          delegations: []
          networkSecurityGroup: {
            id: jumpBoxSubnetNsg.id
          }
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
          defaultOutboundAccess: false // Force agent traffic through your firewall.
          routeTable: {
            id: egressRouteTable.id
          }
        }
      }
      {
        // Foundry Agent Service subnet for egress traffic
        name: 'snet-agentsEgress'
        properties: {
          addressPrefix: aiAgentsEgressSubnetPrefix
          delegations: [
            {
              name: 'Microsoft.App/environments'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
          networkSecurityGroup: {
            id: azureAiAgentServiceSubnetNsg.id
          }
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
          defaultOutboundAccess: false // Force agent traffic through your firewall.
          routeTable: {
            id: egressRouteTable.id
          }
        }
      }
      {
        // Workload firewall for all egress traffic
        name: 'AzureFirewallSubnet'
        properties: {
          defaultOutboundAccess: false
          addressPrefix: azureFirewallSubnetPrefix
          delegations: []
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
        }
      }
      {
        // Workload firewall for all egress traffic
        name: 'AzureFirewallManagementSubnet'
        properties: {
          defaultOutboundAccess: false
          addressPrefix: azureFirewallManagementSubnetPrefix
          delegations: []
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
        }
      }
    ]
  }

  resource appGatewaySubnet 'subnets' existing = {
    name: 'snet-appGateway'
  }

  resource appServiceSubnet 'subnets' existing = {
    name: 'snet-appServicePlan'
  }

  resource privateEndpointsSubnet 'subnets' existing = {
    name: 'snet-privateEndpoints'
  }

  resource buildAgentsSubnet 'subnets' existing = {
    name: 'snet-buildAgents'
  }

  resource jumpBoxSubnet 'subnets' existing = {
    name: 'snet-jumpBoxes'
  }

  resource agentsEgressSubnet 'subnets' existing = {
    name: 'snet-agentsEgress'
  }
}

@description('The App Gateway subnet NSG')
resource appGatewaySubnetNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-appGatewaySubnet'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AppGw.In.Allow.ControlPlane'
        properties: {
          description: 'Allow inbound Control Plane (https://docs.microsoft.com/azure/application-gateway/configuration-infrastructure#network-security-groups)'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '65200-65535'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 100
          direction: 'Inbound'
        }
      }
      {
        name: 'AppGw.In.Allow443.Internet'
        properties: {
          description: 'Allow ALL inbound web traffic on port 443'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'Internet'
          destinationAddressPrefix: appGatewaySubnetPrefix
          access: 'Allow'
          priority: 110
          direction: 'Inbound'
        }
      }
      {
        name: 'AppGw.In.Allow.LoadBalancer'
        properties: {
          description: 'Allow inbound traffic from azure load balancer'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'AzureLoadBalancer'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 120
          direction: 'Inbound'
        }
      }
      {
        name: 'DenyAllInBound'
        properties: {
          protocol: '*'
          sourcePortRange: '*'
          sourceAddressPrefix: '*'
          destinationPortRange: '*'
          destinationAddressPrefix: '*'
          access: 'Deny'
          priority: 1000
          direction: 'Inbound'
        }
      }
      {
        name: 'AppGw.Out.Allow.PrivateEndpoints'
        properties: {
          description: 'Allow outbound traffic from the App Gateway subnet to the Private Endpoints subnet.'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: appGatewaySubnetPrefix
          destinationAddressPrefix: privateEndpointsSubnetPrefix
          access: 'Allow'
          priority: 100
          direction: 'Outbound'
        }
      }
      {
        name: 'AppPlan.Out.Allow.AzureMonitor'
        properties: {
          description: 'Allow outbound traffic from the App Gateway subnet to Azure Monitor'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: appGatewaySubnetPrefix
          destinationAddressPrefix: 'AzureMonitor'
          access: 'Allow'
          priority: 110
          direction: 'Outbound'
        }
      }
    ]
  }
}

@description('The App Service subnet NSG')
resource appServiceSubnetNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-appServicesSubnet'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AppPlan.Out.Allow.PrivateEndpoints'
        properties: {
          description: 'Allow outbound traffic from the app service subnet to the private endpoints subnet'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: appServicesSubnetPrefix
          destinationAddressPrefix: privateEndpointsSubnetPrefix
          access: 'Allow'
          priority: 100
          direction: 'Outbound'
        }
      }
      {
        name: 'AppPlan.Out.Allow.AzureMonitor'
        properties: {
          description: 'Allow outbound traffic from App service to the AzureMonitor ServiceTag.'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: appServicesSubnetPrefix
          destinationAddressPrefix: 'AzureMonitor'
          access: 'Allow'
          priority: 110
          direction: 'Outbound'
        }
      }
    ]
  }
}

@description('The Private endpoints subnet NSG')
resource privateEndpointsSubnetNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-privateEndpointsSubnet'
  location: location
  properties: {
    securityRules: [
      {
        name: 'DenyAllOutBound'
        properties: {
          description: 'Deny outbound traffic from the private endpoints subnet'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: privateEndpointsSubnetPrefix
          destinationAddressPrefix: '*'
          access: 'Deny'
          priority: 1000
          direction: 'Outbound'
        }
      }
    ]
  }
}

@description('The Build agents subnet NSG')
resource buildAgentsSubnetNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-buildAgentsSubnet'
  location: location
  properties: {
    securityRules: [
      {
        name: 'DenyAllOutBound'
        properties: {
          description: 'Deny outbound traffic from the build agents subnet. Note: adjust rules as needed based on the resources added to the subnet'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: buildAgentsSubnetPrefix
          destinationAddressPrefix: '*'
          access: 'Deny'
          priority: 1000
          direction: 'Outbound'
        }
      }
    ]
  }
}

@description('The Foundry Agent Service egress subnet NSG')
resource azureAiAgentServiceSubnetNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-agentsEgressSubnet'
  location: location
  properties: {
    securityRules: [
      {
        name: 'DenyAllInBound'
        properties: {
          protocol: '*'
          sourcePortRange: '*'
          sourceAddressPrefix: '*'
          destinationPortRange: '*'
          destinationAddressPrefix: '*'
          access: 'Deny'
          priority: 1000
          direction: 'Inbound'
        }
      }
      {
        name: 'Agents.Out.Allow.PrivateEndpoints'
        properties: {
          description: 'Allow outbound traffic from the Foundry Agent egress subnet to the Private Endpoints subnet.'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: aiAgentsEgressSubnetPrefix
          destinationAddressPrefix: privateEndpointsSubnetPrefix
          access: 'Allow'
          priority: 100
          direction: 'Outbound'
        }
      }
      {
        name: 'Agents.Out.AllowTcp443.Internet'
        properties: {
          description: 'Allow outbound traffic from the Foundry Agent egress subnet to Internet on 443 (Azure firewall to filter further)'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: aiAgentsEgressSubnetPrefix
          destinationAddressPrefix: 'Internet'
          access: 'Allow'
          priority: 110
          direction: 'Outbound'
        }
      }
      {
        name: 'DenyAllOutBound'
        properties: {
          description: 'Deny all other outbound traffic from the Foundry Agent Service subnet.'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: aiAgentsEgressSubnetPrefix
          destinationAddressPrefix: '*'
          access: 'Deny'
          priority: 1000
          direction: 'Outbound'
        }
      }
    ]
  }
}

// Bastion host subnet NSG
// https://learn.microsoft.com/azure/bastion/bastion-nsg
// https://github.com/Azure/azure-quickstart-templates/blob/master/quickstarts/microsoft.network/azure-bastion-nsg/main.bicep
resource bastionSubnetNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-bastionSubnet'
  location: location
  properties: {
    securityRules: [
      {
        name: 'Bastion.In.Allow.Https'
        properties: {
          description: 'Allow inbound Https traffic from the from the Internet to the Bastion Host'
          protocol: 'Tcp'
          sourcePortRange: '*'
          sourceAddressPrefix: 'Internet'
          destinationPortRange: '443'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 100
          direction: 'Inbound'
        }
      }
      {
        name: 'Bastion.In.Allow.GatewayManager'
        properties: {
          protocol: 'Tcp'
          sourcePortRange: '*'
          sourceAddressPrefix: 'GatewayManager'
          destinationPortRanges: [
            '443'
            '4443'
          ]
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 110
          direction: 'Inbound'
        }
      }
      {
        name: 'Bastion.In.Allow.LoadBalancer'
        properties: {
          protocol: 'Tcp'
          sourcePortRange: '*'
          sourceAddressPrefix: 'AzureLoadBalancer'
          destinationPortRange: '443'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 120
          direction: 'Inbound'
        }
      }
      {
        name: 'Bastion.In.Allow.BastionHostCommunication'
        properties: {
          protocol: '*'
          sourcePortRange: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: [
            '8080'
            '5701'
          ]
          destinationAddressPrefix: 'VirtualNetwork'
          access: 'Allow'
          priority: 130
          direction: 'Inbound'
        }
      }
      {
        name: 'DenyAllInBound'
        properties: {
          protocol: '*'
          sourcePortRange: '*'
          sourceAddressPrefix: '*'
          destinationPortRange: '*'
          destinationAddressPrefix: '*'
          access: 'Deny'
          priority: 1000
          direction: 'Inbound'
        }
      }
      {
        name: 'Bastion.Out.Allow.SshRdp'
        properties: {
          description: 'Allow outbound RDP and SSH from the Bastion Host subnet to elsewhere in the vnet'
          protocol: 'Tcp'
          sourcePortRange: '*'
          sourceAddressPrefix: '*'
          destinationPortRanges: [
            '22'
            '3389'
          ]
          destinationAddressPrefix: 'VirtualNetwork'
          access: 'Allow'
          priority: 100
          direction: 'Outbound'
        }
      }
      {
        name: 'Bastion.Out.Allow.AzureMonitor'
        properties: {
          description: 'Allow outbound traffic from the Bastion Host subnet to Azure Monitor'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: bastionSubnetPrefix
          destinationAddressPrefix: 'AzureMonitor'
          access: 'Allow'
          priority: 110
          direction: 'Outbound'
        }
      }
      {
        name: 'Bastion.Out.Allow.AzureCloudCommunication'
        properties: {
          protocol: 'Tcp'
          sourcePortRange: '*'
          sourceAddressPrefix: '*'
          destinationPortRange: '443'
          destinationAddressPrefix: 'AzureCloud'
          access: 'Allow'
          priority: 120
          direction: 'Outbound'
        }
      }
      {
        name: 'Bastion.Out.Allow.BastionHostCommunication'
        properties: {
          protocol: '*'
          sourcePortRange: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: [
            '8080'
            '5701'
          ]
          destinationAddressPrefix: 'VirtualNetwork'
          access: 'Allow'
          priority: 130
          direction: 'Outbound'
        }
      }
      {
        name: 'Bastion.Out.Allow.GetSessionInformation'
        properties: {
          protocol: '*'
          sourcePortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRanges: [
            '80'
            '443'
          ]
          access: 'Allow'
          priority: 140
          direction: 'Outbound'
        }
      }
      {
        name: 'DenyAllOutBound'
        properties: {
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
          access: 'Deny'
          priority: 1000
          direction: 'Outbound'
        }
      }
    ]
  }
}

@description('The Jump box subnet NSG')
resource jumpBoxSubnetNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-jumpBoxesSubnet'
  location: location
  properties: {
    securityRules: [
      {
        name: 'JumpBox.In.Allow.SshRdp'
        properties: {
          description: 'Allow inbound RDP and SSH from the Bastion Host subnet'
          protocol: 'Tcp'
          sourcePortRange: '*'
          sourceAddressPrefix: bastionSubnetPrefix
          destinationPortRanges: [
            '22'
            '3389'
          ]
          destinationAddressPrefix: jumpBoxSubnetPrefix
          access: 'Allow'
          priority: 100
          direction: 'Inbound'
        }
      }
      {
        name: 'JumpBox.Out.Allow.PrivateEndpoints'
        properties: {
          description: 'Allow outbound traffic from the jump box subnet to the Private Endpoints subnet.'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: jumpBoxSubnetPrefix
          destinationAddressPrefix: privateEndpointsSubnetPrefix
          access: 'Allow'
          priority: 100
          direction: 'Outbound'
        }
      }
      {
        name: 'JumpBox.Out.Allow.Internet'
        properties: {
          description: 'Allow outbound traffic from all VMs to Internet'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: jumpBoxSubnetPrefix
          destinationAddressPrefix: 'Internet'
          access: 'Allow'
          priority: 130
          direction: 'Outbound'
        }
      }
      {
        name: 'DenyAllOutBound'
        properties: {
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: jumpBoxSubnetPrefix
          destinationAddressPrefix: '*'
          access: 'Deny'
          priority: 1000
          direction: 'Outbound'
        }
      }
    ]
  }
}

@description('Placeholder route table for egress traffic from subnets that we want to control routing for. When the firewall is created, the routes will be added.')
resource egressRouteTable 'Microsoft.Network/routeTables@2024-05-01' = {
  name: 'udr-internet-to-firewall'
  location: location
  properties: {
    disableBgpRoutePropagation: true
  }
}

// Create and link Private DNS Zones used in this workload

@description('Foundry related private DNS zone')
resource cognitiveServicesPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.cognitiveservices.azure.com'
  location: 'global'
  properties: {}

  resource link 'virtualNetworkLinks' = {
    name: 'cognitiveservices'
    location: 'global'
    properties: {
      virtualNetwork: {
        id: virtualNetwork.id
      }
      registrationEnabled: false
    }
  }
}

@description('Foundry related private DNS zone')
resource foundryPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.services.ai.azure.com'
  location: 'global'
  properties: {}

  resource link 'virtualNetworkLinks' = {
    name: 'aifoundry'
    location: 'global'
    properties: {
      virtualNetwork: {
        id: virtualNetwork.id
      }
      registrationEnabled: false
    }
  }
}

@description('Foundry related private DNS zone')
resource azureOpenAiPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.openai.azure.com'
  location: 'global'
  properties: {}

  resource link 'virtualNetworkLinks' = {
    name: 'azureopenai'
    location: 'global'
    properties: {
      virtualNetwork: {
        id: virtualNetwork.id
      }
      registrationEnabled: false
    }
  }
}

@description('Azure AI Search private DNS zone')
resource aiSearchPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.search.windows.net'
  location: 'global'
  properties: {}

  resource link 'virtualNetworkLinks' = {
    name: 'aisearch'
    location: 'global'
    properties: {
      virtualNetwork: {
        id: virtualNetwork.id
      }
      registrationEnabled: false
    }
  }
}

@description('Blob Storage private DNS zone')
resource blobStoragePrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.blob.${environment().suffixes.storage}'
  location: 'global'
  properties: {}

  resource link 'virtualNetworkLinks' = {
    name: 'blobstorage'
    location: 'global'
    properties: {
      virtualNetwork: {
        id: virtualNetwork.id
      }
      registrationEnabled: false
    }
  }
}

@description('Cosmos DB private DNS zone')
resource cosmosDbPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.documents.azure.com'
  location: 'global'
  properties: {}

  resource link 'virtualNetworkLinks' = {
    name: 'cosmosdb'
    location: 'global'
    properties: {
      virtualNetwork: {
        id: virtualNetwork.id
      }
      registrationEnabled: false
    }
  }
}

@description('Azure Key Vault private DNS zone')
resource keyVaultPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.vaultcore.azure.net' //Cannot use 'privatelink.${environment().suffixes.keyvaultDns}', per https://github.com/Azure/bicep/issues/9708
  location: 'global'
  properties: {}

  resource link 'virtualNetworkLinks' = {
    name: 'keyvault'
    location: 'global'
    properties: {
      virtualNetwork: {
        id: virtualNetwork.id
      }
      registrationEnabled: false
    }
  }
}

resource appServicePrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.azurewebsites.net'
  location: 'global'
  properties: {}

  resource link 'virtualNetworkLinks' = {
    name: 'webapp'
    location: 'global'
    properties: {
      virtualNetwork: {
        id: virtualNetwork.id
      }
      registrationEnabled: false
    }
  }
}

// ---- Outputs ----

@description('The name of the virtual network.')
output virtualNetworkName string = virtualNetwork.name

@description('The name of the app service plan subnet.')
output appServicesSubnetName string = virtualNetwork::appServiceSubnet.name

@description('The name of the Azure Application Gateway subnet.')
output applicationGatewaySubnetName string = virtualNetwork::appGatewaySubnet.name

@description('The name of the private endpoints subnet.')
output privateEndpointsSubnetName string = virtualNetwork::privateEndpointsSubnet.name

@description('The name of the jump boxes subnet.')
output jumpBoxesSubnetName string = virtualNetwork::jumpBoxSubnet.name

@description('The name of the build agents subnet.')
output buildAgentsSubnetName string = virtualNetwork::buildAgentsSubnet.name

@description('The name of the Foundry Agent Service egress subnet.')
output agentsEgressSubnetName string = virtualNetwork::agentsEgressSubnet.name

@description('The resource ID of the Foundry Agents Service egress subnet.')
output agentsEgressSubnetResourceId string = virtualNetwork::agentsEgressSubnet.id

@description('The resource ID of the private endpoints subnet.')
output privateEndpointsSubnetResourceId string = virtualNetwork::privateEndpointsSubnet.id

@description('The name of the subnet for jump boxes.')
output jumpBoxSubnetName string = virtualNetwork::jumpBoxSubnet.name

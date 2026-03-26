targetScope = 'resourceGroup'

/*
  Deploy an Azure Application Gateway with WAF v2 and a custom domain name.
*/

@description('The region in which this architecture is deployed. Should match the region of the resource group.')
@minLength(1)
param location string = resourceGroup().location

@description('This is the base name for each Azure resource name (6-8 chars)')
@minLength(6)
@maxLength(8)
param baseName string

@description('The name of the workload\'s existing Log Analytics workspace.')
@minLength(4)
param logAnalyticsWorkspaceName string

@description('Domain name to use for App Gateway')
param customDomainName string

@description('The name of the existing virtual network that this Application Gateway instance will be deployed into.')
@minLength(1)
param virtualNetworkName string

@description('The name of the existing subnet for Application Gateway. Must in in the provided virtual network and sized appropriately.')
param applicationGatewaySubnetName string

@description('The name of the existing webapp that will be the backend origin for the primary Application Gateway route.')
param appName string

@description('The name of the existing Key Vault that contains the SSL certificate for the Application Gateway.')
param keyVaultName string

@description('The name of the existing Key Vault secret that contains the SSL certificate for the Application Gateway.')
#disable-next-line secure-secrets-in-params
param gatewayCertSecretKey string

//variables
var appGatewayName = 'agw-${baseName}'
var appGatewayManagedIdentityName = 'id-${appGatewayName}'
var appGatewayPublicIpName = 'pip-${baseName}'
var appGatewayFqdn = 'fe-${baseName}'
var wafPolicyName= 'waf-${baseName}'

// ---- Existing resources ----

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' existing =  {
  name: virtualNetworkName

  resource applicationGatewaySubnet 'subnets' existing = {
    name: applicationGatewaySubnetName
  }
}

resource webApp 'Microsoft.Web/sites@2024-04-01' existing = {
  name: appName
}

resource logWorkspace 'Microsoft.OperationalInsights/workspaces@2025-02-01' existing = {
  name: logAnalyticsWorkspaceName
}

resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' existing = {
  name: keyVaultName

  resource kvsGatewayPublicCert 'secrets' existing = {
    name: gatewayCertSecretKey
  }
}

@description('Built-in Role: [Key Vault Secrets User](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles#key-vault-secrets-user)')
resource keyVaultSecretsUserRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: '4633458b-17de-408a-b874-0445c86b69e6'
  scope: subscription()
}

// ---- New resources ----

// Managed Identity for App Gateway.
resource appGatewayManagedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: appGatewayManagedIdentityName
  location: location
}

@description('Grant the Application Gateway managed identity Key Vault secrets user role permissions. This allows pulling certificates.')
module grantAppGatewaySecretsUserRoleAssignment './modules/keyvaultRoleAssignment.bicep' = {
  name: 'appGatewaySecretsUserRoleAssignmentDeploy'
  params: {
    roleDefinitionId: keyVaultSecretsUserRole.id
    principalId: appGatewayManagedIdentity.properties.principalId
    keyVaultName: keyVaultName
  }
}

//External IP for App Gateway
resource appGatewayPublicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: appGatewayPublicIpName
  location: location
  zones: pickZones('Microsoft.Network', 'publicIPAddresses', location, 3)
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAddressVersion: 'IPv4'
    publicIPAllocationMethod: 'Static'
    idleTimeoutInMinutes: 4
    dnsSettings: {
      domainNameLabel: appGatewayFqdn
    }
  }
}

//WAF policy definition
resource wafPolicy 'Microsoft.Network/ApplicationGatewayWebApplicationFirewallPolicies@2024-05-01' = {
  name: wafPolicyName
  location: location
  properties: {
    policySettings: {
      requestBodyCheck: true
      requestBodyEnforcement: true
      maxRequestBodySizeInKb: 128
      requestBodyInspectLimitInKB: 128
      fileUploadLimitInMb: 10
      fileUploadEnforcement: true
      jsChallengeCookieExpirationInMins: 30
      state: 'Enabled'
      mode: 'Prevention'
    }
    managedRules: {
      managedRuleSets: [
        {
          ruleSetType: 'Microsoft_DefaultRuleSet'
          ruleSetVersion: '2.1'
          ruleGroupOverrides: []
        }
        {
          ruleSetType: 'Microsoft_BotManagerRuleSet'
          ruleSetVersion: '1.1'
          ruleGroupOverrides: []
        }
      ]
      // AI chat conversations naturally contain markdown, code snippets, and special characters
      // in assistant responses that trigger false positives across multiple OWASP rule categories
      // (SQLi, protocol attack, XSS, etc.). The anomaly score accumulates across multi-turn
      // conversations until WAF blocks the request (HTTP 403). This exclusion bypasses content-
      // inspection rules for the "content" JSON field in the request body. When Azure WAF
      // releases an AI/chat-aware rule set, revisit this exclusion.
      exclusions: [
        {
          matchVariable: 'RequestArgValues'
          selectorMatchOperator: 'Contains'
          selector: 'content'
          exclusionManagedRuleSets: [
            {
              ruleSetType: 'Microsoft_DefaultRuleSet'
              ruleSetVersion: '2.1'
              ruleGroups: [
                { ruleGroupName: 'SQLI' }
                { ruleGroupName: 'MS-ThreatIntel-SQLI' }
                { ruleGroupName: 'PROTOCOL-ATTACK' }
                { ruleGroupName: 'XSS' }
                { ruleGroupName: 'RCE' }
                { ruleGroupName: 'LFI' }
                { ruleGroupName: 'RFI' }
                { ruleGroupName: 'PHP' }
                { ruleGroupName: 'MS-ThreatIntel-AppSec' }
                { ruleGroupName: 'MS-ThreatIntel-WebShells' }
                { ruleGroupName: 'MS-ThreatIntel-CVEs' }
              ]
            }
          ]
        }
      ]
    }
  }
}

//App Gateway
resource appGateway 'Microsoft.Network/applicationGateways@2024-05-01' = {
  name: appGatewayName
  location: location
  zones: pickZones('Microsoft.Network', 'applicationGateways', location, 3)
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${appGatewayManagedIdentity.id}': {}
    }
  }
  properties: {
    sku: {
      name: 'WAF_v2'
      tier: 'WAF_v2'
    }
    sslPolicy: {
      policyType: 'Custom'
      cipherSuites: [
        'TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384'
        'TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256'
      ]
      minProtocolVersion: 'TLSv1_2'
    }

    gatewayIPConfigurations: [
      {
        name: 'appGatewayIpConfig'
        properties: {
          subnet: {
            id: virtualNetwork::applicationGatewaySubnet.id
          }
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'appGwPublicFrontendIp'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: appGatewayPublicIp.id
          }
        }
      }
    ]
    frontendPorts: [
      {
        name: 'port-443'
        properties: {
          port: 443
        }
      }
    ]
    probes: [
      {
        name: 'probe-web${baseName}'
        properties: {
          protocol: 'Https'
          path: '/favicon.ico'
          interval: 30
          timeout: 30
          unhealthyThreshold: 3
          pickHostNameFromBackendHttpSettings: true
          minServers: 0
          match: {
            statusCodes: [
              '200-399'
              '401'
              '403'
            ]
          }
        }
      }
    ]
    firewallPolicy: {
      id: wafPolicy.id
    }
    enableHttp2: true
    sslCertificates: [
      {
        name: '${appGatewayName}-ssl-certificate'
        properties: {
          keyVaultSecretId: keyVault::kvsGatewayPublicCert.properties.secretUri
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'pool-${appName}'
        properties: {
          backendAddresses: [
            {
              fqdn: webApp.properties.defaultHostName
            }
          ]
        }
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: 'WebAppBackendHttpSettings'
        properties: {
          port: 443
          protocol: 'Https'
          cookieBasedAffinity: 'Disabled'
          pickHostNameFromBackendAddress: true
          requestTimeout: 20
          probe: {
            id: resourceId('Microsoft.Network/applicationGateways/probes', appGatewayName, 'probe-web${baseName}')
          }
        }
      }
    ]
    httpListeners: [
      {
        name: 'WebAppListener'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendIPConfigurations', appGatewayName, 'appGwPublicFrontendIp')
          }
          frontendPort: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', appGatewayName, 'port-443')
          }
          protocol: 'Https'
          sslCertificate: {
            id: resourceId('Microsoft.Network/applicationGateways/sslCertificates', appGatewayName, '${appGatewayName}-ssl-certificate')
          }
          hostName: 'www.${customDomainName}'
          hostNames: []
          requireServerNameIndication: true
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'WebAppRoutingRule'
        properties: {
          ruleType: 'Basic'
          priority: 100
          httpListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', appGatewayName, 'WebAppListener')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', appGatewayName, 'pool-${appName}')
          }
          backendHttpSettings: {
            id: resourceId('Microsoft.Network/applicationGateways/backendHttpSettingsCollection', appGatewayName, 'WebAppBackendHttpSettings')
          }
        }
      }
    ]
    autoscaleConfiguration: {
      minCapacity: 2
      maxCapacity: 5
    }
  }
  dependsOn: [
    grantAppGatewaySecretsUserRoleAssignment
  ]
}

@description('Enable Application Gateway diagnostic settings')
resource azureDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'default'
  scope: appGateway
  properties: {
    workspaceId: logWorkspace.id
    logs: [
      {
        category: 'ApplicationGatewayAccessLog'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
      {
        category: 'ApplicationGatewayPerformanceLog'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
      {
        category: 'ApplicationGatewayFirewallLog'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
    ]
    logAnalyticsDestinationType: null
  }
}

// ---- Outputs ----

@description('The name of the Azure Application Gateway resource.')
output applicationGatewayName string = appGateway.name

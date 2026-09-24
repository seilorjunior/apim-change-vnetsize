@description('Same region as API Management.')
param location string

@description('Lab identification tags.')
param tags object

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-07-01' = {
  name: 'nsg-apim-resize-poc'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowGatewayHttps'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'Internet'
          destinationAddressPrefix: 'VirtualNetwork'
        }
      }
      {
        name: 'AllowApimManagement'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '3443'
          sourceAddressPrefix: 'ApiManagement'
          destinationAddressPrefix: 'VirtualNetwork'
        }
      }
      {
        name: 'AllowLoadBalancerProbe'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '6390'
          sourceAddressPrefix: 'AzureLoadBalancer'
          destinationAddressPrefix: 'VirtualNetwork'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-07-01' = {
  name: 'vnet-apim-resize-poc'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.90.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'snet-apim-original'
        properties: {
          addressPrefix: '10.90.0.0/27'
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

output originalSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, 'snet-apim-original')

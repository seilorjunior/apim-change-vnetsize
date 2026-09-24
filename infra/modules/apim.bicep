@description('Same region as the lab VNet.')
param location string

@description('Lab identification tags.')
param tags object

@description('Globally unique service name.')
param apimName string

@description('Publisher contact email.')
param publisherEmail string

@description('Publisher display name.')
param publisherName string

@description('Initial subnet resource ID.')
param subnetId string

resource apim 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: apimName
  location: location
  tags: tags
  sku: {
    name: 'Developer'
    capacity: 1
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
    virtualNetworkType: 'External'
    virtualNetworkConfiguration: {
      subnetResourceId: subnetId
    }
    publicNetworkAccess: 'Enabled'
  }
}

resource api 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'subnet-poc'
  properties: {
    displayName: 'Subnet resize probe'
    path: 'subnet-poc'
    protocols: [
      'https'
    ]
    subscriptionRequired: false
  }
}

resource health 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'health'
  properties: {
    displayName: 'Health mock'
    method: 'GET'
    urlTemplate: '/health'
    responses: [
      {
        statusCode: 200
        description: 'Gateway mock is responding.'
      }
    ]
  }
}

resource policy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: health
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: '''
      <policies>
        <inbound>
          <base />
          <return-response>
            <set-status code="200" reason="OK" />
            <set-header name="Content-Type" exists-action="override"><value>application/json</value></set-header>
            <set-header name="Cache-Control" exists-action="override"><value>no-store</value></set-header>
            <set-body>{"status":"ok","poc":"apim-subnet-resize"}</set-body>
          </return-response>
        </inbound>
        <backend><base /></backend>
        <outbound><base /></outbound>
        <on-error><base /></on-error>
      </policies>
      '''
  }
}

output apimId string = apim.id
output healthUrl string = '${apim.properties.gatewayUrl}/subnet-poc/health'

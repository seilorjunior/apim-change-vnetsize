targetScope = 'resourceGroup'

@description('Region of the isolated lab. Defaults to the new resource group location.')
param location string = resourceGroup().location

@description('Globally unique APIM name. Keep the lab prefix for the safety checks.')
@minLength(8)
@maxLength(50)
param apimName string = 'apim-resize-poc-${uniqueString(resourceGroup().id)}'

@description('Real contact email required by API Management. Not a secret.')
param publisherEmail string

@description('Publisher displayed by the lab instance.')
param publisherName string = 'Subnet resize lab'

var tags = {
  purpose: 'apim-subnet-resize-poc'
  environment: 'lab'
}

module network './modules/network.bicep' = {
  name: 'network'
  params: {
    location: location
    tags: tags
  }
}

module gateway './modules/apim.bicep' = {
  name: 'gateway'
  params: {
    location: location
    tags: tags
    apimName: apimName
    publisherEmail: publisherEmail
    publisherName: publisherName
    subnetId: network.outputs.originalSubnetId
  }
}

output apimName string = apimName
output apimId string = gateway.outputs.apimId
output originalSubnetId string = network.outputs.originalSubnetId
output healthUrl string = gateway.outputs.healthUrl

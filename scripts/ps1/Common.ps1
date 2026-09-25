#Requires -Version 7.0
Set-StrictMode -Version Latest

function Get-LabEnvironment {
    param([string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env'))
    if (-not (Test-Path -LiteralPath $EnvFile -PathType Leaf)) {
        throw "Local environment file not found: $EnvFile. Copy .env.example to .env and fill in your lab values, or supply all target parameters."
    }
    $allowed = @('AZURE_SUBSCRIPTION_ID', 'AZURE_SUBSCRIPTION_NAME', 'AZURE_TENANT_ID',
        'AZURE_LOCATION', 'AZURE_RESOURCE_GROUP', 'APIM_NAME', 'APIM_PUBLISHER_EMAIL',
        'LAB_DEPLOYMENT_CORRELATION_ID')
    $values = @{}
    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $EnvFile -Encoding utf8 -ErrorAction Stop) {
        $lineNumber++
        $text = $line.Trim()
        if (-not $text -or $text.StartsWith('#')) { continue }
        if ($text -cnotmatch '^([A-Z][A-Z0-9_]*)=(.*)$') {
            throw "Invalid .env syntax at line $lineNumber. Use KEY=value."
        }
        $key = $Matches[1]
        $value = $Matches[2].Trim()
        if ($key -cnotin $allowed -or $values.ContainsKey($key)) {
            throw "Unknown or duplicate .env key at line ${lineNumber}: $key."
        }
        if ($value.StartsWith('"') -or $value.StartsWith("'")) {
            if ($value.Length -lt 2 -or $value[-1] -ne $value[0]) {
                throw "Unclosed .env quote at line $lineNumber."
            }
            $value = $value.Substring(1, $value.Length - 2)
        }
        $values[$key] = $value
    }
    return $values
}

function Resolve-LabTarget {
    param(
        [Parameter(Mandatory)][hashtable]$Overrides,
        [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env')
    )
    $keys = @{
        SubscriptionId = 'AZURE_SUBSCRIPTION_ID'
        ResourceGroup = 'AZURE_RESOURCE_GROUP'
        ApimName = 'APIM_NAME'
    }
    $values = @{}
    if (@($keys.Keys | Where-Object { -not $Overrides.ContainsKey($_) }).Count -gt 0) {
        $values = Get-LabEnvironment -EnvFile $EnvFile
    }
    $target = @{}
    foreach ($parameter in $keys.Keys) {
        $value = if ($Overrides.ContainsKey($parameter)) { [string]$Overrides[$parameter] } else { [string]$values[$keys[$parameter]] }
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "Missing $parameter. Set $($keys[$parameter]) in .env or supply -$parameter."
        }
        $target[$parameter] = $value
    }
    $subscription = [guid]::Empty
    if (-not [guid]::TryParse($target.SubscriptionId, [ref]$subscription) -or $subscription -eq [guid]::Empty) {
        throw 'SubscriptionId must be a non-empty GUID.'
    }
    if ($target.ResourceGroup -notmatch '^rg-apim-resize-poc[-a-zA-Z0-9]*$' -or
        $target.ApimName -notmatch '^apim-resize-poc-[a-zA-Z0-9-]+$') {
        throw 'ResourceGroup and ApimName must use the required lab prefixes.'
    }
    $target.SubscriptionId = $subscription.ToString()
    return $target
}

function Invoke-AzJson {
    param([Parameter(Mandatory)][string[]]$Arguments, [switch]$AllowEmptyResponse, [scriptblock]$Log)
    $command = "az $($Arguments -join ' ') --only-show-errors --output json"
    if ($Log) { & $Log "CLI START: $command" 'INFO' | Out-Null }
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        $output = & az @Arguments --only-show-errors --output json 2>&1
        $exitCode = $LASTEXITCODE
        $text = ($output | ForEach-Object { "$_" }) -join [Environment]::NewLine
        if ($Log) { & $Log ("CLI END: exit={0}; elapsed={1:F1}s" -f $exitCode, $timer.Elapsed.TotalSeconds) 'INFO' | Out-Null }
        if ($exitCode -ne 0) {
            throw "Azure CLI exit code $exitCode. Command: az $($Arguments -join ' ')`n$text"
        }
        if ([string]::IsNullOrWhiteSpace($text)) {
            if ($AllowEmptyResponse) {
                if ($Log) { & $Log 'No response body; submission is not completion.' 'INFO' | Out-Null }
                return $null
            }
            throw "Azure CLI returned no JSON: az $($Arguments -join ' ')"
        }
        return ConvertFrom-Json -InputObject $text -AsHashtable -ErrorAction Stop
    } catch {
        if ($Log) { & $Log "CLI ERROR: $($_.Exception.Message)" 'ERROR' | Out-Null }
        throw
    }
}

function Get-LabSnapshot {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$ApimName,
        [switch]$IncludeTemporarySubnet,
        [scriptblock]$Log
    )
    $scope = @('--subscription', $SubscriptionId, '--resource-group', $ResourceGroup)
    $state = @{
        capturedAtUtc = [DateTime]::UtcNow.ToString('o')
        group = Invoke-AzJson -Log $Log -Arguments @('group', 'show', '--name', $ResourceGroup, '--subscription', $SubscriptionId)
        apim = Invoke-AzJson -Log $Log -Arguments (@('apim', 'show', '--name', $ApimName) + $scope)
        vnet = Invoke-AzJson -Log $Log -Arguments (@('network', 'vnet', 'show', '--name', 'vnet-apim-resize-poc') + $scope)
        original = Invoke-AzJson -Log $Log -Arguments (@('network', 'vnet', 'subnet', 'show', '--vnet-name', 'vnet-apim-resize-poc', '--name', 'snet-apim-original') + $scope)
    }
    if ($IncludeTemporarySubnet) {
        $state.temporary = $null
        if (@($state.vnet.subnets | Where-Object { $_.id -eq "$($state.vnet.id)/subnets/snet-apim-temporary" }).Count -gt 0) {
            $state.temporary = Invoke-AzJson -Log $Log -Arguments (@('network', 'vnet', 'subnet', 'show', '--vnet-name', 'vnet-apim-resize-poc', '--name', 'snet-apim-temporary') + $scope)
        }
    }
    return $state
}

function Assert-LabState {
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$ApimName,
        [switch]$AllowTemporarySubnet
    )
    $root = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup"
    $vnetId = "$root/providers/Microsoft.Network/virtualNetworks/vnet-apim-resize-poc"
    $originalId = "$vnetId/subnets/snet-apim-original"
    $temporaryId = "$vnetId/subnets/snet-apim-temporary"
    foreach ($item in @($State.group, $State.apim, $State.vnet)) {
        if ($item.tags.purpose -ne 'apim-subnet-resize-poc') {
            throw 'Resource without the required lab tag. Refusing operation.'
        }
    }
    if ($State.group.id -ne $root -or $State.vnet.id -ne $vnetId -or
        $State.apim.id -ne "$root/providers/Microsoft.ApiManagement/service/$ApimName" -or
        $State.original.id -ne $originalId) {
        throw 'Resource IDs do not match the specified lab.'
    }
    if ($ApimName -notlike 'apim-resize-poc-*' -or $State.apim.sku.name -ne 'Developer' -or
        $State.apim.virtualNetworkType -ne 'External' -or (Test-HasItems $State.apim['additionalLocations'])) {
        throw 'Only this single-region Developer External lab is allowed.'
    }
    if ($State.apim.provisioningState -ne 'Succeeded' -or $State.vnet.provisioningState -ne 'Succeeded' -or
        $State.original.provisioningState -ne 'Succeeded') {
        throw 'An infrastructure operation is pending or failed. Inspect state before continuing.'
    }
    # APIM can return a display name ("East US 2") while Network returns "eastus2".
    $apimLocation = ([string]$State.apim['location']).Replace(' ', '')
    $vnetLocation = ([string]$State.vnet['location']).Replace(' ', '')
    $expectedSubnetIds = @($originalId)
    if ($AllowTemporarySubnet -and $State['temporary']) {
        $expectedSubnetIds += $temporaryId
    }
    $actualSubnetIds = @($State.vnet.subnets | ForEach-Object { $_.id })
    if ([string]::IsNullOrWhiteSpace($apimLocation) -or [string]::IsNullOrWhiteSpace($vnetLocation) -or
        $apimLocation -ine $vnetLocation -or
        @($State.vnet.addressSpace.addressPrefixes).Count -ne 1 -or
        $State.vnet.addressSpace.addressPrefixes[0] -ne '10.90.0.0/16' -or
        $actualSubnetIds.Count -ne $expectedSubnetIds.Count -or
        @(Compare-Object $expectedSubnetIds $actualSubnetIds).Count -ne 0 -or
        (Test-HasItems $State.vnet['virtualNetworkPeerings'])) {
        throw 'VNet topology differs from the isolated lab.'
    }
    if ($State.original.addressPrefix -notin @('10.90.0.0/27', '10.90.0.0/26')) {
        throw 'Unexpected subnet prefixes. No arbitrary CIDR changes are allowed.'
    }
    $nsgId = "$root/providers/Microsoft.Network/networkSecurityGroups/nsg-apim-resize-poc"
    Assert-LabSubnet -Subnet $State.original -NsgId $nsgId
    if ($AllowTemporarySubnet -and $State['temporary']) {
        if ($State.temporary.id -ne $temporaryId -or $State.temporary.addressPrefix -ne '10.90.1.0/27' -or
            $State.temporary.provisioningState -ne 'Succeeded') {
            throw 'Temporary subnet must be the expected healthy lab /27.'
        }
        Assert-LabSubnet -Subnet $State.temporary -NsgId $nsgId
    }
    if ($State.apim.virtualNetworkConfiguration.subnetResourceId -notin $expectedSubnetIds) {
        throw 'APIM must remain connected to an allowed lab subnet.'
    }
}

function Assert-LabSubnet {
    param([Parameter(Mandatory)][hashtable]$Subnet, [Parameter(Mandatory)][string]$NsgId)
    if ($subnet.networkSecurityGroup.id -ne $nsgId -or (Test-HasItems $subnet['delegations']) -or
        $subnet['routeTable'] -or $subnet['natGateway'] -or (Test-HasItems $subnet['addressPrefixes'])) {
        throw 'Unexpected subnet NSG, delegation, route table, NAT gateway or multiple prefixes.'
    }
}

function Test-SubnetHasAllocations {
    param([Parameter(Mandatory)][hashtable]$Subnet)
    foreach ($field in @('ipConfigurations', 'privateEndpoints', 'ipConfigurationProfiles',
        'serviceAssociationLinks', 'resourceNavigationLinks', 'applicationGatewayIPConfigurations')) {
        if (Test-HasItems $Subnet[$field]) { return $true }
    }
    return $false
}

function Test-LabMockPayload {
    param([Parameter(Mandatory)][string]$Content)
    $body = ConvertFrom-Json -InputObject $Content -AsHashtable -ErrorAction Stop
    return $body -is [hashtable] -and $body.Count -eq 2 -and $body['status'] -ceq 'ok' -and $body['poc'] -ceq 'apim-subnet-resize'
}

function Test-HasItems {
    param([AllowNull()][object]$Value)
    return @($Value | Where-Object { $null -ne $_ }).Count -gt 0
}

function Assert-ExperimentAction {
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][hashtable]$State
    )
    if ($Action -ne 'TryResizeOccupied') { throw "Unknown action: $Action" }
    if ($State.apim.virtualNetworkConfiguration.subnetResourceId -ne $State.original.id -or
        $State.original.addressPrefix -ne '10.90.0.0/27') {
        throw 'Occupied resize requires APIM on the original /27 subnet.'
    }
}

function Get-ProbeSummary {
    param([Parameter(Mandatory)][object[]]$Samples)
    $successes = @($Samples | Where-Object { $_.success -eq $true -or $_.success -eq 'True' })
    $latencies = @($successes | ForEach-Object { [double]$_.latencyMs } | Sort-Object)
    $p95 = if ($latencies.Count) { $latencies[[int][Math]::Ceiling($latencies.Count * 0.95) - 1] } else { $null }
    $percentage = if ($Samples.Count) { [Math]::Round(100 * $successes.Count / $Samples.Count, 3) } else { $null }
    return [ordered]@{
        samples = $Samples.Count
        successfulSamples = $successes.Count
        failedSamples = $Samples.Count - $successes.Count
        successPercent = $percentage
        successfulLatencyP95Ms = $p95
        limitation = 'Sampled gateway mock only; not an SLA, exact downtime, private-backend test or Premium availability result.'
    }
}

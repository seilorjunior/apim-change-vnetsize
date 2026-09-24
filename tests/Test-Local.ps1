#Requires -Version 7.0
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\Common.ps1')
$script:passed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:passed++
}

function Assert-Throws {
    param([scriptblock]$Code, [string]$Message)
    $threw = $false
    try { & $Code | Out-Null } catch { $threw = $true }
    Assert-True $threw $Message
}

$subscription = '00000000-0000-0000-0000-000000000001'
$group = 'rg-apim-resize-poc-test'
$apimName = 'apim-resize-poc-test'
$root = "/subscriptions/$subscription/resourceGroups/$group"
$vnetId = "$root/providers/Microsoft.Network/virtualNetworks/vnet-apim-resize-poc"
$originalId = "$vnetId/subnets/snet-apim-original"
$nsgId = "$root/providers/Microsoft.Network/networkSecurityGroups/nsg-apim-resize-poc"
$script:state = @{
    group = @{ id = $root; tags = @{ purpose = 'apim-subnet-resize-poc' } }
    apim = @{
        id = "$root/providers/Microsoft.ApiManagement/service/$apimName"
        tags = @{ purpose = 'apim-subnet-resize-poc' }
        sku = @{ name = 'Developer' }
        virtualNetworkType = 'External'
        additionalLocations = $null
        provisioningState = 'Succeeded'
        location = 'East US 2'
        virtualNetworkConfiguration = @{ subnetResourceId = $originalId }
    }
    vnet = @{
        id = $vnetId
        tags = @{ purpose = 'apim-subnet-resize-poc' }
        location = 'eastus2'
        provisioningState = 'Succeeded'
        addressSpace = @{ addressPrefixes = @('10.90.0.0/16') }
        subnets = @(@{ id = $originalId })
        virtualNetworkPeerings = @()
    }
    original = @{
        id = $originalId
        addressPrefix = '10.90.0.0/27'
        provisioningState = 'Succeeded'
        networkSecurityGroup = @{ id = $nsgId }
    }
}
$pristine = $script:state | ConvertTo-Json -Depth 20
$labArgs = @{ SubscriptionId = $subscription; ResourceGroup = $group; ApimName = $apimName }
Assert-LabState -State $script:state @labArgs
Assert-True $true 'APIM display region and Network canonical region must match.'
$script:state.apim.location = 'eastus2'
Assert-LabState -State $script:state @labArgs
Assert-True $true 'Matching canonical regions must remain accepted.'
$script:state = ConvertFrom-Json $pristine -AsHashtable
Assert-True (-not (Test-HasItems $null)) 'Null arrays must count as empty.'
Assert-True (-not (Test-HasItems @())) 'Empty arrays must count as empty.'
Assert-True (Test-HasItems @('x')) 'Populated arrays must not count as empty.'

foreach ($case in @(
    @{ Name = 'Premium must be rejected'; Edit = { $script:state.apim.sku.name = 'Premium' } },
    @{ Name = 'Internal must be rejected'; Edit = { $script:state.apim.virtualNetworkType = 'Internal' } },
    @{ Name = 'Untagged resources must be rejected'; Edit = { $script:state.group.tags.purpose = 'production' } },
    @{ Name = 'Cross-group resources must be rejected'; Edit = { $script:state.original.id = '/another/subnet' } },
    @{ Name = 'In-progress update must be rejected'; Edit = { $script:state.apim.provisioningState = 'Updating' } },
    @{ Name = 'Different regions must be rejected'; Edit = { $script:state.apim.location = 'East US' } },
    @{ Name = 'Missing APIM region must be rejected'; Edit = { $script:state.apim.Remove('location') } },
    @{ Name = 'Null Network region must be rejected'; Edit = { $script:state.vnet.location = $null } },
    @{ Name = 'Blank regions must be rejected'; Edit = { $script:state.apim.location = ' '; $script:state.vnet.location = ' ' } },
    @{ Name = 'Peering must be rejected'; Edit = { $script:state.vnet.virtualNetworkPeerings = @(@{ id = 'peer' }) } },
    @{ Name = 'Delegation must be rejected'; Edit = { $script:state.original.delegations = @(@{ name = 'delegated' }) } },
    @{ Name = 'UDR must be rejected'; Edit = { $script:state.original.routeTable = @{ id = 'route' } } },
    @{ Name = 'Unexpected prefix must be rejected'; Edit = { $script:state.original.addressPrefix = '10.90.0.0/25' } },
    @{ Name = 'Additional subnet must be rejected'; Edit = { $script:state.vnet.subnets += @{ id = "$vnetId/subnets/extra" } } },
    @{ Name = 'Unexpected VNet subnet ID must be rejected'; Edit = { $script:state.vnet.subnets[0].id = "$vnetId/subnets/other" } },
    @{ Name = 'Disconnected APIM must be rejected'; Edit = { $script:state.apim.virtualNetworkConfiguration.subnetResourceId = $null } },
    @{ Name = 'Unexpected NSG must be rejected'; Edit = { $script:state.original.networkSecurityGroup.id = 'other' } }
)) {
    $script:state = ConvertFrom-Json $pristine -AsHashtable
    & $case.Edit
    Assert-Throws { Assert-LabState -State $script:state @labArgs } $case.Name
}
$script:state = ConvertFrom-Json $pristine -AsHashtable
Assert-ExperimentAction -Action TryResizeOccupied -State $script:state
foreach ($removedAction in @('MoveTemporary', 'ResizeEmpty', 'MoveBack')) {
    Assert-Throws { Assert-ExperimentAction -Action $removedAction -State $script:state } "Removed action must be rejected: $removedAction"
}
$script:state.apim.virtualNetworkConfiguration.subnetResourceId = "$vnetId/subnets/other"
Assert-Throws { Assert-ExperimentAction -Action TryResizeOccupied -State $script:state } 'Occupied resize requires APIM on the original subnet.'
$script:state = ConvertFrom-Json $pristine -AsHashtable
$script:state.original.addressPrefix = '10.90.0.0/26'
Assert-Throws { Assert-ExperimentAction -Action TryResizeOccupied -State $script:state } 'Repeated expansion must be rejected.'
$summary = Get-ProbeSummary -Samples @(
    [pscustomobject]@{ success = $true; latencyMs = 10 },
    [pscustomobject]@{ success = $true; latencyMs = 20 },
    [pscustomobject]@{ success = $false; latencyMs = 999 }
)
Assert-True ($summary.failedSamples -eq 1 -and $summary.successfulLatencyP95Ms -eq 20 -and $summary.successPercent -eq 66.667) 'Probe summary uses only successful latencies.'
$summary = Get-ProbeSummary -Samples @([pscustomobject]@{ success = $false; latencyMs = 99 })
Assert-True ($null -eq $summary.successfulLatencyP95Ms -and $summary.successPercent -eq 0) 'All failures must not produce a successful latency.'

# Mock the CLI so the workflow test cannot access Azure.
if (Get-Variable -Name ApimResizeTestContext -Scope Global -ErrorAction SilentlyContinue) {
    throw 'A test context already exists; use a fresh PowerShell process.'
}
$global:ApimResizeTestContext = @{
    State = ConvertFrom-Json $pristine -AsHashtable
    Subscription = $subscription
    Mutations = 0
    RejectResize = $true
    PreservePrefix = $false
}
function az {
    $arguments = @($args)
    $global:LASTEXITCODE = 0
    $command = $arguments -join ' '
    $context = $global:ApimResizeTestContext
    if ($command -notmatch "--subscription $($context.Subscription)") { throw 'Missing explicit subscription.' }
    if ($command -match '^group show ') { return ($context.State.group | ConvertTo-Json -Depth 30) }
    if ($command -match '^apim show ') { return ($context.State.apim | ConvertTo-Json -Depth 30) }
    if ($command -match '^network vnet show ') { return ($context.State.vnet | ConvertTo-Json -Depth 30) }
    if ($command -match '^network vnet subnet show ') {
        if ($command -notmatch '--name snet-apim-original ') { throw 'Unexpected subnet read.' }
        return ($context.State.original | ConvertTo-Json -Depth 30)
    }
    if ($command -match '^network vnet subnet update ') {
        if ($command -notmatch '--vnet-name vnet-apim-resize-poc --name snet-apim-original --address-prefixes 10\.90\.0\.0/26 ') {
            throw 'Only the original subnet /26 expansion is allowed.'
        }
        $context.Mutations++
        if ($context.RejectResize) {
            $global:LASTEXITCODE = 1
            return 'SubnetInUse: simulated occupied subnet rejection'
        }
        if (-not $context.PreservePrefix) { $context.State.original.addressPrefix = '10.90.0.0/26' }
        return ($context.State.original | ConvertTo-Json -Depth 30)
    }
    throw "Unexpected mock CLI invocation: $command"
}
function Invoke-WebRequest {
    if ($global:ApimResizeTestContext.Probe.Throw) { throw 'Simulated network timeout' }
    return $global:ApimResizeTestContext.Probe.Response
}
function Start-Sleep {
    throw 'TestStopAfterOneSample'
}
$experiment = Join-Path $PSScriptRoot '..\scripts\Invoke-SubnetExperiment.ps1'
$evidence = Join-Path ([IO.Path]::GetTempPath()) "apim-resize-tests-$([guid]::NewGuid().ToString('N'))"
try {
    foreach ($removedAction in @('MoveTemporary', 'ResizeEmpty', 'MoveBack')) {
        Assert-Throws { & $experiment -Action $removedAction @labArgs -EvidenceRoot $evidence -Confirm:$false } "Script must reject removed action: $removedAction"
    }
    & $experiment -Action TryResizeOccupied @labArgs -EvidenceRoot $evidence -WhatIf
    Assert-True ($global:ApimResizeTestContext.Mutations -eq 0) 'WhatIf must not mutate Azure.'
    $skipped = @(Get-ChildItem $evidence -Filter result.json -Recurse | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json })
    Assert-True ($skipped.Count -eq 1 -and $skipped[0].outcome -eq 'Skipped') 'WhatIf must persist a skipped result.'
    Assert-Throws { & $experiment -Action TryResizeOccupied @labArgs -EvidenceRoot $evidence -Confirm:$false } 'Rejected resize must throw.'
    $failed = @(Get-ChildItem $evidence -Filter result.json -Recurse | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } | Where-Object outcome -eq 'FailedOrRejected')
    Assert-True ($failed.Count -eq 1 -and $failed[0].error -match 'SubnetInUse') 'Persist actual error without declaring a successful test.'
    Assert-True ($global:ApimResizeTestContext.Mutations -eq 1) 'Rejection must not trigger retries or fallback mutations.'
    $errorSnapshots = @(Get-ChildItem $evidence -Filter after-error.json -Recurse | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json })
    Assert-True ($errorSnapshots.Count -eq 1 -and $errorSnapshots[0].original.addressPrefix -eq '10.90.0.0/27' -and
        $errorSnapshots[0].apim.virtualNetworkConfiguration.subnetResourceId -eq $originalId) 'Rejection must capture the unchanged occupied subnet.'
    $global:ApimResizeTestContext.RejectResize = $false
    & $experiment -Action TryResizeOccupied @labArgs -EvidenceRoot $evidence -Confirm:$false
    Assert-True ($global:ApimResizeTestContext.State.original.addressPrefix -eq '10.90.0.0/26' -and
        $global:ApimResizeTestContext.State.apim.virtualNetworkConfiguration.subnetResourceId -eq $originalId) 'Direct resize must keep APIM on the expanded original subnet.'
    Assert-True ($global:ApimResizeTestContext.Mutations -eq 2) 'Each attempt must issue exactly one subnet update.'
    $success = @(Get-ChildItem $evidence -Filter result.json -Recurse | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } | Where-Object outcome -eq 'ControlPlaneSucceeded')
    Assert-True ($success.Count -eq 1) 'Only the successful direct resize must persist a verified control-plane outcome.'
    $responses = @(Get-ChildItem $evidence -Filter operation-response.json -Recurse | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json })
    Assert-True ($responses.Count -eq 1 -and $responses[0].id -eq $originalId -and
        $responses[0].addressPrefix -eq '10.90.0.0/26') 'Persist the actual accepted subnet response.'
    $after = @(Get-ChildItem $evidence -Filter after.json -Recurse | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json })
    Assert-True ($after.Count -eq 1 -and $after[0].original.addressPrefix -eq '10.90.0.0/26' -and
        $after[0].apim.virtualNetworkConfiguration.subnetResourceId -eq $originalId) 'Persist the verified state after expansion.'
    Assert-Throws { & $experiment -Action TryResizeOccupied @labArgs -EvidenceRoot $evidence -Confirm:$false } 'Second expansion must fail before a mutation.'
    $snapshot = & $experiment -Action Snapshot @labArgs -EvidenceRoot $evidence
    Assert-True ($snapshot.original.addressPrefix -eq '10.90.0.0/26' -and $global:ApimResizeTestContext.Mutations -eq 2) 'Snapshot must remain read-only after expansion.'
    $global:ApimResizeTestContext.State = ConvertFrom-Json $pristine -AsHashtable
    $global:ApimResizeTestContext.PreservePrefix = $true
    Assert-Throws { & $experiment -Action TryResizeOccupied @labArgs -EvidenceRoot $evidence -Confirm:$false } 'CLI success without /26 must fail postcondition validation.'
    $success = @(Get-ChildItem $evidence -Filter result.json -Recurse | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } | Where-Object outcome -eq 'ControlPlaneSucceeded')
    Assert-True ($success.Count -eq 1 -and $global:ApimResizeTestContext.Mutations -eq 3) 'Failed postconditions must not create a success result or retry.'
    $monitor = Join-Path $PSScriptRoot '..\scripts\Watch-Gateway.ps1'
    Assert-Throws {
        & $monitor -Url 'https://example.com/subnet-poc/health' -EvidenceRoot $evidence
    } 'Monitor must reject non-lab endpoints.'
    foreach ($probeCase in @(
        @{ Name = 'Exact mock'; Code = 200; Body = '{"status":"ok","poc":"apim-subnet-resize"}'; Throw = $false; Expected = $true },
        @{ Name = 'Extra field'; Code = 200; Body = '{"status":"ok","poc":"apim-subnet-resize","extra":true}'; Throw = $false; Expected = $false },
        @{ Name = 'Wrong payload'; Code = 200; Body = '{"status":"bad","poc":"apim-subnet-resize"}'; Throw = $false; Expected = $false },
        @{ Name = 'Malformed JSON'; Code = 200; Body = 'not json'; Throw = $false; Expected = $false },
        @{ Name = 'HTTP 503'; Code = 503; Body = '{}'; Throw = $false; Expected = $false },
        @{ Name = 'Network timeout'; Code = 0; Body = ''; Throw = $true; Expected = $false }
    )) {
        $global:ApimResizeTestContext.Probe = @{
            Throw = $probeCase.Throw
            Response = @{ StatusCode = $probeCase.Code; Content = $probeCase.Body }
        }
        $existing = @(Get-ChildItem -LiteralPath $evidence -Directory).FullName
        try {
            & $monitor -Url 'https://apim-resize-poc-test.azure-api.net/subnet-poc/health' -EvidenceRoot $evidence | Out-Null
            throw 'Monitor should have reached the test stop.'
        } catch {
            if ($_.Exception.Message -ne 'TestStopAfterOneSample') { throw }
        }
        $newDirectory = @(Get-ChildItem -LiteralPath $evidence -Directory | Where-Object { $_.FullName -notin $existing })
        Assert-True ($newDirectory.Count -eq 1) "One evidence directory: $($probeCase.Name)"
        $rows = @(Import-Csv -LiteralPath (Join-Path $newDirectory[0].FullName 'samples.csv'))
        $report = Get-Content -LiteralPath (Join-Path $newDirectory[0].FullName 'summary.json') -Raw | ConvertFrom-Json
        Assert-True ($rows.Count -eq 1 -and $rows[0].success -eq [string]$probeCase.Expected) "Recorded probe result: $($probeCase.Name)"
        Assert-True ($report.successfulSamples -eq [int]$probeCase.Expected) "Persisted probe summary: $($probeCase.Name)"
        if (-not $probeCase.Expected) {
            Assert-True (-not [string]::IsNullOrWhiteSpace($rows[0].error)) "Failures expose errors: $($probeCase.Name)"
        }
    }
} finally {
    Remove-Item Function:\az
    Remove-Item Function:\Invoke-WebRequest
    Remove-Item Function:\Start-Sleep
    Remove-Variable -Name ApimResizeTestContext -Scope Global
    if (Test-Path -LiteralPath $evidence) {
        Get-ChildItem -LiteralPath $evidence -File -Recurse | Remove-Item
        Get-ChildItem -LiteralPath $evidence -Directory | Remove-Item
        Remove-Item -LiteralPath $evidence
    }
}
Write-Host "PASS: $script:passed assertions. Azure was mocked; no cloud resources were accessed."

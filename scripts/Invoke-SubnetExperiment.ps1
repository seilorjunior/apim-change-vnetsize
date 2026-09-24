#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][ValidateSet('Snapshot', 'TryResizeOccupied')]
    [string]$Action,
    [guid]$SubscriptionId,
    [ValidatePattern('^rg-apim-resize-poc[-a-zA-Z0-9]*$')][string]$ResourceGroup,
    [ValidatePattern('^apim-resize-poc-[a-zA-Z0-9-]+$')][string]$ApimName,
    [string]$EvidenceRoot = (Join-Path $PSScriptRoot '..\artifacts'),
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\.env')
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$snapshotArgs = Resolve-LabTarget -Overrides $PSBoundParameters -EnvFile $EnvFile
$subscription = $snapshotArgs.SubscriptionId
$ResourceGroup = $snapshotArgs.ResourceGroup
$ApimName = $snapshotArgs.ApimName
$scope = @('--subscription', $subscription, '--resource-group', $ResourceGroup)
$vnetName = 'vnet-apim-resize-poc'

function Save-Evidence {
    param([string]$Name, [object]$Value)
    $Value | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath (Join-Path $runDirectory $Name) -Encoding utf8 -WhatIf:$false
}

$before = Get-LabSnapshot @snapshotArgs
$runDirectory = Join-Path $EvidenceRoot ("{0}-{1}-{2}" -f [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'), $Action, [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $runDirectory -Force -WhatIf:$false | Out-Null
Save-Evidence 'before.json' $before
Write-Host "Evidence: $runDirectory"
if ($Action -eq 'Snapshot') { return $before }

$result = [ordered]@{
    action = $Action
    startedAtUtc = [DateTime]::UtcNow.ToString('o')
    finishedAtUtc = $null
    outcome = 'NotStarted'
    error = $null
}
try {
    Assert-LabState -State $before -SubscriptionId $subscription -ResourceGroup $ResourceGroup -ApimName $ApimName
    Assert-ExperimentAction -Action $Action -State $before
    if (-not $PSCmdlet.ShouldProcess("$ResourceGroup / $ApimName", "$Action (lab network mutation; downtime and IP changes possible)")) {
        $result.outcome = 'Skipped'
        return
    }
    $result.outcome = 'InProgress'
    Save-Evidence 'result.json' $result
    $response = Invoke-AzJson -Arguments (@(
        'network', 'vnet', 'subnet', 'update', '--vnet-name', $vnetName,
        '--name', 'snet-apim-original', '--address-prefixes', '10.90.0.0/26'
    ) + $scope)
    Save-Evidence 'operation-response.json' $response
    $after = Get-LabSnapshot @snapshotArgs
    Save-Evidence 'after.json' $after
    Assert-LabState -State $after -SubscriptionId $subscription -ResourceGroup $ResourceGroup -ApimName $ApimName
    if ($after.original.addressPrefix -ne '10.90.0.0/26' -or
        $after.apim.virtualNetworkConfiguration.subnetResourceId -ne $before.apim.virtualNetworkConfiguration.subnetResourceId) {
        throw 'Postcondition failed: prefix or APIM subnet differs from the expected result.'
    }
    $result.outcome = 'ControlPlaneSucceeded'
    Write-Host 'Control-plane postconditions verified. Gateway availability must be checked separately.'
} catch {
    $result.outcome = 'FailedOrRejected'
    $result.error = $_.Exception.Message
    Write-Warning 'Failure is not automatically proof of a subnet restriction. Inspect the Azure error code, permissions, policy and Activity Log.'
    try { Save-Evidence 'after-error.json' (Get-LabSnapshot @snapshotArgs) }
    catch { Write-Warning "Could not capture state after failure: $($_.Exception.Message)" }
    throw
} finally {
    $result.finishedAtUtc = [DateTime]::UtcNow.ToString('o')
    Save-Evidence 'result.json' $result
}

#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Snapshot', 'Run', 'PrepareTemporary', 'MoveTemporary', 'ResizeEmpty', 'MoveBack')]
    [string]$Action,
    [guid]$SubscriptionId,
    [ValidatePattern('^rg-apim-resize-poc[-a-zA-Z0-9]*$')][string]$ResourceGroup,
    [ValidatePattern('^apim-resize-poc-[a-zA-Z0-9-]+$')][string]$ApimName,
    [ValidateRange(1, 14400)][int]$TimeoutSeconds = 7200,
    [ValidateRange(1, 120)][int]$PollSeconds = 30,
    [string]$EvidenceRoot = (Join-Path $PSScriptRoot '..\artifacts'),
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\.env')
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$lab = Resolve-LabTarget -Overrides $PSBoundParameters -EnvFile $EnvFile
$SubscriptionId = [guid]$lab.SubscriptionId
$ResourceGroup = $lab.ResourceGroup
$ApimName = $lab.ApimName
$scope = @('--subscription', $lab.SubscriptionId, '--resource-group', $ResourceGroup)
$vnetId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Network/virtualNetworks/vnet-apim-resize-poc"
$originalId = "$vnetId/subnets/snet-apim-original"
$temporaryId = "$vnetId/subnets/snet-apim-temporary"
$runDirectory = Join-Path $EvidenceRoot ("{0}-Migration-{1}-{2}" -f [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'), $Action, [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $runDirectory -Force -WhatIf:$false | Out-Null
$runDirectory = (Resolve-Path -LiteralPath $runDirectory).ProviderPath
$logPath = Join-Path $runDirectory 'migration.log'
$runTimer = [System.Diagnostics.Stopwatch]::StartNew()
$result = [ordered]@{
    action = $Action
    startedAtUtc = [DateTime]::UtcNow.ToString('o')
    finishedAtUtc = $null
    outcome = 'NotStarted'
    stage = 'Preflight'
    completedStages = @()
    controlPlaneVerifiedStages = @()
    error = $null
    logPath = $logPath
    recovery = 'Inspect live Snapshot and evidence. No automatic retry, rollback, shrinking or deletion. A timed-out operation may still be running.'
}

function Write-MigrationLog {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO')
    foreach ($line in ($Message -split '\r?\n')) {
        $entry = "[{0}] [{1}] [{2}] {3}" -f [DateTime]::UtcNow.ToString('o'), $Level, $result.stage, $line
        Add-Content -LiteralPath $logPath -Value $entry -Encoding utf8 -WhatIf:$false
        Write-Host $entry
    }
}
$log = { param($Message, $Level) Write-MigrationLog -Message $Message -Level $Level }

function Save-MigrationEvidence {
    param([string]$Name, [AllowNull()][object]$Value)
    ConvertTo-Json -InputObject $Value -Depth 100 |
        Set-Content -LiteralPath (Join-Path $runDirectory $Name) -Encoding utf8 -WhatIf:$false
    Write-MigrationLog "Evidence saved: $Name"
}

function Write-MigrationState {
    param([hashtable]$State)
    Write-MigrationLog ("State: APIM={0}; subnet={1}; originalPrefix={2}; originalAllocated={3}; temporaryExists={4}" -f
        $State.apim.provisioningState, $State.apim.virtualNetworkConfiguration.subnetResourceId,
        $State.original.addressPrefix, (Test-SubnetHasAllocations $State.original), [bool]$State.temporary)
}

function Assert-MigrationState {
    param([hashtable]$State)
    Assert-LabState -State $State @lab -AllowTemporarySubnet
    $dns = $State.vnet['dhcpOptions']
    if ($State.apim.sku.capacity -ne 1 -or $State.apim.platformVersion -ne 'stv2' -or
        $State.apim['publicIpAddressId'] -or (Test-HasItems $State.apim['privateEndpointConnections']) -or
        ($dns -and (Test-HasItems $dns['dnsServers']))) {
        throw 'Only the single-unit stv2 lab with managed public IP and default DNS is supported.'
    }
    foreach ($resource in @($State.group, $State.apim, $State.vnet)) {
        if ($resource.tags['environment'] -ne 'lab') { throw 'Migration requires environment=lab tags.' }
    }
}

function Assert-MigrationStage {
    param([string]$Stage, [hashtable]$State)
    Assert-MigrationState $State
    $onOriginal = $State.apim.virtualNetworkConfiguration.subnetResourceId -eq $originalId
    switch ($Stage) {
        { $_ -in 'Run', 'PrepareTemporary' } {
            if (-not $onOriginal -or $State.original.addressPrefix -ne '10.90.0.0/27' -or $State.temporary) {
                throw 'Start requires APIM on original /27 and no temporary subnet. Use explicit stages to resume.'
            }
        }
        'MoveTemporary' {
            if (-not $onOriginal -or $State.original.addressPrefix -ne '10.90.0.0/27' -or
                -not $State.temporary -or (Test-SubnetHasAllocations $State.temporary)) {
                throw 'MoveTemporary requires APIM on original /27 and an empty temporary subnet.'
            }
        }
        'ResizeEmpty' {
            if ($onOriginal -or -not $State.temporary -or $State.original.addressPrefix -ne '10.90.0.0/27') {
                throw 'ResizeEmpty requires APIM on temporary and original /27.'
            }
        }
        'MoveBack' {
            if ($onOriginal -or -not $State.temporary -or $State.original.addressPrefix -ne '10.90.0.0/26' -or
                (Test-SubnetHasAllocations $State.original)) {
                throw 'MoveBack requires APIM on temporary and empty original /26.'
            }
        }
    }
}

function Assert-MockHealth {
    param([string]$Name)
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $sample = [ordered]@{ timestampUtc = [DateTime]::UtcNow.ToString('o'); statusCode = $null; success = $false; error = $null }
    try {
        Write-MigrationLog "HTTP START: $Name GET https://$ApimName.azure-api.net/subnet-poc/health; timeout=30s"
        $response = Invoke-WebRequest -Uri "https://$ApimName.azure-api.net/subnet-poc/health" `
            -TimeoutSec 30 -SkipHttpErrorCheck -MaximumRedirection 0
        $sample.statusCode = [int]$response.StatusCode
        Write-MigrationLog ("HTTP status={0}; elapsed={1:F1}s" -f $sample.statusCode, $timer.Elapsed.TotalSeconds)
        if ($sample.statusCode -ne 200) { throw "Unexpected HTTP status $($sample.statusCode)." }
        if (-not (Test-LabMockPayload -Content ([string]$response.Content))) {
            throw 'Unexpected mock payload.'
        }
        $sample.success = $true
        Write-MigrationLog 'HTTP health verified: status=200 and exact mock payload.'
    } catch {
        $sample.error = $_.Exception.Message
        Write-MigrationLog "HTTP ERROR: $($sample.error)" -Level ERROR
        throw
    } finally {
        Save-MigrationEvidence "$Name.json" $sample
    }
}

function Wait-ApimSubnet {
    param([string]$SubnetId)
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $poll = 0
    Write-MigrationLog "Waiting for APIM Succeeded; target=$SubnetId; timeout=${TimeoutSeconds}s"
    do {
        $poll++
        $apim = Invoke-AzJson -Log $log -Arguments (@('apim', 'show', '--name', $ApimName) + $scope)
        Save-MigrationEvidence "$($result.stage)-poll.json" $apim
        Write-MigrationLog ("Poll #{0}: state={1}; subnet={2}; target={3}; elapsed={4:F1}s/{5}s" -f
            $poll, $apim.provisioningState, $apim.virtualNetworkConfiguration.subnetResourceId,
            $SubnetId, $timer.Elapsed.TotalSeconds, $TimeoutSeconds)
        if ($apim.provisioningState -in @('Failed', 'Canceled', 'Deleting', 'Terminating')) {
            throw "APIM entered terminal state $($apim.provisioningState)."
        }
        if ($apim.provisioningState -eq 'Succeeded' -and $apim.virtualNetworkConfiguration.subnetResourceId -eq $SubnetId) {
            Write-MigrationLog 'APIM target subnet and Succeeded state verified.'
            return
        }
        Write-MigrationLog ("Next poll in {0}s; do not resubmit the update." -f [Math]::Min($PollSeconds, $TimeoutSeconds))
        Start-Sleep -Seconds ([Math]::Min($PollSeconds, $TimeoutSeconds))
    } while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    throw "Timeout waiting for APIM on $SubnetId. Operation may still be running; do not repeat the update."
}

function Wait-OriginalEmpty {
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $poll = 0
    Write-MigrationLog "Waiting for original subnet allocations to be released; timeout=${TimeoutSeconds}s"
    do {
        $poll++
        $state = Get-LabSnapshot @lab -IncludeTemporarySubnet -Log $log
        Save-MigrationEvidence 'ResizeEmpty-release-poll.json' $state
        Assert-MigrationStage -Stage ResizeEmpty -State $state
        $allocated = Test-SubnetHasAllocations $state.original
        Write-MigrationLog ("Release poll #{0}: originalAllocated={1}; elapsed={2:F1}s/{3}s" -f
            $poll, $allocated, $timer.Elapsed.TotalSeconds, $TimeoutSeconds)
        if (-not $allocated) {
            Write-MigrationLog 'Original subnet verified empty; prefix update may proceed.'
            return $state
        }
        Write-MigrationLog ("Next poll in {0}s; original subnet still has allocations." -f [Math]::Min($PollSeconds, $TimeoutSeconds))
        Start-Sleep -Seconds ([Math]::Min($PollSeconds, $TimeoutSeconds))
    } while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    throw 'Timeout waiting for original subnet allocations. No prefix update was issued.'
}

function Invoke-MigrationStage {
    param([string]$Stage)
    $result.stage = $Stage
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    Write-MigrationLog 'Stage started'
    Save-MigrationEvidence 'result.json' $result
    $state = Get-LabSnapshot @lab -IncludeTemporarySubnet -Log $log
    Save-MigrationEvidence "$Stage-before.json" $state
    Write-MigrationState $state
    Assert-MigrationStage -Stage $Stage -State $state
    Write-MigrationLog 'Stage safety checks passed.'
    Assert-MockHealth "$Stage-http-before"
    switch ($Stage) {
        'PrepareTemporary' {
            Write-MigrationLog 'Creating temporary subnet 10.90.1.0/27 with the original NSG.'
            $response = Invoke-AzJson -Log $log -Arguments (@(
                'network', 'vnet', 'subnet', 'create', '--vnet-name', 'vnet-apim-resize-poc',
                '--name', 'snet-apim-temporary', '--address-prefixes', '10.90.1.0/27',
                '--network-security-group', $state.original.networkSecurityGroup.id
            ) + $scope)
        }
        { $_ -in 'MoveTemporary', 'MoveBack' } {
            $targetId = if ($Stage -eq 'MoveTemporary') { $temporaryId } else { $originalId }
            Write-MigrationLog "Submitting APIM move to $targetId; submission is not completion."
            # --no-wait may return no body; submission alone is never considered completion.
            $response = Invoke-AzJson -Log $log -AllowEmptyResponse -Arguments (@(
                'apim', 'update', '--name', $ApimName, '--virtual-network', 'External',
                '--set', "virtualNetworkConfiguration.subnetResourceId=$targetId", '--no-wait'
            ) + $scope)
            Save-MigrationEvidence "$Stage-response.json" $response
            Wait-ApimSubnet -SubnetId $targetId
        }
        'ResizeEmpty' {
            $state = Wait-OriginalEmpty
            Save-MigrationEvidence 'ResizeEmpty-verified-empty.json' $state
            Write-MigrationLog 'Expanding verified-empty original subnet from 10.90.0.0/27 to 10.90.0.0/26.'
            $response = Invoke-AzJson -Log $log -Arguments (@(
                'network', 'vnet', 'subnet', 'update', '--vnet-name', 'vnet-apim-resize-poc',
                '--name', 'snet-apim-original', '--address-prefixes', '10.90.0.0/26'
            ) + $scope)
        }
    }
    Save-MigrationEvidence "$Stage-response.json" $response
    $after = Get-LabSnapshot @lab -IncludeTemporarySubnet -Log $log
    Save-MigrationEvidence "$Stage-after.json" $after
    Write-MigrationState $after
    Assert-MigrationState $after
    $expectedApimSubnet = if ($Stage -in 'MoveTemporary', 'ResizeEmpty') { $temporaryId } else { $originalId }
    $expectedPrefix = if ($Stage -in 'ResizeEmpty', 'MoveBack') { '10.90.0.0/26' } else { '10.90.0.0/27' }
    if (-not $after.temporary -or $after.original.addressPrefix -ne $expectedPrefix -or
        $after.apim.virtualNetworkConfiguration.subnetResourceId -ne $expectedApimSubnet) {
        throw "Postcondition failed after $Stage."
    }
    if ($Stage -eq 'PrepareTemporary' -and (Test-SubnetHasAllocations $after.temporary)) {
        throw 'New temporary subnet unexpectedly has allocations.'
    }
    $result.controlPlaneVerifiedStages += $Stage
    Write-MigrationLog 'Control-plane postconditions verified; checking gateway health next.'
    Save-MigrationEvidence 'result.json' $result
    Assert-MockHealth "$Stage-http-after"
    $result.completedStages += $Stage
    Save-MigrationEvidence 'result.json' $result
    Write-MigrationLog ("Stage verified; elapsed={0:F1}s" -f $timer.Elapsed.TotalSeconds)
}

try {
    Write-MigrationLog "Action=$Action; subscription=$SubscriptionId; resourceGroup=$ResourceGroup; APIM=$ApimName"
    Write-MigrationLog "Evidence: $runDirectory"
    Write-MigrationLog "Log: $logPath"
    Write-MigrationLog ("Follow in another terminal: Get-Content -LiteralPath '{0}' -Tail 50 -Wait" -f $logPath.Replace("'", "''"))
    Write-MigrationLog "Poll interval=${PollSeconds}s; timeout per wait=${TimeoutSeconds}s. CLI calls can take longer; Azure operations are not canceled on timeout."
    Save-MigrationEvidence 'result.json' $result
    Write-MigrationLog 'Reading initial Azure state.'
    $before = Get-LabSnapshot @lab -IncludeTemporarySubnet -Log $log
    Save-MigrationEvidence 'before.json' $before
    if ($Action -eq 'Snapshot') {
        $result.outcome = 'SnapshotOnly'
        Write-MigrationLog 'Read-only snapshot captured; inspect before.json for resource state.'
        return $before
    }
    Write-MigrationState $before
    Assert-MigrationStage -Stage $Action -State $before
    Write-MigrationLog 'Preflight safety checks passed. Requesting approval (or evaluating -WhatIf); no mutation submitted yet.'
    if (-not $PSCmdlet.ShouldProcess("$SubscriptionId / $ResourceGroup / $ApimName",
        "${Action}: lab-only temporary subnet migration; downtime and IP changes possible; temporary subnet retained")) {
        $result.outcome = 'Skipped'
        Write-MigrationLog 'Skipped: confirmation declined or -WhatIf; no Azure mutation submitted.'
        return
    }
    $result.outcome = 'InProgress'
    Write-MigrationLog 'Approved; beginning requested migration stages.'
    $stages = if ($Action -eq 'Run') { @('PrepareTemporary', 'MoveTemporary', 'ResizeEmpty', 'MoveBack') } else { @($Action) }
    foreach ($stage in $stages) { Invoke-MigrationStage $stage }
    $result.outcome = 'Verified'
    Write-MigrationLog 'Requested stages verified, including point-in-time mock health. Temporary subnet retained; no cleanup performed.'
} catch {
    $result.outcome = 'Failed'
    $result.error = $_.Exception.Message
    Write-MigrationLog $result.error -Level ERROR
    Write-MigrationLog "Failure location: $($_.InvocationInfo.PositionMessage)`n$($_.ScriptStackTrace)" -Level ERROR
    Write-MigrationLog $result.recovery -Level WARN
    Write-Warning $result.recovery
    Save-MigrationEvidence 'result.json' $result
    try { Save-MigrationEvidence 'after-error.json' (Get-LabSnapshot @lab -IncludeTemporarySubnet -Log $log) }
    catch {
        Write-MigrationLog "Could not capture error snapshot: $($_.Exception.Message)" -Level WARN
        Write-Warning "Could not capture error snapshot: $($_.Exception.Message)"
    }
    throw
} finally {
    $result.finishedAtUtc = [DateTime]::UtcNow.ToString('o')
    Save-MigrationEvidence 'result.json' $result
    Write-MigrationLog ("Outcome={0}; elapsed={1:F1}s; completedStages={2}" -f
        $result.outcome, $runTimer.Elapsed.TotalSeconds, ($result.completedStages -join ','))
}

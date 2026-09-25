#Requires -Version 7.0
[CmdletBinding()]
param([string]$TestEnvFile = (Join-Path $PSScriptRoot '..\..\.env.test'))
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$testEnvironment = Get-TestEnvironment -EnvFile $TestEnvFile
$script:passed = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:passed++
}
$subscription = $testEnvironment.Target.SubscriptionId
$group = $testEnvironment.Target.ResourceGroup
$apimName = $testEnvironment.Target.ApimName
$root = "/subscriptions/$subscription/resourceGroups/$group"
$vnetId = "$root/providers/Microsoft.Network/virtualNetworks/vnet-apim-resize-poc"
$originalId = "$vnetId/subnets/snet-apim-original"
$temporaryId = "$vnetId/subnets/snet-apim-temporary"
$tags = @{ purpose = 'apim-subnet-resize-poc'; environment = 'lab' }
$fixture = @{
    group = @{ id = $root; tags = $tags }
    apim = @{
        id = "$root/providers/Microsoft.ApiManagement/service/$apimName"; tags = $tags
        sku = @{ name = 'Developer'; capacity = 1 }; platformVersion = 'stv2'
        virtualNetworkType = 'External'; provisioningState = 'Succeeded'; location = $testEnvironment.Location
        virtualNetworkConfiguration = @{ subnetResourceId = $originalId }
    }
    vnet = @{
        id = $vnetId; tags = $tags; location = $testEnvironment.Location; provisioningState = 'Succeeded'
        addressSpace = @{ addressPrefixes = @('10.90.0.0/16') }
        subnets = @(@{ id = $originalId; name = 'snet-apim-original' })
        dhcpOptions = @{ dnsServers = @() }
    }
    original = @{
        id = $originalId; addressPrefix = '10.90.0.0/27'; provisioningState = 'Succeeded'
        networkSecurityGroup = @{ id = "$root/providers/Microsoft.Network/networkSecurityGroups/nsg-apim-resize-poc" }
        ipConfigurations = @(@{ id = 'managed-apim-nic/ipconfig' })
    }
    temporary = $null
} | ConvertTo-Json -Depth 30
$lab = @{ SubscriptionId = $subscription; ResourceGroup = $group; ApimName = $apimName }
$migration = Join-Path $PSScriptRoot '..\..\scripts\ps1\Invoke-SubnetMigration.ps1'
$evidence = Join-Path ([IO.Path]::GetTempPath()) ("apim-migration-tests-{0}" -f [guid]::NewGuid().ToString('N'))
if (Get-Variable ApimMigrationTestContext -Scope Global -ErrorAction SilentlyContinue) {
    throw 'A test context already exists; use a fresh PowerShell process.'
}
$global:ApimMigrationTestContext = @{}

function Set-TestTemporary {
    param([switch]$OnTemporary, [switch]$Expanded)
    $state = $global:ApimMigrationTestContext.State
    $state.temporary = @{
        id = $temporaryId; addressPrefix = '10.90.1.0/27'; provisioningState = 'Succeeded'
        networkSecurityGroup = @{ id = $state.original.networkSecurityGroup.id }; ipConfigurations = @()
    }
    $state.vnet.subnets += @{ id = $temporaryId; name = 'snet-apim-temporary' }
    if ($OnTemporary) {
        $state.apim.virtualNetworkConfiguration.subnetResourceId = $temporaryId
        $state.original.ipConfigurations = @()
        $state.temporary.ipConfigurations = @(@{ id = 'managed-apim-nic/ipconfig' })
    }
    if ($Expanded) { $state.original.addressPrefix = '10.90.0.0/26' }
}

# Every CLI command is intercepted; unknown commands fail rather than falling through to Azure.
function az {
    $command = $args -join ' '
    $c = $global:ApimMigrationTestContext
    $global:LASTEXITCODE = 0
    if ($command -notmatch "--subscription $($c.ExpectedLab.SubscriptionId) " -or
        $command -notmatch "(--resource-group|--name) $($c.ExpectedLab.ResourceGroup) ") { throw 'Missing explicit scope.' }
    $logs = @(Get-ChildItem -LiteralPath $c.EvidencePath -Filter migration.log -Recurse)
    if ($logs.Count -ne 1) { throw 'Log must exist before every CLI call.' }
    $liveLog = Get-Content -LiteralPath $logs[0].FullName -Raw
    if (-not $liveLog.Contains("CLI START: az $command")) { throw 'CLI start must be immediately readable before execution.' }
    if ($c.Fault -eq 'invalid-json') { return 'not json' }
    if ($command -match '^group show ') { return ($c.State.group | ConvertTo-Json -Depth 30) }
    if ($command -match '^apim show ') {
        if ($c.PendingTarget) {
            if ($c.PollsRemaining -gt 0) {
                $c.PollsRemaining--
                return ($c.State.apim | ConvertTo-Json -Depth 30)
            }
            $c.State.apim.virtualNetworkConfiguration.subnetResourceId = $c.PendingTarget
            $c.State.apim.provisioningState = 'Succeeded'
            $c.PendingTarget = $null
        }
        return ($c.State.apim | ConvertTo-Json -Depth 30)
    }
    if ($command -match '^network vnet show ') { return ($c.State.vnet | ConvertTo-Json -Depth 30) }
    if ($command -match '^network vnet subnet show ') {
        if ($command -match '--name snet-apim-temporary ') { return ($c.State.temporary | ConvertTo-Json -Depth 30) }
        if ($command -notmatch '--name snet-apim-original ') { throw 'Unexpected subnet read.' }
        if ($c.State.apim.virtualNetworkConfiguration.subnetResourceId -eq $temporaryId -and $c.ReleaseAfter -gt 0) {
            $c.ReleaseReads++
            if ($c.ReleaseReads -ge $c.ReleaseAfter) { $c.State.original.ipConfigurations = @() }
        }
        return ($c.State.original | ConvertTo-Json -Depth 30)
    }
    if ($command -match '^network vnet subnet create ') {
        if ($command -notmatch '--name snet-apim-temporary --address-prefixes 10\.90\.1\.0/27 --network-security-group ' -or
            $command -notlike "*$($c.State.original.networkSecurityGroup.id)*") { throw 'Invalid temporary subnet request.' }
        $c.Mutations.Add('PrepareTemporary')
        if ($c.Fault -eq 'create-reject') { $global:LASTEXITCODE = 1; return 'SimulatedCreateRejected' }
        if ($c.Fault -ne 'create-noop') { Set-TestTemporary }
        return '{}'
    }
    if ($command -match '^apim update ') {
        if ($command -notmatch '--virtual-network External --set virtualNetworkConfiguration\.subnetResourceId=(\S+) --no-wait') {
            throw 'Invalid APIM move request.'
        }
        $target = $Matches[1]
        if ($target -notin @($originalId, $temporaryId)) { throw 'Unexpected move target.' }
        $stage = if ($target -eq $temporaryId) { 'MoveTemporary' } else { 'MoveBack' }
        $c.Mutations.Add($stage)
        if (($c.Fault -eq 'move-reject' -and $stage -eq 'MoveTemporary') -or
            ($c.Fault -eq 'return-reject' -and $stage -eq 'MoveBack')) {
            $global:LASTEXITCODE = 1; return 'SimulatedMoveRejected'
        }
        if ($c.Fault -eq 'move-noop') { return }
        if ($c.Fault -eq 'move-failed') { $c.State.apim.provisioningState = 'Failed'; return }
        $c.State.apim.provisioningState = 'Updating'
        $c.PendingTarget = $target
        if ($stage -eq 'MoveTemporary') {
            $c.State.temporary.ipConfigurations = @(@{ id = 'managed-apim-nic/ipconfig' })
            if ($c.ReleaseAfter -eq 0) { $c.State.original.ipConfigurations = @() }
        } else {
            $c.State.original.ipConfigurations = @(@{ id = 'managed-apim-nic/ipconfig' })
            $c.State.temporary.ipConfigurations = @()
        }
        return
    }
    if ($command -match '^network vnet subnet update ') {
        if ($command -notmatch '--name snet-apim-original --address-prefixes 10\.90\.0\.0/26 ' -or
            $c.State.apim.virtualNetworkConfiguration.subnetResourceId -ne $temporaryId -or
            (Test-SubnetHasAllocations $c.State.original)) { throw 'Unsafe prefix update.' }
        $c.Mutations.Add('ResizeEmpty')
        if ($c.Fault -eq 'resize-reject') { $global:LASTEXITCODE = 1; return 'SimulatedResizeRejected' }
        if ($c.Fault -ne 'resize-noop') { $c.State.original.addressPrefix = '10.90.0.0/26' }
        return ($c.State.original | ConvertTo-Json -Depth 30)
    }
    throw "Unexpected command: $command"
}

function Invoke-WebRequest {
    param($Uri, $TimeoutSec, [switch]$SkipHttpErrorCheck, $MaximumRedirection)
    if ([string]$Uri -ne "https://$($global:ApimMigrationTestContext.ExpectedLab.ApimName).azure-api.net/subnet-poc/health" -or $MaximumRedirection -ne 0) {
        throw 'Unexpected HTTP request.'
    }
    $c = $global:ApimMigrationTestContext
    $c.HttpCalls++
    if ($c.Fault -eq 'health-after-move' -and $c.Mutations.Contains('MoveTemporary')) { throw 'SimulatedHttpTimeout' }
    return @{ StatusCode = $c.HttpStatus; Content = $c.HttpBody }
}

function Invoke-Case {
    param(
        [string]$Name, [string]$Action = 'Run', [scriptblock]$Setup = {},
        [string]$ErrorPattern, [string[]]$ExpectedMutations = @(), [switch]$WhatIf,
        [int]$TimeoutSeconds = 1, [switch]$UseDefaults
    )
    $c = $global:ApimMigrationTestContext
    $c.Clear()
    $c.State = ConvertFrom-Json $fixture -AsHashtable
    $c.Mutations = [System.Collections.Generic.List[string]]::new()
    $c.Fault = ''
    $c.PendingTarget = $null
    $c.PollsRemaining = 0
    $c.ReleaseAfter = 0
    $c.ReleaseReads = 0
    $c.HttpCalls = 0
    $c.HttpStatus = 200
    $c.HttpBody = '{"status":"ok","poc":"apim-subnet-resize"}'
    $caseLab = $lab
    $c.ExpectedLab = $lab
    if ($UseDefaults) {
        $envPath = Join-Path $evidence '.env'
        @("AZURE_SUBSCRIPTION_ID=$subscription", "AZURE_RESOURCE_GROUP=$group", "APIM_NAME=$apimName") |
            Set-Content -LiteralPath $envPath -Encoding utf8
        $caseLab = @{ EnvFile = $envPath }
    }
    & $Setup
    $casePath = Join-Path $evidence $Name
    $c.EvidencePath = $casePath
    $failure = $null
    try {
        $output = @(& $migration @caseLab -Action $Action -TimeoutSeconds $TimeoutSeconds -PollSeconds 1 -EvidenceRoot $casePath -Confirm:$false -WhatIf:$WhatIf)
        if ($Action -eq 'Snapshot') {
            Assert-True ($output.Count -eq 1 -and $output[0] -is [hashtable]) "$Name logging does not pollute snapshot output"
        } else {
            Assert-True ($output.Count -eq 0) "$Name logging does not pollute success output"
        }
    } catch { $failure = $_ }
    if ($ErrorPattern) {
        Assert-True ($null -ne $failure -and $failure.Exception.Message -match $ErrorPattern) "$Name expected $ErrorPattern, got $failure"
    } elseif ($failure) { throw $failure }
    $files = @(Get-ChildItem -LiteralPath $casePath -Filter result.json -Recurse)
    Assert-True ($files.Count -eq 1) "$Name one durable result"
    $report = Get-Content -LiteralPath $files[0].FullName -Raw | ConvertFrom-Json -AsHashtable
    $expectedOutcome = if ($ErrorPattern) { 'Failed' } elseif ($WhatIf) { 'Skipped' } elseif ($Action -eq 'Snapshot') { 'SnapshotOnly' } else { 'Verified' }
    Assert-True ($report.outcome -eq $expectedOutcome) "$Name correct outcome"
    Assert-True (($c.Mutations -join ',') -eq ($ExpectedMutations -join ',')) "$Name exact mutation order and count"
    $logPath = Join-Path $files[0].DirectoryName 'migration.log'
    Assert-True ($report.logPath -eq $logPath) "$Name result links to log"
    $log = Get-Content -LiteralPath $logPath -Raw
    Assert-True ($log -match '\[\d{4}-\d{2}-\d{2}T[^\]]+Z\] \[INFO\] \[Preflight\]') "$Name timestamped leveled stage log"
    Assert-True ($log.Contains("Outcome=$expectedOutcome")) "$Name final outcome logged"
    Assert-True ($log.Contains($c.ExpectedLab.SubscriptionId) -and
        $log.Contains($c.ExpectedLab.ResourceGroup) -and $log.Contains($c.ExpectedLab.ApimName)) "$Name target logged"
    if ($ErrorPattern) {
        Assert-True (-not [string]::IsNullOrWhiteSpace($report.error)) "$Name error preserved"
        if ($c.Fault -eq 'invalid-json') {
            Assert-True ($log.Contains('Could not capture error snapshot')) "$Name recovery snapshot failure logged"
        } else {
            Assert-True (Test-Path (Join-Path $files[0].DirectoryName 'after-error.json')) "$Name error snapshot"
        }
        Assert-True ($log.Contains('[ERROR]') -and $log -match $ErrorPattern) "$Name error logged"
        Assert-True ($log.Contains('No automatic retry')) "$Name recovery guidance logged"
    }
    return @{ Report = $report; Directory = $files[0].DirectoryName; Log = $log }
}

try {
    $success = Invoke-Case -Name success -ExpectedMutations PrepareTemporary, MoveTemporary, ResizeEmpty, MoveBack
    $c = $global:ApimMigrationTestContext
    Assert-True ($c.State.original.addressPrefix -eq '10.90.0.0/26' -and
        $c.State.apim.virtualNetworkConfiguration.subnetResourceId -eq $originalId -and $c.State.temporary) 'Full workflow returns to original /26 and retains temporary subnet'
    Assert-True ($success.Report.completedStages.Count -eq 4 -and $success.Report.controlPlaneVerifiedStages.Count -eq 4) 'All control/data-plane stages verified'
    Assert-True ($c.HttpCalls -eq 8) 'Health checked before and after every stage'
    Assert-True ($success.Log.Contains('CLI END: exit=0') -and $success.Log.Contains('HTTP status=200')) 'CLI completion and HTTP status logged'
    Assert-True ($success.Log.Contains('No response body') -and $success.Log.Contains('submission is not completion')) 'Async submission is not reported as completion'
    foreach ($stage in @('PrepareTemporary', 'MoveTemporary', 'ResizeEmpty', 'MoveBack')) {
        Assert-True ($success.Log.Contains("[$stage] Stage started") -and $success.Log.Contains("[$stage] Stage verified")) "Stage $stage lifecycle logged"
        foreach ($suffix in @('before', 'after', 'response', 'http-before', 'http-after')) {
            Assert-True (Test-Path (Join-Path $success.Directory "$stage-$suffix.json")) "Evidence $stage-$suffix"
        }
    }
    $empty = Get-Content (Join-Path $success.Directory 'ResizeEmpty-verified-empty.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert-True (-not (Test-SubnetHasAllocations $empty.original)) 'Empty original proven immediately before update'
    Assert-True ((Get-Content (Join-Path $success.Directory 'MoveTemporary-response.json') -Raw).Trim() -eq 'null') 'Empty async response preserved, not fabricated'
    foreach ($field in @('ipConfigurations', 'privateEndpoints', 'ipConfigurationProfiles', 'serviceAssociationLinks',
        'resourceNavigationLinks', 'applicationGatewayIPConfigurations')) {
        Assert-True (Test-SubnetHasAllocations @{ $field = @(@{ id = 'occupied' }) }) "Detect allocation $field"
    }
    Assert-True (-not (Test-SubnetHasAllocations @{ ipConfigurations = $null })) 'Null allocations are empty'
    Invoke-Case -Name whatif -WhatIf | Out-Null
    Assert-True ($global:ApimMigrationTestContext.HttpCalls -eq 0) 'WhatIf performs no HTTP mutation-stage probes'
    Invoke-Case -Name snapshot -Action Snapshot -Setup { $c.State.apim.provisioningState = 'Updating' } | Out-Null
    Invoke-Case -Name defaults -Action Snapshot -UseDefaults | Out-Null
    Invoke-Case -Name invalid-json -Action Snapshot -Setup { $c.Fault = 'invalid-json' } -ErrorPattern 'JSON' | Out-Null
    $delayed = Invoke-Case -Name delayed-move -Action MoveTemporary -Setup {
        Set-TestTemporary; $c.PollsRemaining = 1
    } -TimeoutSeconds 3 -ExpectedMutations MoveTemporary
    Assert-True ($delayed.Log.Contains('Poll #1') -and $delayed.Log.Contains('Poll #2') -and
        $delayed.Log.Contains('state=Updating') -and $delayed.Log.Contains('state=Succeeded') -and
        $delayed.Log.Contains("target=$temporaryId") -and $delayed.Log.Contains('elapsed=') -and
        $delayed.Log.Contains('Next poll in 1s')) 'All polls and wait details retained'
    Invoke-Case -Name prepare -Action PrepareTemporary -ExpectedMutations PrepareTemporary | Out-Null
    Invoke-Case -Name move -Action MoveTemporary -Setup { Set-TestTemporary } -ExpectedMutations MoveTemporary | Out-Null
    Invoke-Case -Name resize -Action ResizeEmpty -Setup { Set-TestTemporary -OnTemporary } -ExpectedMutations ResizeEmpty | Out-Null
    Invoke-Case -Name back -Action MoveBack -Setup { Set-TestTemporary -OnTemporary -Expanded } -ExpectedMutations MoveBack | Out-Null
    Invoke-Case -Name delayed-release -Setup { $c.ReleaseAfter = 4 } -TimeoutSeconds 3 -ExpectedMutations PrepareTemporary, MoveTemporary, ResizeEmpty, MoveBack | Out-Null
    Assert-True ($global:ApimMigrationTestContext.ReleaseReads -ge 4) 'Waits for delayed release'

    foreach ($case in @(
        @{ Name = 'premium'; Setup = { $c.State.apim.sku.name = 'Premium' }; Error = 'Developer' },
        @{ Name = 'internal'; Setup = { $c.State.apim.virtualNetworkType = 'Internal' }; Error = 'Developer' },
        @{ Name = 'production'; Setup = { $c.State.group.tags.environment = 'production' }; Error = 'environment=lab' },
        @{ Name = 'capacity'; Setup = { $c.State.apim.sku.capacity = 2 }; Error = 'single-unit' },
        @{ Name = 'dns'; Setup = { $c.State.vnet.dhcpOptions.dnsServers = @('10.90.2.4') }; Error = 'default DNS' },
        @{ Name = 'updating'; Setup = { $c.State.apim.provisioningState = 'Updating' }; Error = 'pending or failed' },
        @{ Name = 'extra-subnet'; Setup = { $c.State.vnet.subnets += @{ id = "$vnetId/subnets/extra" } }; Error = 'topology' },
        @{ Name = 'existing-temporary'; Setup = { Set-TestTemporary }; Error = 'explicit stages' },
        @{ Name = 'repeated-run'; Setup = { Set-TestTemporary; $c.State.original.addressPrefix = '10.90.0.0/26' }; Error = 'explicit stages' },
        @{ Name = 'overlap'; Setup = { Set-TestTemporary; $c.State.temporary.addressPrefix = '10.90.0.32/27' }; Error = 'expected healthy' },
        @{ Name = 'temp-nsg'; Setup = { Set-TestTemporary; $c.State.temporary.networkSecurityGroup.id = 'wrong' }; Error = 'NSG' },
        @{ Name = 'temp-route'; Setup = { Set-TestTemporary; $c.State.temporary.routeTable = @{ id = 'route' } }; Error = 'route table' }
    )) {
        Invoke-Case -Name $case.Name -Setup $case.Setup -ErrorPattern $case.Error | Out-Null
    }
    Invoke-Case -Name missing-temp -Action MoveTemporary -ErrorPattern 'empty temporary' | Out-Null
    Invoke-Case -Name occupied-temp -Action MoveTemporary -Setup {
        Set-TestTemporary; $c.State.temporary.privateEndpoints = @(@{ id = 'pe' })
    } -ErrorPattern 'empty temporary' | Out-Null
    Invoke-Case -Name unsafe-resize -Action ResizeEmpty -Setup { Set-TestTemporary } -ErrorPattern 'APIM on temporary' | Out-Null
    Invoke-Case -Name unsafe-return -Action MoveBack -Setup { Set-TestTemporary -OnTemporary } -ErrorPattern 'empty original /26' | Out-Null
    Invoke-Case -Name occupied-return -Action MoveBack -Setup {
        Set-TestTemporary -OnTemporary -Expanded; $c.State.original.serviceAssociationLinks = @(@{ id = 'link' })
    } -ErrorPattern 'empty original /26' | Out-Null
    foreach ($case in @(
        @{ Fault = 'create-reject'; Error = 'SimulatedCreateRejected'; Mutations = @('PrepareTemporary') },
        @{ Fault = 'create-noop'; Error = 'Postcondition'; Mutations = @('PrepareTemporary') },
        @{ Fault = 'move-reject'; Error = 'SimulatedMoveRejected'; Mutations = @('PrepareTemporary', 'MoveTemporary') },
        @{ Fault = 'move-noop'; Error = 'Timeout waiting for APIM'; Mutations = @('PrepareTemporary', 'MoveTemporary') },
        @{ Fault = 'move-failed'; Error = 'terminal state Failed'; Mutations = @('PrepareTemporary', 'MoveTemporary') },
        @{ Fault = 'resize-reject'; Error = 'SimulatedResizeRejected'; Mutations = @('PrepareTemporary', 'MoveTemporary', 'ResizeEmpty') },
        @{ Fault = 'resize-noop'; Error = 'Postcondition'; Mutations = @('PrepareTemporary', 'MoveTemporary', 'ResizeEmpty') },
        @{ Fault = 'return-reject'; Error = 'SimulatedMoveRejected'; Mutations = @('PrepareTemporary', 'MoveTemporary', 'ResizeEmpty', 'MoveBack') },
        @{ Fault = 'health-after-move'; Error = 'SimulatedHttpTimeout'; Mutations = @('PrepareTemporary', 'MoveTemporary') }
    )) {
        $test = Invoke-Case -Name $case.Fault -Setup { $c.Fault = $case.Fault } -ErrorPattern $case.Error -ExpectedMutations $case.Mutations
        if ($case.Fault -eq 'health-after-move') {
            Assert-True ($test.Report.controlPlaneVerifiedStages.Count -eq 2 -and $test.Report.completedStages.Count -eq 1) 'Health failure distinguishes verified control plane'
        }
    }
    Invoke-Case -Name stale-allocations -Setup { $c.ReleaseAfter = -1 } -ErrorPattern 'Timeout waiting for original' `
        -ExpectedMutations PrepareTemporary, MoveTemporary | Out-Null
    Invoke-Case -Name persistent-link -Action ResizeEmpty -Setup {
        Set-TestTemporary -OnTemporary; $c.State.original.resourceNavigationLinks = @(@{ id = 'link' })
    } -ErrorPattern 'Timeout waiting for original' | Out-Null
    foreach ($body in @('{"status":"bad","poc":"apim-subnet-resize"}', '{"status":"ok","poc":"apim-subnet-resize","extra":1}', '[]', 'not json')) {
        Invoke-Case -Name ("bad-payload-{0}" -f [guid]::NewGuid().ToString('N')) -Setup { $c.HttpBody = $body } `
            -ErrorPattern 'payload|JSON' | Out-Null
    }
    Invoke-Case -Name http-503 -Setup { $c.HttpStatus = 503 } -ErrorPattern 'HTTP status 503' | Out-Null
    Invoke-Case -Name null-dns -Setup { $c.State.vnet.dhcpOptions = $null } -Action PrepareTemporary -ExpectedMutations PrepareTemporary | Out-Null

    $defaultGuardRejected = $false
    try { Assert-LabState -State $global:ApimMigrationTestContext.State @lab } catch { $defaultGuardRejected = $true }
    Assert-True $defaultGuardRejected 'Direct experiment still rejects two-subnet topology'
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($migration, [ref]$null, [ref]$parseErrors) | Out-Null
    Assert-True ($parseErrors.Count -eq 0) 'Migration script parses cleanly'
} finally {
    Remove-Item Function:\az
    Remove-Item Function:\Invoke-WebRequest
    Remove-Variable ApimMigrationTestContext -Scope Global
    if (Test-Path -LiteralPath $evidence) {
        Get-ChildItem -LiteralPath $evidence -File -Recurse | Remove-Item
        Get-ChildItem -LiteralPath $evidence -Directory -Recurse |
            Sort-Object { $_.FullName.Length } -Descending | Remove-Item
        Remove-Item -LiteralPath $evidence
    }
}
Write-Host "PASS: $script:passed migration assertions. Azure CLI and HTTP were mocked; no cloud resources were accessed."

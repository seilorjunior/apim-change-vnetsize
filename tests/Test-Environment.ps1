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
    param([scriptblock]$Action, [string]$Pattern)
    $failure = $null
    try { & $Action | Out-Null } catch { $failure = $_ }
    Assert-True ($null -ne $failure -and $failure.Exception.Message -match $Pattern) "Expected $Pattern; got $failure"
}

$root = Join-Path ([IO.Path]::GetTempPath()) ("apim-env-tests-{0}" -f [guid]::NewGuid().ToString('N'))
$scripts = Join-Path $root 'scripts'
$envFile = Join-Path $root '.env'
$missingFile = Join-Path $root '.env.missing'
$lab = @{
    SubscriptionId = '00000000-0000-0000-0000-000000000001'
    ResourceGroup = 'rg-apim-resize-poc-test'
    ApimName = 'apim-resize-poc-test'
}
$valid = @("AZURE_SUBSCRIPTION_ID=$($lab.SubscriptionId)",
    "AZURE_RESOURCE_GROUP=$($lab.ResourceGroup)", "APIM_NAME=$($lab.ApimName)")
if (Get-Variable ApimEnvironmentTestContext -Scope Global -ErrorAction SilentlyContinue) {
    throw 'A test context already exists; use a fresh PowerShell process.'
}
$global:ApimEnvironmentTestContext = @{ Calls = 0; Expected = $lab }

function az {
    $c = $global:ApimEnvironmentTestContext
    $c.Calls++
    $command = $args -join ' '
    if ($command -notmatch '--subscription 00000000-0000-0000-0000-000000000001' -or
        ($command -notmatch '--resource-group rg-apim-resize-poc-test' -and
         $command -notmatch 'group show --name rg-apim-resize-poc-test')) {
        throw 'Unexpected mock target.'
    }
    if ($command -notmatch '^(group show|apim show|network vnet show|network vnet subnet show) ') {
        throw 'Only snapshot reads are allowed.'
    }
    if ($command.StartsWith('apim show ') -and $command -notmatch ("--name {0}( |$)" -f [regex]::Escape($c.Expected.ApimName))) {
        throw 'Unexpected mock APIM name.'
    }
    $global:LASTEXITCODE = 0
    return '{"id":"mock","subnets":[]}'
}

try {
    New-Item -ItemType Directory -Path $scripts | Out-Null
    $valid | Set-Content -LiteralPath $envFile -Encoding utf8
    $loaded = Get-LabEnvironment -EnvFile $envFile
    Assert-True ($loaded.Count -eq 3) 'Load all configured keys'
    $resolved = Resolve-LabTarget -Overrides @{} -EnvFile $envFile
    foreach ($key in $lab.Keys) { Assert-True ($resolved[$key] -eq $lab[$key]) "Resolve $key from file" }
    $override = Resolve-LabTarget -Overrides @{ ApimName = 'apim-resize-poc-override' } -EnvFile $envFile
    Assert-True ($override.ApimName -eq 'apim-resize-poc-override' -and $override.SubscriptionId -eq $lab.SubscriptionId) 'Explicit parameter overrides only its file value'
    $resolved = Resolve-LabTarget -Overrides $lab -EnvFile $missingFile
    Assert-True ($resolved.ApimName -eq $lab.ApimName) 'Complete explicit target needs no file'
    Assert-Throws { Resolve-LabTarget -Overrides @{} -EnvFile $missingFile } 'not found'
    Assert-Throws { Resolve-LabTarget -Overrides @{ ApimName = '' } -EnvFile $envFile } 'Missing ApimName'
    Assert-Throws { Resolve-LabTarget -Overrides @{ SubscriptionId = [guid]::Empty } -EnvFile $envFile } 'non-empty GUID'

    $literals = @('# comment', '', 'AZURE_SUBSCRIPTION_NAME="literal $env:USERPROFILE $(throw ''not executed'') # = value"',
        "APIM_PUBLISHER_EMAIL='test@example.invalid'")
    $literals | Set-Content -LiteralPath $envFile -Encoding utf8
    $loaded = Get-LabEnvironment -EnvFile $envFile
    Assert-True ($loaded.AZURE_SUBSCRIPTION_NAME -eq 'literal $env:USERPROFILE $(throw ''not executed'') # = value') 'Quoted values are literal, including dollar signs, equals and hashes'
    Assert-True ($loaded.APIM_PUBLISHER_EMAIL -eq 'test@example.invalid' -and $loaded.Count -eq 2) 'Quotes stripped; blank lines and full-line comments ignored'

    foreach ($case in @(
        @{ Lines = @('export APIM_NAME=test'); Pattern = 'Invalid .env syntax' },
        @{ Lines = @('apim_name=test'); Pattern = 'Invalid .env syntax' },
        @{ Lines = @('UNKNOWN_KEY=value'); Pattern = 'Unknown or duplicate' },
        @{ Lines = @('APIM_NAME=one', 'APIM_NAME=two'); Pattern = 'Unknown or duplicate' },
        @{ Lines = @('APIM_NAME="unclosed'); Pattern = 'Unclosed .env quote' }
    )) {
        $case.Lines | Set-Content -LiteralPath $envFile -Encoding utf8
        Assert-Throws { Get-LabEnvironment -EnvFile $envFile } $case.Pattern
    }
    $invalidTargets = @(
        @{ Lines = @(); Pattern = 'Missing' },
        @{ Lines = $valid[0..1]; Pattern = 'Missing ApimName' },
        @{ Lines = $valid.Replace("APIM_NAME=$($lab.ApimName)", 'APIM_NAME='); Pattern = 'Missing ApimName' },
        @{ Lines = $valid.Replace("AZURE_SUBSCRIPTION_ID=$($lab.SubscriptionId)", 'AZURE_SUBSCRIPTION_ID=invalid'); Pattern = 'non-empty GUID' },
        @{ Lines = $valid.Replace("AZURE_RESOURCE_GROUP=$($lab.ResourceGroup)", 'AZURE_RESOURCE_GROUP=production'); Pattern = 'lab prefixes' },
        @{ Lines = $valid.Replace("APIM_NAME=$($lab.ApimName)", 'APIM_NAME=production'); Pattern = 'lab prefixes' }
    )
    foreach ($case in $invalidTargets) {
        [IO.File]::WriteAllLines($envFile, [string[]]$case.Lines)
        Assert-Throws { Resolve-LabTarget -Overrides @{} -EnvFile $envFile } $case.Pattern
        foreach ($name in @('Invoke-SubnetExperiment.ps1', 'Invoke-SubnetMigration.ps1')) {
            $entry = Join-Path $PSScriptRoot "..\scripts\$name"
            $evidence = Join-Path $root 'invalid-evidence'
            Assert-Throws { & $entry -Action Snapshot -EnvFile $envFile -EvidenceRoot $evidence } $case.Pattern
            Assert-True (-not (Test-Path -LiteralPath $evidence)) "$name invalid target creates no run artifacts"
        }
    }
    Assert-True ($global:ApimEnvironmentTestContext.Calls -eq 0) 'Invalid configurations never call Azure CLI'

    $valid | Set-Content -LiteralPath $envFile -Encoding utf8
    foreach ($name in @('Common.ps1', 'Invoke-SubnetExperiment.ps1', 'Invoke-SubnetMigration.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "..\scripts\$name") -Destination (Join-Path $scripts $name)
    }
    Push-Location $scripts
    try {
        foreach ($name in @('Invoke-SubnetExperiment.ps1', 'Invoke-SubnetMigration.ps1')) {
            $entry = Join-Path $scripts $name
            $snapshot = & $entry -Action Snapshot -EvidenceRoot (Join-Path $root 'snapshots')
            Assert-True ($snapshot -is [hashtable] -and $snapshot.apim.id -eq 'mock') "$name finds project-root .env from scripts directory"
        }
    } finally { Pop-Location }
    Assert-True ($global:ApimEnvironmentTestContext.Calls -eq 8) 'Snapshot integrations issue only four mocked reads each'

    $global:ApimEnvironmentTestContext.Expected = @{ ApimName = 'apim-resize-poc-override' }
    foreach ($name in @('Invoke-SubnetExperiment.ps1', 'Invoke-SubnetMigration.ps1')) {
        $entry = Join-Path $scripts $name
        $snapshot = & $entry -Action Snapshot -ApimName 'apim-resize-poc-override' -EvidenceRoot (Join-Path $root 'overrides')
        Assert-True ($snapshot.apim.id -eq 'mock') "$name uses explicit APIM parameter over local file"
    }
    Assert-True ($global:ApimEnvironmentTestContext.Calls -eq 16) 'Overrides preserve read-only snapshot operations'

    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '..\scripts') -Filter '*.ps1') {
        $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$parseErrors) | Out-Null
        Assert-True ($parseErrors.Count -eq 0) "$($file.Name) parses cleanly"
    }
} finally {
    Remove-Item Function:\az
    Remove-Variable ApimEnvironmentTestContext -Scope Global
    if (Test-Path -LiteralPath $root) {
        Get-ChildItem -LiteralPath $root -File -Recurse -Force | Remove-Item -Force
        Get-ChildItem -LiteralPath $root -Directory -Recurse |
            Sort-Object { $_.FullName.Length } -Descending | Remove-Item
        Remove-Item -LiteralPath $root
    }
}
Write-Host "PASS: $script:passed configuration assertions. Azure CLI was mocked; no cloud resources were accessed."

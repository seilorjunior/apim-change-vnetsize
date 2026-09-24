#Requires -Version 7.0
. (Join-Path $PSScriptRoot '..\scripts\Common.ps1')

function Get-TestEnvironment {
    param([string]$EnvFile = (Join-Path $PSScriptRoot '..\.env.test'))
    if ([IO.Path]::GetFileName($EnvFile) -eq '.env') {
        throw 'Offline tests must not load operational .env files. Use a synthetic .env.test file.'
    }
    if (-not (Test-Path -LiteralPath $EnvFile -PathType Leaf)) {
        throw "Test environment file not found: $EnvFile. Copy .env.test.example to .env.test or supply -TestEnvFile with a synthetic configuration."
    }
    $values = Get-LabEnvironment -EnvFile $EnvFile
    $keys = @('AZURE_SUBSCRIPTION_ID', 'AZURE_RESOURCE_GROUP', 'APIM_NAME', 'AZURE_LOCATION')
    if (@($values.Keys | Where-Object { $_ -notin $keys }).Count -gt 0) {
        throw 'Test configuration accepts only the four keys in .env.test.example; do not copy operational metadata.'
    }
    foreach ($key in $keys) {
        if ([string]::IsNullOrWhiteSpace($values[$key])) {
            throw "Missing $key in test configuration."
        }
    }
    $target = Resolve-LabTarget -Overrides @{
        SubscriptionId = $values.AZURE_SUBSCRIPTION_ID
        ResourceGroup = $values.AZURE_RESOURCE_GROUP
        ApimName = $values.APIM_NAME
    }
    if ($target.SubscriptionId -notmatch '^00000000-0000-0000-0000-[0-9a-f]{12}$' -or
        $target.ResourceGroup -notmatch '^rg-apim-resize-poc-test(?:-[a-zA-Z0-9-]+)?$' -or
        $target.ApimName -notmatch '^apim-resize-poc-test(?:-[a-zA-Z0-9-]+)?$') {
        throw 'Use synthetic test identifiers: a nonzero 00000000-0000-0000-0000- GUID and the test name prefixes in .env.test.example.'
    }
    if ($values.AZURE_LOCATION -cnotmatch '^[a-z][a-z0-9]+$') {
        throw 'AZURE_LOCATION in test configuration must be a canonical lowercase region name.'
    }
    return @{ Target = $target; Location = $values.AZURE_LOCATION }
}

#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][uri]$Url,
    [ValidateRange(1, 1440)][int]$DurationMinutes = 180,
    [ValidateRange(1, 60)][int]$IntervalSeconds = 5,
    [ValidateRange(1, 120)][int]$RequestTimeoutSeconds = 10,
    [string]$EvidenceRoot = (Join-Path $PSScriptRoot '..\artifacts')
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
if ($Url.Scheme -ne 'https' -or $Url.DnsSafeHost -notmatch '^apim-resize-poc-[a-z0-9-]+\.azure-api\.net$' -or
    $Url.AbsolutePath -ne '/subnet-poc/health' -or $Url.Query -or $Url.UserInfo -or -not $Url.IsDefaultPort) {
    throw 'Use only the HTTPS mock endpoint of this lab in Azure public cloud.'
}
$directory = Join-Path $EvidenceRoot ("{0}-probe-{1}" -f [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'), [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $directory -Force | Out-Null
$csv = Join-Path $directory 'samples.csv'
$samples = [System.Collections.Generic.List[object]]::new()
$deadline = [DateTime]::UtcNow.AddMinutes($DurationMinutes)
Write-Host "Monitoring $Url. CSV: $csv. Keep this terminal open during all network changes."
try {
    do {
        $sample = [ordered]@{
            timestampUtc = [DateTime]::UtcNow.ToString('o')
            statusCode = 0
            success = $false
            latencyMs = 0
            error = ''
        }
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $response = Invoke-WebRequest -Uri $Url -TimeoutSec $RequestTimeoutSeconds -SkipHttpErrorCheck -MaximumRedirection 0
            $sample.statusCode = [int]$response.StatusCode
            if ($response.StatusCode -ne 200) {
                $sample.error = "Unexpected HTTP status $($response.StatusCode)"
            } else {
                $sample.success = Test-LabMockPayload -Content ([string]$response.Content)
                if (-not $sample.success) { $sample.error = 'Unexpected JSON payload' }
            }
        } catch {
            $sample.error = $_.Exception.Message
        } finally {
            $watch.Stop()
            $sample.latencyMs = [Math]::Round($watch.Elapsed.TotalMilliseconds, 2)
        }
        $row = [pscustomobject]$sample
        $samples.Add($row)
        $row | Export-Csv -LiteralPath $csv -Append -NoTypeInformation -Encoding utf8
        if (-not $sample.success) { Write-Warning "$($sample.timestampUtc): $($sample.error)" }
        Start-Sleep -Seconds $IntervalSeconds
    } while ([DateTime]::UtcNow -lt $deadline)
} finally {
    if ($samples.Count -gt 0) {
        $summary = Get-ProbeSummary -Samples $samples.ToArray()
        $summary | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $directory 'summary.json') -Encoding utf8
        $summary
    }
}

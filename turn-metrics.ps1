#requires -Version 7.0
param(
    [ValidateSet('en', 'tr')][string]$Language = 'tr',
    [switch]$HideCost
)

$ErrorActionPreference = 'Stop'

function Get-TokenCount {
    param([object]$Value)

    if ($null -eq $Value) {
        return $null
    }
    $count = [int64]$Value
    if ($count -ge 0) {
        return $count
    }
    return $null
}

function Format-Metric {
    param([object]$Value, [string]$Format = 'F1', [string]$Suffix = '')

    if ($null -eq $Value) {
        return 'n/a'
    }
    return $Value.ToString($Format, [Globalization.CultureInfo]::InvariantCulture) + $Suffix
}

function Format-TokenCount {
    param([object]$Value)

    if ($null -eq $Value) {
        return 'n/a'
    }
    $culture = if ($Language -eq 'tr') { 'tr-TR' } else { 'en-US' }
    return $Value.ToString('N0', [Globalization.CultureInfo]::GetCultureInfo($culture))
}

function Get-ApiTokenCost {
    param($Catalog, [string]$Model, [string]$Tier, $InputTokens, $CachedTokens, $WriteTokens, $OutputTokens)

    if ($null -eq $Catalog -or [string]::IsNullOrWhiteSpace($Model) -or
        $null -eq $InputTokens -or $null -eq $CachedTokens -or $null -eq $OutputTokens) {
        return $null
    }
    $band = if ($InputTokens -gt $Catalog.long_context_threshold) { 'long' } else { 'short' }
    $rates = $Catalog.models.$Model.$Tier.$band
    if ($rates.Count -ne 4 -or $null -eq $rates[0] -or $null -eq $rates[1] -or
        $null -eq $rates[3] -or $Catalog.unit_tokens -le 0) { return $null }
    if ($null -eq $WriteTokens) {
        if ($null -ne $rates[2]) { return $null }
        $WriteTokens = 0
    }
    if ($WriteTokens -gt 0 -and $null -eq $rates[2]) { return $null }
    $uncachedTokens = $InputTokens - $CachedTokens - $WriteTokens
    if ($uncachedTokens -lt 0) { return $null }
    return ([decimal]$uncachedTokens * [decimal]$rates[0] +
        [decimal]$CachedTokens * [decimal]$rates[1] +
        [decimal]$WriteTokens * [decimal]$rates[2] +
        [decimal]$OutputTokens * [decimal]$rates[3]) / [decimal]$Catalog.unit_tokens
}

function Format-Usd {
    param($Value)
    if ($null -eq $Value) { return 'n/a' }
    return '$' + $Value.ToString('F4', [Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-UnixMilliseconds {
    param([object]$Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [DateTime]) {
        return ([DateTimeOffset]$Value).ToUnixTimeMilliseconds()
    }
    if ($Value -is [DateTimeOffset]) {
        return $Value.ToUnixTimeMilliseconds()
    }

    $parsed = [DateTimeOffset]::Parse(
        [string]$Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal
    )
    return $parsed.ToUnixTimeMilliseconds()
}

function Is-InputItem {
    param([object]$Payload)

    $type = [string]$Payload.type
    if ($type -eq 'agent_message' -or $type.EndsWith('_call_output')) {
        return $true
    }

    return $type -eq 'message' -and [string]$Payload.role -in @('user', 'developer', 'system')
}

function Is-GeneratedItem {
    param([object]$Payload)

    $type = [string]$Payload.type
    if ($type -eq 'reasoning' -or $type.EndsWith('_call')) {
        return $true
    }

    return $type -eq 'message' -and [string]$Payload.role -eq 'assistant'
}


try {
    $hookInputText = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($hookInputText)) { exit 0 }
    $hookInput = $hookInputText | ConvertFrom-Json -Depth 20
    $event = [string]$hookInput.hook_event_name
    if ($event -notin @('Stop', 'SubagentStop')) { exit 0 }
    $turnId = [string]$hookInput.turn_id
    $transcriptPath = if ($event -eq 'SubagentStop') { [string]$hookInput.agent_transcript_path } else { [string]$hookInput.transcript_path }
    if (-not $turnId -or -not $transcriptPath -or -not (Test-Path -LiteralPath $transcriptPath -PathType Leaf)) {
        exit 0
    }
    . (Join-Path $PSScriptRoot 'turn-metrics-reader.ps1')
    . (Join-Path $PSScriptRoot 'turn-metrics-summary.ps1')
    . (Join-Path $PSScriptRoot 'turn-metrics-display.ps1')
    $result = Read-MetricsTranscript $transcriptPath '' ([string]$hookInput.model) ([string]$hookInput.session_id)
    $sessionMain = @($result.Samples)
    $samples = if ($event -eq 'Stop') { @($sessionMain | Where-Object { $_.TurnId -eq $turnId }) } else { $sessionMain }
    if (-not $samples.Count) {
        if ($event -eq 'SubagentStop') { '{}' }
        exit 0
    }
    $storeAvailable = $false
    try {
        . (Join-Path $PSScriptRoot 'turn-metrics-store.ps1')
        $storeAvailable = $true
    }
    catch { }
    $childSnapshots = @()
    $discoveryWarning = $null
    if ($storeAvailable -and $event -eq 'Stop' -and $result.Metadata.id -and -not $samples[0].IsSubagent) {
        $discovery = Get-UsageChildTranscripts ([string]$result.Metadata.id)
        $discoveryWarning = $discovery.Warning
        foreach ($childPath in $discovery.Paths) {
            try {
                $child = Read-MetricsTranscript $childPath '' '' ''
                $childSnapshots += @($child.Samples | Where-Object { $_.RootTurnId -in $sessionMain.RootTurnId })
            }
            catch { $discoveryWarning = '⚠ Bazı alt ajan kayıtları okunamadı; toplam kısmi olabilir.' }
        }
    }
    $pricing = $null
    try {
        $pricing = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'turn-metrics-pricing.json') -Raw | ConvertFrom-Json -Depth 10
    }
    catch { }
    foreach ($sample in (@($sessionMain) + $childSnapshots)) {
        $arguments = @($sample.InputTokens, $sample.CachedTokens, $sample.CacheWriteTokens, $sample.OutputTokens)
        $sample | Add-Member -NotePropertyName StandardCost -NotePropertyValue (Get-ApiTokenCost $pricing $sample.Model 'standard' @arguments)
        $sample | Add-Member -NotePropertyName FastCost -NotePropertyValue (Get-ApiTokenCost $pricing $sample.Model 'fast' @arguments)
    }
    $stored = $null
    $warning = $null
    try {
        $stored = Write-UsageCalls (@($sessionMain) + $childSnapshots) $hookInput $result.Metadata $pricing
        $warning = $stored.Warning
    }
    catch { $warning = '⚠ Kullanım DB kaydı başlatılamadı; alt ajan toplamı doğrulanamadı.' }
    if ($event -eq 'SubagentStop') {
        $output = if ($warning) { @{ systemMessage = Convert-MetricsDisplay $warning $Language $HideCost } } else { @{} }
        $output | ConvertTo-Json -Compress -EscapeHandling EscapeNonAscii
        exit 0
    }
    $metricText = Format-MetricsGroup $samples '👤 Ana oturum / bu istek'
    $children = if ($warning) { @($childSnapshots | Where-Object { $_.RootTurnId -eq $samples[0].RootTurnId }) } else { @($stored.SubagentSamples | Where-Object { $null -ne $_ }) }
    if ($children.Count) {
        $agentCount = @($children.SessionId | Sort-Object -Unique).Count
        $metricText += "`n`n" + (Format-MetricsGroup $children ("🤖 Alt ajanlar / bu istek · {0} ajan" -f $agentCount))
    }
    $allSamples = @($samples) + $children
    $metricText += "`n`nΣ Genel toplam · Input {0} · Output {1} (Reasoning {2})" -f @(
        (Format-MetricsSum $allSamples 'InputTokens'), (Format-MetricsSum $allSamples 'OutputTokens'), (Format-MetricsSum $allSamples 'ReasoningTokens')
    )
    $metricText += "`n" + (Format-MetricsCache $allSamples '↻ Genel toplam · Cache')
    $metricText += "`n💵 Genel toplam · {0} çağrı · Standard≈ {1} · Fast≈ {2}" -f @(
        $allSamples.Count, (Format-MetricsSum $allSamples 'StandardCost' -Money), (Format-MetricsSum $allSamples 'FastCost' -Money)
    )
    $sessionSamples = if ($stored.SessionSamples) { @($stored.SessionSamples) } else { @($sessionMain) + $childSnapshots }
    $metricText += "`n`n" + (Format-MetricsSession $sessionSamples)
    if ($warning) { $metricText += "`n$warning" }
    if ($discoveryWarning) { $metricText += "`n$discoveryWarning" }
    @{ systemMessage = Convert-MetricsDisplay $metricText $Language $HideCost } | ConvertTo-Json -Compress -EscapeHandling EscapeNonAscii
}
catch {
    exit 0
}

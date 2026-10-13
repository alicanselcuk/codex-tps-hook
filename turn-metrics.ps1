#requires -Version 7.0
param(
    [ValidateSet('en', 'tr')][string]$Language = 'tr',
    [switch]$HideCost
)

$ErrorActionPreference = 'Stop'

# Metrics describe the last model response in the turn, not turn-wide totals.
# output_tokens already includes reasoning_output_tokens; never add it twice.
# Item lifecycle/input timestamps approximate generation and request timing.
# Completed response_item timestamps alone cannot identify the first token.

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
    # Cache writes replace uncached input billing; output already includes reasoning.
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
    if ([string]::IsNullOrWhiteSpace($hookInputText)) {
        exit 0
    }

    $hookInput = $hookInputText | ConvertFrom-Json -Depth 20
    if ([string]$hookInput.hook_event_name -ne 'Stop') {
        exit 0
    }

    $turnId = [string]$hookInput.turn_id
    $transcriptPath = [string]$hookInput.transcript_path
    if ([string]::IsNullOrWhiteSpace($turnId) -or
        [string]::IsNullOrWhiteSpace($transcriptPath) -or
        -not (Test-Path -LiteralPath $transcriptPath -PathType Leaf)) {
        exit 0
    }

    $requestStartMs = $null
    $lastGeneratedMs = $null
    $firstTimedItemMs = $null
    $firstMessageMs = $null
    $lastTimedItemMs = $null
    $latestSample = $null
    $insideTurn = $false
    $currentModel = [string]$hookInput.model
    $pricing = $null
    try {
        $pricing = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'turn-metrics-pricing.json') -Raw |
            ConvertFrom-Json -Depth 10
    }
    catch { } # Optional pricing must not hide throughput/token metrics.

    $stream = [IO.FileStream]::new(
        $transcriptPath,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite
    )
    $reader = [IO.StreamReader]::new($stream)

    try {
        while (($line = $reader.ReadLine()) -ne $null) {
            if (-not $insideTurn -and
                (-not $line.Contains($turnId) -or -not $line.Contains('"type":"task_started"'))) {
                continue
            }

            try {
                $record = $line | ConvertFrom-Json -Depth 30
            }
            catch {
                continue
            }

            $payload = $record.payload
            $payloadType = [string]$payload.type
            if (-not $insideTurn) {
                if ($record.type -ne 'event_msg' -or
                    $payloadType -ne 'task_started' -or
                    [string]$payload.turn_id -ne $turnId) {
                    continue
                }
                $insideTurn = $true
            }

            $recordTurnId = [string]$record.turn_id
            if ([string]::IsNullOrWhiteSpace($recordTurnId)) {
                $recordTurnId = [string]$payload.turn_id
            }
            if ([string]::IsNullOrWhiteSpace($recordTurnId)) {
                $recordTurnId = [string]$payload.root_turn_id
            }
            if ($record.type -eq 'event_msg' -and $payloadType -eq 'task_started' -and
                $recordTurnId -ne $turnId) {
                break
            }
            if ((-not [string]::IsNullOrWhiteSpace($recordTurnId) -and $recordTurnId -ne $turnId) -or
                ($record.type -ne 'response_item' -and $recordTurnId -ne $turnId)) {
                continue
            }

            if ($record.type -eq 'turn_context') {
                if (-not [string]::IsNullOrWhiteSpace([string]$payload.model)) {
                    $currentModel = [string]$payload.model
                }
                continue
            }

            $recordMs = ConvertTo-UnixMilliseconds $record.timestamp

            if ($record.type -eq 'event_msg' -and $payloadType -eq 'task_started') {
                $requestStartMs = $recordMs
                continue
            }

            if ($record.type -eq 'response_item') {
                if (Is-InputItem $payload) {
                    $requestStartMs = $recordMs
                    $lastGeneratedMs = $null
                    $firstTimedItemMs = $null
                    $firstMessageMs = $null
                    $lastTimedItemMs = $null
                }
                elseif (Is-GeneratedItem $payload) {
                    $lastGeneratedMs = $recordMs
                }
                continue
            }

            if ($record.type -eq 'event_msg' -and $payloadType -eq 'item_completed') {
                $itemType = [string]$payload.item.type
                if ($itemType -in @('Reasoning', 'AgentMessage')) {
                    $startedAtMs = $payload.started_at_ms
                    $completedAtMs = $payload.completed_at_ms
                    if ($null -ne $startedAtMs -and
                        ($null -eq $firstTimedItemMs -or [int64]$startedAtMs -lt $firstTimedItemMs)) {
                        $firstTimedItemMs = [int64]$startedAtMs
                    }
                    if ($itemType -eq 'AgentMessage' -and $null -ne $startedAtMs -and
                        ($null -eq $firstMessageMs -or [int64]$startedAtMs -lt $firstMessageMs)) {
                        $firstMessageMs = [int64]$startedAtMs
                    }
                    if ($null -ne $completedAtMs -and
                        ($null -eq $lastTimedItemMs -or [int64]$completedAtMs -gt $lastTimedItemMs)) {
                        $lastTimedItemMs = [int64]$completedAtMs
                    }
                }
                continue
            }

            if ($record.type -ne 'token_usage_record') {
                continue
            }

            $usage = $payload.usage
            $outputTokens = Get-TokenCount $usage.output_tokens

            $sampleLastMs = $lastTimedItemMs
            # Tool arguments are output tokens too. Include their generation end,
            # but never a tool's execution/completion lifecycle in the decode span.
            if ($null -ne $lastGeneratedMs -and
                ($null -eq $sampleLastMs -or $lastGeneratedMs -gt $sampleLastMs)) {
                $sampleLastMs = $lastGeneratedMs
            }
            if ($null -eq $sampleLastMs) {
                $sampleLastMs = $recordMs
            }

            $effectiveTps = $null
            $decodeTps = $null
            $generationDelaySeconds = $null
            $messageDelaySeconds = $null

            if ($null -ne $outputTokens -and $null -ne $requestStartMs -and
                $null -ne $sampleLastMs -and $sampleLastMs -gt $requestStartMs) {
                $effectiveTps = $outputTokens / (($sampleLastMs - $requestStartMs) / 1000.0)
            }
            if ($null -ne $requestStartMs -and $null -ne $firstTimedItemMs -and
                $firstTimedItemMs -ge $requestStartMs -and
                $sampleLastMs -gt $firstTimedItemMs) {
                $generationDelaySeconds = ($firstTimedItemMs - $requestStartMs) / 1000.0
                if ($null -ne $outputTokens) {
                    $decodeSeconds = ($sampleLastMs - $firstTimedItemMs) / 1000.0
                    $decodeTps = $outputTokens / $decodeSeconds
                }
            }
            if ($null -ne $requestStartMs -and $null -ne $firstMessageMs -and
                $firstMessageMs -ge $requestStartMs -and
                $sampleLastMs -ge $firstMessageMs) {
                $messageDelaySeconds = ($firstMessageMs - $requestStartMs) / 1000.0
            }

            $inputTokens = Get-TokenCount $usage.input_tokens
            $cachedTokens = Get-TokenCount $usage.cached_input_tokens
            $cacheHitPercent = $null
            if ($null -ne $inputTokens -and $inputTokens -gt 0 -and $null -ne $cachedTokens) {
                $cacheHitPercent = 100.0 * $cachedTokens / $inputTokens
            }

            $latestSample = [pscustomobject]@{
                EffectiveTps = $effectiveTps
                DecodeTps = $decodeTps
                GenerationDelaySeconds = $generationDelaySeconds
                MessageDelaySeconds = $messageDelaySeconds
                InputTokens = $inputTokens
                OutputTokens = $outputTokens
                ReasoningTokens = Get-TokenCount $usage.reasoning_output_tokens
                CachedTokens = $cachedTokens
                CacheWriteTokens = Get-TokenCount $usage.cache_write_input_tokens
                CacheHitPercent = $cacheHitPercent
                Model = if ([string]::IsNullOrWhiteSpace([string]$payload.model)) { $currentModel } else { [string]$payload.model }
            }

            $requestStartMs = $recordMs
            $lastGeneratedMs = $null
            $firstTimedItemMs = $null
            $firstMessageMs = $null
            $lastTimedItemMs = $null
        }
    }
    finally {
        $reader.Dispose()
    }

    if ($null -eq $latestSample) {
        exit 0
    }

    $speedText = '⚡ Decode≈ {0} · TPS≈ {1}' -f @(
        (Format-Metric $latestSample.DecodeTps),
        (Format-Metric $latestSample.EffectiveTps)
    )
    $latencyTemplate = if ($Language -eq 'tr') { '⏱ İlk üretim≈ {0} · İlk metin≈ {1}' } else { '⏱ First generation≈ {0} · First text≈ {1}' }
    $latencyText = $latencyTemplate -f @(
        (Format-Metric $latestSample.GenerationDelaySeconds -Suffix 's'),
        (Format-Metric $latestSample.MessageDelaySeconds -Suffix 's')
    )
    $tokenText = 'Σ Token · Input {0} · Output {1} (Reasoning {2})' -f @(
        (Format-TokenCount $latestSample.InputTokens),
        (Format-TokenCount $latestSample.OutputTokens),
        (Format-TokenCount $latestSample.ReasoningTokens)
    )
    $cacheText = '↻ Cache {0} · Hit {1}' -f @(
        (Format-TokenCount $latestSample.CachedTokens),
        (Format-Metric $latestSample.CacheHitPercent -Suffix '%')
    )
    $modelText = if ([string]::IsNullOrWhiteSpace($latestSample.Model)) { 'model n/a' } else { $latestSample.Model }
    $costArguments = @($latestSample.InputTokens, $latestSample.CachedTokens, $latestSample.CacheWriteTokens, $latestSample.OutputTokens)
    $costTemplate = if ($Language -eq 'tr') { '💵 API/son çağrı · {0} · Standard≈ {1} · Fast≈ {2}' } else { '💵 API/last call · {0} · Standard≈ {1} · Fast≈ {2}' }
    $costText = $costTemplate -f @(
        $modelText,
        (Format-Usd (Get-ApiTokenCost $pricing $latestSample.Model 'standard' @costArguments)),
        (Format-Usd (Get-ApiTokenCost $pricing $latestSample.Model 'fast' @costArguments))
    )
    $metricLines = @($speedText, $latencyText, $tokenText, $cacheText)
    if (-not $HideCost) { $metricLines += $costText }
    $metricText = $metricLines -join "`n"

    # ASCII JSON survives Windows console code pages; the app restores Unicode.
    @{ systemMessage = $metricText } | ConvertTo-Json -Compress -EscapeHandling EscapeNonAscii
}
catch {
    # A metrics failure must never fail or continue the Codex turn.
    exit 0
}

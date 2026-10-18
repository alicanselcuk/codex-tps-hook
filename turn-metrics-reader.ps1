function ConvertFrom-MetricsRecord {
    param([string]$Line)
    if ($Line.Length -le 4096 -or -not $Line.Contains('"type":"response_item"')) {
        return $Line | ConvertFrom-Json -Depth 30
    }
    $document = [Text.Json.JsonDocument]::Parse($Line)
    try {
        $root = $document.RootElement
        $body = $root.GetProperty('payload')
        $payload = @{}
        foreach ($name in @('type', 'role', 'turn_id', 'root_turn_id')) {
            $element = [Text.Json.JsonElement]::new()
            if ($body.TryGetProperty($name, [ref]$element)) { $payload[$name] = $element.GetString() }
        }
        $record = @{ type = $root.GetProperty('type').GetString(); payload = [pscustomobject]$payload }
        foreach ($name in @('timestamp', 'turn_id')) {
            $element = [Text.Json.JsonElement]::new()
            if ($root.TryGetProperty($name, [ref]$element)) { $record[$name] = $element.GetString() }
        }
        return [pscustomobject]$record
    }
    finally { $document.Dispose() }
}

function Read-MetricsTranscript {
    param([string]$TranscriptPath, [string]$TurnId, [string]$Model, [string]$SessionId)

    $requestStartMs = $null
    $lastGeneratedMs = $null
    $firstTimedItemMs = $null
    $firstMessageMs = $null
    $lastTimedItemMs = $null
    $latestSample = $null
    $samples = [Collections.Generic.List[object]]::new()
    $sessionMetadata = $null
    $insideTurn = [string]::IsNullOrWhiteSpace($TurnId)
    $activeTurnId = $TurnId
    $seenResponses = [Collections.Generic.HashSet[string]]::new()
    $currentModel = $Model

    $stream = [IO.FileStream]::new(
        $transcriptPath,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite
    )
    $reader = [IO.StreamReader]::new($stream)

    try {
        while (($line = $reader.ReadLine()) -ne $null) {
            if (-not $sessionMetadata -and $line.Contains('"type":"session_meta"')) {
                try { $sessionMetadata = ($line | ConvertFrom-Json -Depth 30).payload } catch { }
                continue
            }
            if (-not $insideTurn -and
                (-not $line.Contains($TurnId) -or -not $line.Contains('"type":"task_started"'))) {
                continue
            }

            try {
                $record = ConvertFrom-MetricsRecord $line
            }
            catch {
                continue
            }

            $payload = $record.payload
            $payloadType = [string]$payload.type
            if (-not $insideTurn) {
                if ($record.type -ne 'event_msg' -or
                    $payloadType -ne 'task_started' -or
                    [string]$payload.turn_id -ne $TurnId) {
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
            if ($TurnId -and $record.type -eq 'event_msg' -and $payloadType -eq 'task_started' -and
                $recordTurnId -ne $TurnId) {
                break
            }
            if (-not $TurnId -and $record.type -eq 'event_msg' -and $payloadType -eq 'task_started') {
                $activeTurnId = $recordTurnId
            }
            $expectedTurnId = if ($TurnId) { $TurnId } else { $activeTurnId }
            if ($expectedTurnId -and ((-not [string]::IsNullOrWhiteSpace($recordTurnId) -and $recordTurnId -ne $expectedTurnId) -or
                ($record.type -ne 'response_item' -and $recordTurnId -ne $expectedTurnId))) {
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
                $activeTurnId = $recordTurnId
                $requestStartMs = $recordMs
                $lastGeneratedMs = $null
                $firstTimedItemMs = $null
                $firstMessageMs = $null
                $lastTimedItemMs = $null
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

            if ($sessionMetadata.id -and $payload.thread_id -and $payload.thread_id -ne $sessionMetadata.id) {
                continue
            }
            $responseKey = [string]$payload.response_id
            if ($responseKey -and -not $seenResponses.Add("$recordTurnId/$responseKey")) { continue }

            $usage = $payload.usage
            $outputTokens = Get-TokenCount $usage.output_tokens

            $sampleLastMs = $lastTimedItemMs
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
                IsSubagent = $null -ne $sessionMetadata.source.subagent -or [string]$sessionMetadata.source -like '*subagent*'
                Project = [string]$sessionMetadata.cwd
                SessionId = if ($payload.thread_id) { [string]$payload.thread_id } elseif ($payload.session_id) { [string]$payload.session_id } elseif ($sessionMetadata.id) { [string]$sessionMetadata.id } else { $SessionId }
                TurnId = if ($payload.turn_id) { [string]$payload.turn_id } else { $activeTurnId }
                RootTurnId = if ($payload.root_turn_id) { [string]$payload.root_turn_id } elseif (-not $sessionMetadata.source.subagent) { $activeTurnId } else { $null }
                ResponseId = [string]$payload.response_id
                RecordedAtMs = $recordMs
                ServiceTier = [string]$payload.service_tier
                EffectiveTps = $effectiveTps
                DecodeTps = $decodeTps
                EffectiveSeconds = if ($null -ne $effectiveTps -and $sampleLastMs -gt $requestStartMs) { ($sampleLastMs - $requestStartMs) / 1000.0 } else { $null }
                DecodeSeconds = if ($null -ne $decodeTps) { ($sampleLastMs - $firstTimedItemMs) / 1000.0 } else { $null }
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
            $samples.Add($latestSample)

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

    return [pscustomobject]@{ Samples = $samples.ToArray(); Metadata = $sessionMetadata }
}

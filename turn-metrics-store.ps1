function Invoke-UsageTool {
    param([string]$Script, [string[]]$Arguments, $Records)
    $process = $null
    try {
        $configuration = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'turn-metrics-store.json') -Raw | ConvertFrom-Json
        $settings = Get-Content -LiteralPath (Join-Path $configuration.project_dir 'settings.json') -Raw | ConvertFrom-Json
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $settings.python
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
        [void]$startInfo.ArgumentList.Add((Join-Path $configuration.project_dir $Script))
        foreach ($argument in $Arguments) { [void]$startInfo.ArgumentList.Add($argument) }
        $process = [Diagnostics.Process]::Start($startInfo)
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if ($null -ne $Records) {
            $process.StandardInput.WriteLine((ConvertTo-Json -InputObject $Records -Depth 8 -Compress -EscapeHandling EscapeNonAscii))
        }
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(2000)) {
            $process.Kill($true)
            return @{ Warning = '⚠ Kullanım işlemi zaman aşımına uğradı; alt ajan toplamı doğrulanamadı.' }
        }
        if ($process.ExitCode -ne 0) { return @{ Warning = '⚠ Kullanım işlemi başarısız; alt ajan toplamı doğrulanamadı.' } }
        return $stdout.GetAwaiter().GetResult() | ConvertFrom-Json -Depth 15
    }
    catch { return @{ Warning = '⚠ Kullanım veritabanına erişilemedi; alt ajan toplamı doğrulanamadı.' } }
    finally { if ($null -ne $process) { $process.Dispose() } }
}

function Get-UsageChildTranscripts {
    param([string]$SessionId)
    return Invoke-UsageTool 'child_transcripts.py' @('--session-id', $SessionId) $null
}

function Write-UsageCalls {
    param($Samples, $HookInput, $SessionMetadata, $Pricing)

    $rows = @($Samples | Where-Object { $_.SessionId -and $_.ResponseId -and $null -ne $_.RecordedAtMs })
    if (-not $rows.Count) { return $null }
    $configuration = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'turn-metrics-store.json') -Raw | ConvertFrom-Json
    $settings = Get-Content -LiteralPath (Join-Path $configuration.project_dir 'settings.json') -Raw | ConvertFrom-Json
    $database = if ($env:CODEX_USAGE_DB) { $env:CODEX_USAGE_DB } else { Join-Path $configuration.project_dir $settings.database }
    $records = @($rows | ForEach-Object {
        @{
            session_id = $_.SessionId; turn_id = $_.TurnId; response_id = $_.ResponseId; root_turn_id = $_.RootTurnId
            recorded_at_ms = $_.RecordedAtMs; model = $_.Model; project = $_.Project; is_subagent = $_.IsSubagent
            input_tokens = $_.InputTokens; output_tokens = $_.OutputTokens; reasoning_tokens = $_.ReasoningTokens
            cached_tokens = $_.CachedTokens; cache_write_tokens = $_.CacheWriteTokens
            effective_tps = $_.EffectiveTps; decode_tps = $_.DecodeTps
            effective_seconds = $_.EffectiveSeconds; decode_seconds = $_.DecodeSeconds
            generation_delay_seconds = $_.GenerationDelaySeconds; message_delay_seconds = $_.MessageDelaySeconds
            standard_cost_usd = $_.StandardCost; fast_cost_usd = $_.FastCost
            actual_cost_usd = $null; service_tier = $_.ServiceTier
            pricing_verified_on = $Pricing.verified_on; pricing_source = $Pricing.source
        }
    })
    $arguments = @('--database', $database)
    if ($HookInput.hook_event_name -eq 'Stop') {
        $current = $rows | Where-Object { $_.TurnId -eq $HookInput.turn_id } | Select-Object -Last 1
        if ($current.RootTurnId) { $arguments += @('--root-turn-id', [string]$current.RootTurnId) }
        if ($SessionMetadata.id) { $arguments += @('--session-id', [string]$SessionMetadata.id) }
    }
    return Invoke-UsageTool 'store.py' $arguments $records
}

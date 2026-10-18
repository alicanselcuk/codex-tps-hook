#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$hookPath = Join-Path $PSScriptRoot 'turn-metrics.ps1'
$pwshPath = (Get-Process -Id $PID).Path
$turnId = 'metrics-test-turn'
$epoch = [DateTimeOffset]::Parse('2026-10-01T00:00:00Z')
$checks = 0

function New-Record {
    param([string]$Type, [int64]$Milliseconds, [hashtable]$Payload)
    return @{
        timestamp = $epoch.AddMilliseconds($Milliseconds).ToString('o')
        type = $Type
        payload = $Payload
    }
}

function New-Start {
    param([string]$Id = $turnId)
    New-Record 'event_msg' 0 @{ type = 'task_started'; turn_id = $Id }
}

function New-Context {
    param([string]$Model)
    New-Record 'turn_context' 0 @{ turn_id = $turnId; model = $Model }
}

function New-Input {
    param([int64]$Milliseconds = 0, [string]$Type = 'message')
    New-Record 'response_item' $Milliseconds @{ type = $Type; role = 'user' }
}

function New-TimedItem {
    param([string]$Type, [int64]$Start, [int64]$End)
    New-Record 'event_msg' $End @{
        type = 'item_completed'; turn_id = $turnId; item = @{ type = $Type }
        started_at_ms = $epoch.ToUnixTimeMilliseconds() + $Start
        completed_at_ms = $epoch.ToUnixTimeMilliseconds() + $End
    }
}

function New-Generated {
    param([int64]$Milliseconds, [string]$Type = 'message')
    New-Record 'response_item' $Milliseconds @{ type = $Type; role = 'assistant' }
}

function New-Usage {
    param([int64]$Milliseconds, [hashtable]$Usage)
    New-Record 'token_usage_record' $Milliseconds @{ turn_id = $turnId; usage = $Usage }
}

function Invoke-Metrics {
    param([object[]]$Records, [string]$Event = 'Stop', [string]$RawInput, [int]$ConsoleCodePage, [string]$Model, [string]$Language = 'tr', [switch]$HideCost)

    # Each invocation owns one temporary fixture, without touching live sessions.
    $sessionId = $env:CODEX_THREAD_ID
    $prefix = if ($sessionId) { $sessionId.Substring(0, 8) } else { 'metrics' }
    $fixturePath = Join-Path ([IO.Path]::GetTempPath()) "$prefix-turn-metrics-$([Guid]::NewGuid()).jsonl"
    try {
        $lines = @($Records | ForEach-Object { ConvertTo-Json -InputObject $_ -Depth 20 -Compress })
        [IO.File]::WriteAllLines($fixturePath, [string[]]$lines)
        $stdin = if ($PSBoundParameters.ContainsKey('RawInput')) { $RawInput } else {
            @{ hook_event_name = $Event; turn_id = $turnId; transcript_path = $fixturePath; model = $Model } |
                ConvertTo-Json -Compress
        }
        if ($ConsoleCodePage -gt 0) {
            # Capture the pipe as UTF-8, as the app does, with a legacy child console.
            $startInfo = [Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $pwshPath
            $startInfo.UseShellExecute = $false
            $startInfo.RedirectStandardInput = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false, $true)
            $startInfo.Environment['CODEX_METRICS_TEST_SCRIPT'] = $hookPath
            $command = "[Console]::OutputEncoding = [Text.Encoding]::GetEncoding($ConsoleCodePage); & `$env:CODEX_METRICS_TEST_SCRIPT -Language $Language"
            if ($HideCost) { $command += ' -HideCost' }
            foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $command)) {
                [void]$startInfo.ArgumentList.Add($argument)
            }
            $process = [Diagnostics.Process]::Start($startInfo)
            try {
                $process.StandardInput.WriteLine($stdin)
                $process.StandardInput.Close()
                $output = $process.StandardOutput.ReadToEnd()
                $stderr = $process.StandardError.ReadToEnd()
                $process.WaitForExit()
                if ($process.ExitCode -ne 0 -or $stderr) { throw "Hook process failed: $stderr" }
                if ($output -match '[^\x00-\x7F]') { throw 'Hook JSON transport must contain only ASCII' }
            }
            finally { $process.Dispose() }
        }
        else {
            $output = $stdin | & $pwshPath -NoLogo -NoProfile -NonInteractive -File $hookPath -Language $Language -HideCost:$HideCost
            if ($LASTEXITCODE -ne 0) { throw "Hook exited with $LASTEXITCODE" }
        }
        if ($output) {
            return (($output -join "`n") | ConvertFrom-Json).systemMessage
        }
        return ''
    }
    finally {
        if (Test-Path -LiteralPath $fixturePath) { Remove-Item -LiteralPath $fixturePath }
    }
}

function Assert-Contains {
    param([string]$Actual, [string]$Expected)
    if (-not $Actual.Contains($Expected)) { throw "Expected '$Expected', got '$Actual'" }
    $script:checks++
}

$plain = @(
    New-Start
    New-Input
    New-TimedItem 'Reasoning' 2000 3000
    New-Generated 3000 'reasoning'
    New-TimedItem 'AgentMessage' 3100 7000
    New-Generated 7000
    New-Usage 7010 @{ input_tokens = 1000; output_tokens = 250; reasoning_output_tokens = 100; cached_input_tokens = 800 }
)
$text = Invoke-Metrics $plain
Assert-Contains $text '⚡ Decode≈ 50.0 · TPS≈ 35.7'
Assert-Contains $text '⏱ İlk üretim≈ 2.0s · İlk metin≈ 3.1s'
Assert-Contains $text "Σ Token · Input 1.000 · Output 250 (Reasoning 100)`n↻ Cache 800 · Hit 80.0%"
Assert-Contains $text '↻ Genel toplam · Cache 800 · Hit 80.0%'
Assert-Contains $text '📚 Sohbetin tamamı · 1 istek · 1 çağrı'
Assert-Contains $text '↻ Sohbet toplamı · Cache 800 · Hit 80.0%'

$largeInput = New-Input
$largeInput.payload.content = 'x' * 10000
$largeCall = $plain.Clone()
$largeCall[1] = $largeInput
$text = Invoke-Metrics $largeCall
Assert-Contains $text 'Decode≈ 50.0 · TPS≈ 35.7'
Assert-Contains $text 'Σ Sohbet toplamı · Input 1.000 · Output 250 (Reasoning 100)'

# All token fields use dot grouping, including multiple thousands groups.
$grouped = $plain[0..5] + @(New-Usage 7010 @{
    input_tokens = 1234567; output_tokens = 12345; reasoning_output_tokens = 2345; cached_input_tokens = 1000000
})
$text = Invoke-Metrics $grouped
Assert-Contains $text "Σ Token · Input 1.234.567 · Output 12.345 (Reasoning 2.345)`n↻ Cache 1.000.000"

# Pricing uses four disjoint token classes and includes reasoning only in output.
$pricedUsage = @{
    input_tokens = 100000; cached_input_tokens = 98000; cache_write_input_tokens = 1000
    output_tokens = 2000; reasoning_output_tokens = 1500
}
$priced = $plain[0..5] + @(New-Usage 7010 $pricedUsage)
$text = Invoke-Metrics $priced -Model 'gpt-6.1-sol'
Assert-Contains $text '💵 API/istek · gpt-6.1-sol · Standard≈ $0.0343 · Fast≈ $0.0686'

# Actual turn metadata wins over a stale active/default model.
$text = Invoke-Metrics (@($plain[0], (New-Context 'gpt-6-sol')) + $priced[1..6]) -Model 'gpt-6.1-sol'
Assert-Contains $text 'gpt-6-sol · Standard≈ $0.0441 · Fast≈ $0.0882'

# A recorded response model is more specific than the turn model.
$responseUsage = New-Usage 7010 $pricedUsage
$responseUsage.payload.model = 'gpt-6-luna'
$text = Invoke-Metrics (@($plain[0], (New-Context 'gpt-6-sol')) + $plain[1..5] + @($responseUsage))
Assert-Contains $text 'gpt-6-luna · Standard≈ $0.0022 · Fast≈ $0.0044'

# Long context pricing applies to the entire response only above 272K input.
foreach ($case in @(
    @{ Input = 272000; Expected = 'Standard≈ $0.5540 · Fast≈ $1.1080' },
    @{ Input = 272001; Expected = 'Standard≈ $1.1030 · Fast≈ $2.2060' }
)) {
    $records = $plain[0..5] + @(New-Usage 7010 @{
        input_tokens = $case.Input; cached_input_tokens = 0; cache_write_input_tokens = 0; output_tokens = 1000
    })
    $text = Invoke-Metrics $records -Model 'gpt-6.1-sol'
    Assert-Contains $text $case.Expected
}

# gpt-5.5 Fast is 2.5x Standard for short context and unpriced for long context.
foreach ($case in @(
    @{ Input = 1000; Expected = 'Standard≈ $0.0089 · Fast≈ $0.0223' },
    @{ Input = 272001; Expected = 'Standard≈ $2.7241 · Fast≈ n/a' }
)) {
    $records = $plain[0..5] + @(New-Usage 7010 @{
        input_tokens = $case.Input; cached_input_tokens = 800; output_tokens = 250; reasoning_output_tokens = 100
    })
    $text = Invoke-Metrics $records -Model 'gpt-5.5'
    Assert-Contains $text $case.Expected
}

# Unknown models and incomplete usage cannot yield an invented financial value.
$text = Invoke-Metrics $priced -Model 'unknown-model'
Assert-Contains $text 'unknown-model · Standard≈ n/a · Fast≈ n/a'
$text = Invoke-Metrics $plain -Model 'gpt-6.1-sol'
Assert-Contains $text 'gpt-6.1-sol · Standard≈ n/a · Fast≈ n/a'
$text = Invoke-Metrics $priced
Assert-Contains $text 'model n/a · Standard≈ n/a · Fast≈ n/a'

# Cache reads/writes cannot exceed total input; timing metrics still remain.
$invalidCache = $plain[0..5] + @(New-Usage 7010 @{
    input_tokens = 1000; cached_input_tokens = 800; cache_write_input_tokens = 500; output_tokens = 250
})
$text = Invoke-Metrics $invalidCache -Model 'gpt-6.1-sol'
Assert-Contains $text 'gpt-6.1-sol · Standard≈ n/a · Fast≈ n/a'
Assert-Contains $text 'Decode≈ 50.0 · TPS≈ 35.7'

# Cost includes every call in the selected request.
$lastPriced = @(
    New-Input 20000 'function_call_output'
    New-TimedItem 'AgentMessage' 21000 22000
    New-Generated 22000
    New-Usage 22010 @{ input_tokens = 500; cached_input_tokens = 0; cache_write_input_tokens = 0; output_tokens = 50 }
)
$text = Invoke-Metrics ($priced + $lastPriced) -Model 'gpt-6.1-sol'
Assert-Contains $text 'gpt-6.1-sol · Standard≈ $0.0358 · Fast≈ $0.0716'

$mixedCall = $lastPriced.Clone()
$mixedUsage = New-Usage 22010 @{ input_tokens = 500; cached_input_tokens = 0; cache_write_input_tokens = 0; output_tokens = 50 }
$mixedUsage.payload.model = 'gpt-6-luna'
$mixedCall[3] = $mixedUsage
$text = Invoke-Metrics ($priced + $mixedCall) -Model 'gpt-6.1-sol'
Assert-Contains $text 'gpt-6-luna, gpt-6.1-sol · Standard≈ $0.0344 · Fast≈ $0.0688'

$unknownUsage = New-Usage 22010 @{ input_tokens = 500; cached_input_tokens = 0; output_tokens = 50 }
$unknownUsage.payload.model = 'unknown-model'
$text = Invoke-Metrics ($priced + $lastPriced[0..2] + @($unknownUsage)) -Model 'gpt-6.1-sol'
Assert-Contains $text 'Standard≈ $0.0343 + ? · Fast≈ $0.0686 + ?'

# An unavailable pricing catalogue must not suppress the existing metrics.
$savedHookPath = $hookPath
$isolatedPrefix = if ($env:CODEX_THREAD_ID) { $env:CODEX_THREAD_ID.Substring(0, 8) } else { 'metrics' }
$isolatedDir = Join-Path ([IO.Path]::GetTempPath()) "$isolatedPrefix-metrics-pricing-$([Guid]::NewGuid())"
[void][IO.Directory]::CreateDirectory($isolatedDir)
$hookPath = Join-Path $isolatedDir 'turn-metrics.ps1'
$isolatedPricingPath = Join-Path $isolatedDir 'turn-metrics-pricing.json'
try {
    [IO.File]::Copy($savedHookPath, $hookPath)
    foreach ($dependency in @('turn-metrics-reader.ps1', 'turn-metrics-summary.ps1', 'turn-metrics-display.ps1')) {
        [IO.File]::Copy((Join-Path $PSScriptRoot $dependency), (Join-Path $isolatedDir $dependency))
    }
    foreach ($state in @('missing', 'malformed')) {
        if ($state -eq 'malformed') { [IO.File]::WriteAllText($isolatedPricingPath, '{broken') }
        $text = Invoke-Metrics $priced -Model 'gpt-6.1-sol'
        Assert-Contains $text 'Input 100.000 · Output 2.000 (Reasoning 1.500)'
        Assert-Contains $text 'gpt-6.1-sol · Standard≈ n/a · Fast≈ n/a'
    }
}
finally {
    Remove-Item -LiteralPath $hookPath
    foreach ($dependency in @('turn-metrics-reader.ps1', 'turn-metrics-summary.ps1', 'turn-metrics-display.ps1')) {
        Remove-Item -LiteralPath (Join-Path $isolatedDir $dependency)
    }
    if (Test-Path -LiteralPath $isolatedPricingPath) { Remove-Item -LiteralPath $isolatedPricingPath }
    Remove-Item -LiteralPath $isolatedDir
    $hookPath = $savedHookPath
}

# Regression: Turkish OEM/ANSI stdout decoded by the app must retain all glyphs.
foreach ($codePage in @(857, 1254)) {
    $text = Invoke-Metrics $plain -ConsoleCodePage $codePage
    Assert-Contains $text '⚡ Decode≈ 50.0 · TPS≈ 35.7'
    Assert-Contains $text '⏱ İlk üretim≈ 2.0s · İlk metin≈ 3.1s'
    Assert-Contains $text '💵 API/istek · model n/a'
}

# Regression: reasoning finishes before tool argument generation does.
# A later tool execution lifecycle must not lengthen the generation window.
$tool = @(
    New-Start
    New-Input 16280 'custom_tool_call_output'
    New-TimedItem 'Reasoning' 17893 18335
    New-Generated 18335 'reasoning'
    New-Generated 19274 'custom_tool_call'
    New-TimedItem 'McpToolCall' 19274 29000
    New-Usage 29010 @{ input_tokens = 44504; output_tokens = 88; reasoning_output_tokens = 21; cached_input_tokens = 42752 }
)
$text = Invoke-Metrics $tool
Assert-Contains $text 'Decode≈ 63.7 · TPS≈ 29.4'
Assert-Contains $text 'İlk üretim≈ 1.6s · İlk metin≈ n/a'

# Completion-only transcript timestamps do not identify the first token.
$untimed = @(
    New-Start
    New-Input
    New-Generated 3000 'reasoning'
    New-Generated 7000
    New-Usage 7010 @{ output_tokens = 250 }
)
$text = Invoke-Metrics $untimed
Assert-Contains $text "Decode≈ n/a (0/1 çağrı) · TPS≈ 35.7`n⏱ İlk üretim≈ n/a · İlk metin≈ n/a"
Assert-Contains $text "Input n/a · Output 250 (Reasoning n/a)`n↻ Cache n/a · Hit n/a"

# Request totals use paired output/duration sums, not the final call.
$secondCall = @(
    New-Input 20000 'function_call_output'
    New-TimedItem 'AgentMessage' 21000 22000
    New-Generated 22000
    New-Usage 22010 @{ input_tokens = 500; output_tokens = 50; reasoning_output_tokens = 0; cached_input_tokens = 0 }
)
$text = Invoke-Metrics ($plain + $secondCall)
Assert-Contains $text "Decode≈ 50.0 · TPS≈ 33.3`n⏱ İlk üretim≈ 1.5s · İlk metin≈ 2.0s"
Assert-Contains $text "Input 1.500 · Output 300 (Reasoning 100)`n↻ Cache 800 · Hit 53.3%"

$zeroInput = @(
    New-Start
    New-Input
    New-TimedItem 'AgentMessage' 1000 2000
    New-Usage 2010 @{ input_tokens = 0; output_tokens = 50; reasoning_output_tokens = 0; cached_input_tokens = 0 }
)
$text = Invoke-Metrics $zeroInput
Assert-Contains $text "Input 0 · Output 50 (Reasoning 0)`n↻ Cache 0 · Hit n/a"

# Missing measurements retain known totals and show incomplete coverage.
$zeroOutput = @(
    New-Input 20000 'function_call_output'
    New-Usage 22000 @{ input_tokens = 500; output_tokens = 0; reasoning_output_tokens = 0; cached_input_tokens = 100 }
)
$text = Invoke-Metrics ($plain + $zeroOutput)
Assert-Contains $text "Decode≈ 50.0 (1/2 çağrı) · TPS≈ 27.8`n⏱ İlk üretim≈ 2.0s · İlk metin≈ 3.1s"
Assert-Contains $text "Input 1.500 · Output 250 (Reasoning 100)`n↻ Cache 900 · Hit 60.0%"

$missingOutput = @(
    New-Input 20000 'function_call_output'
    New-Usage 22000 @{ input_tokens = 600; cached_input_tokens = 300 }
)
$text = Invoke-Metrics ($plain + $missingOutput)
Assert-Contains $text 'Decode≈ 50.0 (1/2 çağrı) · TPS≈ 35.7 (1/2 çağrı)'
Assert-Contains $text "Input 1.600 · Output 250 + ? (Reasoning 100 + ?)`n↻ Cache 1.100 · Hit 68.8%"

$noRequestTimestamp = New-Start
$noRequestTimestamp.timestamp = $null
$text = Invoke-Metrics @(
    $noRequestTimestamp
    New-Usage 22000 @{ input_tokens = 600; output_tokens = 50; cached_input_tokens = 300 }
)
Assert-Contains $text 'Decode≈ n/a (0/1 çağrı) · TPS≈ n/a (0/1 çağrı)'
Assert-Contains $text "Input 600 · Output 50 (Reasoning n/a)`n↻ Cache 300 · Hit 50.0%"

# Historic replay must stop at the next turn, including untagged response items.
$nextTurn = @(
    New-Start 'different-turn'
    New-Generated 99000
    New-Usage 99010 @{ input_tokens = 123; output_tokens = 999 }
)
$text = Invoke-Metrics ($plain + $nextTurn)
Assert-Contains $text 'Decode≈ 50.0 · TPS≈ 35.7'
Assert-Contains $text 'Output 250 (Reasoning 100)'

# Explicitly foreign response items cannot affect the selected turn.
$foreign = New-Generated 99000
$foreign.payload.turn_id = 'different-turn'
$text = Invoke-Metrics ($plain[0..5] + @($foreign) + @($plain[6]))
Assert-Contains $text 'Decode≈ 50.0 · TPS≈ 35.7'

# Malformed/irrelevant hook input must remain fail-silent and exit successfully.
foreach ($text in @(
    (Invoke-Metrics $plain -Event 'SessionStart'),
    (Invoke-Metrics $plain -RawInput '{broken'),
    (Invoke-Metrics $plain -RawInput '{}'),
    (Invoke-Metrics @())
)) {
    if ($text -ne '') { throw "Expected no hook output, got '$text'" }
    $checks++
}

$text = Invoke-Metrics $plain -Language 'en'
Assert-Contains $text 'Main session / this request'
Assert-Contains $text 'First generation≈ 2.0s · First text≈ 3.1s'
Assert-Contains $text 'Input 1,000 · Output 250'
Assert-Contains $text 'Entire session'
$text = Invoke-Metrics $priced -Language 'en' -HideCost
Assert-Contains $text 'First generation'
if ($text.Contains('💵') -or $text.Contains('Standard≈') -or $text.Contains('Fast≈')) { throw 'HideCost leaked a cost estimate' }
$checks++
Write-Output "$checks assertions passed."

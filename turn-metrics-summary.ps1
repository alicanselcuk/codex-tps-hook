function Get-MetricsSum {
    param($Samples, [string]$Property)
    $known = @($Samples | Where-Object { $null -ne $_.$Property })
    $value = $null
    if ($known.Count) {
        $value = [decimal]0
        foreach ($sample in $known) { $value += [decimal]$sample.$Property }
    }
    return [pscustomobject]@{ Value = $value; Known = $known.Count; Count = $Samples.Count }
}

function Format-MetricsSum {
    param($Samples, [string]$Property, [switch]$Money)
    $total = Get-MetricsSum $Samples $Property
    $formatted = if ($Money) { Format-Usd $total.Value } else { Format-TokenCount $total.Value }
    if ($total.Known -gt 0 -and $total.Known -lt $total.Count) { $formatted += ' + ?' }
    return $formatted
}

function Get-WeightedSpeed {
    param($Samples, [string]$Duration)
    $measured = @($Samples | Where-Object { $null -ne $_.OutputTokens -and $_.$Duration -gt 0 })
    $value = $null
    if ($measured.Count) {
        $value = ($measured | Measure-Object OutputTokens -Sum).Sum / ($measured | Measure-Object $Duration -Sum).Sum
    }
    $formatted = Format-Metric $value
    if ($measured.Count -lt $Samples.Count) { $formatted += ' ({0}/{1} çağrı)' -f $measured.Count, $Samples.Count }
    return $formatted
}

function Format-MetricsCache {
    param($Samples, [string]$Label = '↻ Cache')
    $cachePairs = @($Samples | Where-Object { $null -ne $_.InputTokens -and $null -ne $_.CachedTokens })
    $cacheInput = ($cachePairs | Measure-Object InputTokens -Sum).Sum
    $cacheHit = if ($cacheInput -gt 0) { 100.0 * ($cachePairs | Measure-Object CachedTokens -Sum).Sum / $cacheInput } else { $null }
    $cacheCoverage = if ($cachePairs.Count -lt $Samples.Count) { ' ({0}/{1} çağrı)' -f $cachePairs.Count, $Samples.Count } else { '' }
    return '{0} {1} · Hit {2}{3}' -f $Label, (Format-MetricsSum $Samples 'CachedTokens'), (Format-Metric $cacheHit -Suffix '%'), $cacheCoverage
}

function Format-MetricsGroup {
    param($Samples, [string]$Title)
    $models = @($Samples | ForEach-Object { if ($_.Model) { $_.Model } else { 'model n/a' } } | Sort-Object -Unique) -join ', '
    $delays = @($Samples | Where-Object { $null -ne $_.GenerationDelaySeconds })
    $messages = @($Samples | Where-Object { $null -ne $_.MessageDelaySeconds })
    $generation = if ($delays.Count) { ($delays | Measure-Object GenerationDelaySeconds -Average).Average } else { $null }
    $message = if ($messages.Count) { ($messages | Measure-Object MessageDelaySeconds -Average).Average } else { $null }
    return @(
        ('{0} · {1} çağrı · {2}' -f $Title, $Samples.Count, $models)
        ('⚡ Decode≈ {0} · TPS≈ {1}' -f (Get-WeightedSpeed $Samples 'DecodeSeconds'), (Get-WeightedSpeed $Samples 'EffectiveSeconds'))
        ('⏱ İlk üretim≈ {0} · İlk metin≈ {1} (çağrı ortalaması)' -f (Format-Metric $generation -Suffix 's'), (Format-Metric $message -Suffix 's'))
        ('Σ Token · Input {0} · Output {1} (Reasoning {2})' -f (Format-MetricsSum $Samples 'InputTokens'), (Format-MetricsSum $Samples 'OutputTokens'), (Format-MetricsSum $Samples 'ReasoningTokens'))
        (Format-MetricsCache $Samples)
        ('💵 API/istek · {0} · Standard≈ {1} · Fast≈ {2}' -f $models, (Format-MetricsSum $Samples 'StandardCost' -Money), (Format-MetricsSum $Samples 'FastCost' -Money))
    ) -join "`n"
}

function Format-MetricsSession {
    param($Samples)
    $main = @($Samples | Where-Object { -not $_.IsSubagent })
    $children = @($Samples | Where-Object { $_.IsSubagent })
    $turnCount = @($main.TurnId | Sort-Object -Unique).Count
    $lines = @('📚 Sohbetin tamamı · {0} istek · {1} çağrı' -f $turnCount, $Samples.Count)
    foreach ($group in @(@{ Title = '👤 Ana oturum'; Samples = $main }, @{ Title = '🤖 Alt ajanlar'; Samples = $children })) {
        $calls = @($group.Samples)
        if (-not $calls.Count) { continue }
        $lines += '{0} · {1} çağrı · Decode≈ {2} · TPS≈ {3} · Standard≈ {4} · Fast≈ {5}' -f @(
            $group.Title, $calls.Count, (Get-WeightedSpeed $calls 'DecodeSeconds'), (Get-WeightedSpeed $calls 'EffectiveSeconds'),
            (Format-MetricsSum $calls 'StandardCost' -Money), (Format-MetricsSum $calls 'FastCost' -Money)
        )
    }
    $lines += 'Σ Sohbet toplamı · Input {0} · Output {1} (Reasoning {2})' -f @(
        (Format-MetricsSum $Samples 'InputTokens'), (Format-MetricsSum $Samples 'OutputTokens'), (Format-MetricsSum $Samples 'ReasoningTokens')
    )
    $lines += Format-MetricsCache $Samples '↻ Sohbet toplamı · Cache'
    $lines += '💵 Sohbet toplamı · Standard≈ {0} · Fast≈ {1}' -f (Format-MetricsSum $Samples 'StandardCost' -Money), (Format-MetricsSum $Samples 'FastCost' -Money)
    return $lines -join "`n"
}

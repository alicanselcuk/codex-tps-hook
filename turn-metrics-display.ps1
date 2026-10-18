function Convert-MetricsDisplay {
    param([string]$Text, [string]$Language, [bool]$HideCost)
    if ($HideCost) {
        $Text = (($Text -split "`n" | Where-Object { -not $_.StartsWith('💵') } |
            ForEach-Object { $_ -replace ' · Standard≈ .*$', '' }) -join "`n")
    }
    if ($Language -ne 'en') { return $Text }
    $labels = [ordered]@{
        '⚠ Kullanım işlemi zaman aşımına uğradı; alt ajan toplamı doğrulanamadı.' = '⚠ Usage operation timed out; subagent totals could not be verified.'
        '⚠ Kullanım işlemi başarısız; alt ajan toplamı doğrulanamadı.' = '⚠ Usage operation failed; subagent totals could not be verified.'
        '⚠ Kullanım veritabanına erişilemedi; alt ajan toplamı doğrulanamadı.' = '⚠ Usage database unavailable; subagent totals could not be verified.'
        '⚠ Kullanım DB kaydı başlatılamadı; alt ajan toplamı doğrulanamadı.' = '⚠ Usage storage could not start; subagent totals could not be verified.'
        '⚠ Bazı alt ajan kayıtları okunamadı; toplam kısmi olabilir.' = '⚠ Some subagent transcripts could not be read; totals may be partial.'
        'Alt ajan oturum indeksi okunamadı; yalnız arşivdeki alt ajan çağrıları dahil.' = 'Subagent session index unavailable; only archived subagent calls are included.'
        'Sohbetin tamamı' = 'Entire session'
        'Sohbet toplamı' = 'Session total'
        'Ana oturum' = 'Main session'
        'Alt ajanlar' = 'Subagents'
        'bu istek' = 'this request'
        'Genel toplam' = 'Request total'
        'API/istek' = 'API/request'
        'İlk üretim' = 'First generation'
        'İlk metin' = 'First text'
        'çağrı ortalaması' = 'call average'
        'çağrı' = 'calls'
        'istek' = 'requests'
        ' ajan' = ' agents'
    }
    foreach ($entry in $labels.GetEnumerator()) { $Text = $Text.Replace($entry.Key, $entry.Value) }
    return $Text -replace '\b1 calls\b', '1 call' -replace '\b1 requests\b', '1 request' -replace '\b1 agents\b', '1 agent'
}

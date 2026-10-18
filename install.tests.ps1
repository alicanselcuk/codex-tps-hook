#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$installer = Join-Path $PSScriptRoot 'install.ps1'
$pwshPath = (Get-Process -Id $PID).Path
$prefix = if ($env:CODEX_THREAD_ID) { $env:CODEX_THREAD_ID.Substring(0, 8) } else { [Guid]::NewGuid().ToString('N').Substring(0, 8) }
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "$prefix-codex-tps-tests-$([Guid]::NewGuid())"
$testHome = Join-Path $fixtureRoot "home with ' quotes `$dollar ``backtick %TEMP%"
$configPath = Join-Path $testHome 'hooks.json'
$checks = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}

function Invoke-Installer {
    param([string[]]$Arguments)
    $output = & $pwshPath -NoLogo -NoProfile -NonInteractive -File $installer -CodexHome $testHome @Arguments 2>&1
    return @{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
}

try {
    $preview = Invoke-Installer @('-DryRun')
    Assert-True ($preview.ExitCode -eq 0) "Dry run failed: $($preview.Output)"
    Assert-True (-not (Test-Path -LiteralPath $testHome)) 'Dry run wrote to disk.'

    [void][IO.Directory]::CreateDirectory($testHome)
    $original = [ordered]@{
        description = 'Unrelated user metadata'
        hooks = [ordered]@{
            SessionStart = @(@{ matcher = 'startup'; hooks = @(@{ type = 'command'; command = 'echo startup' }) })
            SubagentStop = @(@{ hooks = @(@{ type = 'command'; command = 'echo keep-child' }) })
            Stop = @(@{ matcher = ''; hooks = @(@{ type = 'command'; command = 'echo keep-me'; timeout = 17 }) })
        }
    }
    $originalJson = ConvertTo-Json -InputObject $original -Depth 20
    [IO.File]::WriteAllText($configPath, $originalJson)
    $result = Invoke-Installer @('-Language', 'tr', '-HideCost')
    Assert-True ($result.ExitCode -eq 0) "Install failed: $($result.Output)"
    $installed = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -AsHashtable
    Assert-True ($installed.description -eq $original.description) 'Top-level metadata changed.'
    Assert-True ($installed.hooks.SessionStart[0].hooks[0].command -eq 'echo startup') 'Other events changed.'
    Assert-True ($installed.hooks.Stop[0].hooks[0].command -eq 'echo keep-me' -and $installed.hooks.Stop[0].hooks[0].timeout -eq 17) 'Other Stop hook changed.'
    Assert-True ($installed.hooks.Stop.Count -eq 2) 'Expected exactly one added Stop group.'
    Assert-True ($installed.hooks.SubagentStop.Count -eq 2) 'Expected exactly one added SubagentStop group.'
    Assert-True ($installed.hooks.Stop[1].hooks[0].timeout -eq 30 -and $installed.hooks.SubagentStop[1].hooks[0].timeout -eq 5) 'Hook time budgets changed.'
    $handler = $installed.hooks.Stop[1].hooks[0]
    $windowsInvocation = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(($handler.commandWindows -split ' ')[-1]))
    Assert-True ($windowsInvocation.Contains('-Language tr -HideCost')) 'Install options were not applied.'
    $backups = @(Get-ChildItem -LiteralPath (Join-Path $testHome 'backups/codex-tps-hook') -Directory)
    Assert-True ($backups.Count -eq 1) 'Missing first backup.'
    Assert-True ([IO.File]::ReadAllText((Join-Path $backups[0].FullName 'hooks.json')) -eq $originalJson) 'Backup differs from original.'

    # Execute a real Stop payload through the generated shell command so both
    # path quoting and stdin/JSON transport are checked.
    $transcriptPath = Join-Path $fixtureRoot 'stop-fixture.jsonl'
    [IO.File]::WriteAllLines($transcriptPath, [string[]]@(
        '{"timestamp":"2026-10-13T00:00:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"installer-test"}}',
        '{"timestamp":"2026-10-13T00:00:01Z","type":"token_usage_record","payload":{"turn_id":"installer-test","usage":{"output_tokens":1}}}'
    ))
    $stopInput = @{ hook_event_name = 'Stop'; turn_id = 'installer-test'; transcript_path = $transcriptPath } | ConvertTo-Json -Compress
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    if ($IsWindows) {
        $startInfo.FileName = $env:ComSpec
        # cmd.exe parses its command tail itself; ArgumentList's C-style quote
        # escaping would turn a quoted script path into a literal \" argument.
        $startInfo.Arguments = '/d /s /c "' + $handler.commandWindows + '"'
    } else {
        $startInfo.FileName = '/bin/sh'
        foreach ($argument in @('-c', $handler.command)) { [void]$startInfo.ArgumentList.Add($argument) }
    }
    $process = [Diagnostics.Process]::Start($startInfo)
    try {
        $process.StandardInput.WriteLine($stopInput)
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        Assert-True ($process.ExitCode -eq 0 -and -not $stderr -and $stdout) "Generated hook command failed: $stderr"
        $message = ($stdout | ConvertFrom-Json).systemMessage
        Assert-True ($message.Contains('Output 1') -and $message.Contains('İlk üretim') -and -not $message.Contains('💵')) 'Generated command lost its Stop input or runtime options.'
    } finally { $process.Dispose() }

    $installedScript = Join-Path $testHome 'hooks/codex-tps-hook/turn-metrics.ps1'
    [IO.File]::AppendAllText($installedScript, "`n# User customization`n")
    $result = Invoke-Installer @('-Language', 'en')
    Assert-True ($result.ExitCode -eq 0) "Reinstall failed: $($result.Output)"
    $installed = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -AsHashtable
    Assert-True ($installed.hooks.Stop.Count -eq 2) 'Reinstall duplicated the registration.'
    Assert-True ($installed.hooks.SubagentStop.Count -eq 2) 'Reinstall duplicated the subagent registration.'
    Assert-True ($installed.hooks.Stop[1].hooks[0].command.Contains('-Language en')) 'Reinstall did not update language.'
    $backups = @(Get-ChildItem -LiteralPath (Join-Path $testHome 'backups/codex-tps-hook') -Directory)
    $savedScripts = @($backups | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'turn-metrics.ps1') })
    Assert-True ($savedScripts.Count -eq 1 -and [IO.File]::ReadAllText((Join-Path $savedScripts[0].FullName 'turn-metrics.ps1')).Contains('# User customization')) 'Reinstall lost the customized script backup.'

    # Test removal when another hook shares the same matcher group.
    $installed.hooks.Stop[0].hooks += $installed.hooks.Stop[1].hooks
    $installed.hooks.Stop = @($installed.hooks.Stop[0])
    [IO.File]::WriteAllText($configPath, (ConvertTo-Json -InputObject $installed -Depth 20))
    $result = Invoke-Installer @('-Action', 'Uninstall')
    Assert-True ($result.ExitCode -eq 0) "Uninstall failed: $($result.Output)"
    $uninstalledJson = [IO.File]::ReadAllText($configPath)
    $uninstalled = $uninstalledJson | ConvertFrom-Json -AsHashtable
    Assert-True ($uninstalled.hooks.Stop.Count -eq 1 -and $uninstalled.hooks.Stop[0].hooks.Count -eq 1) 'Uninstall changed unrelated Stop hooks.'
    Assert-True ($uninstalled.hooks.Stop[0].hooks[0].command -eq 'echo keep-me') 'Uninstall removed another hook.'
    Assert-True ($uninstalled.hooks.SubagentStop.Count -eq 1 -and $uninstalled.hooks.SubagentStop[0].hooks[0].command -eq 'echo keep-child') 'Uninstall changed another subagent hook.'
    Assert-True (Test-Path -LiteralPath $installedScript) 'Uninstall deleted user-customizable scripts.'
    $result = Invoke-Installer @('-Action', 'Uninstall')
    Assert-True ($result.ExitCode -eq 0 -and [IO.File]::ReadAllText($configPath) -eq $uninstalledJson) 'Repeated uninstall changed configuration.'

    foreach ($invalidJson in @('{broken', '[]', '[{"hooks":{}}]', '{"hooks":[]}', '{"hooks":{"Stop":{}}}', '{"hooks":{"Stop":[{"hooks":{}}]}}', '{"hooks":{"SubagentStop":{}}}', '{"hooks":{"SubagentStop":[{"hooks":{}}]}}')) {
        [IO.File]::WriteAllText($configPath, $invalidJson)
        $result = Invoke-Installer @()
        Assert-True ($result.ExitCode -ne 0) "Invalid config was accepted: $invalidJson"
        Assert-True ([IO.File]::ReadAllText($configPath) -eq $invalidJson) 'Invalid configuration was overwritten.'
    }
    Write-Output "$checks installer assertions passed."
} finally {
    # Only remove the exact temporary root created by this test invocation.
    $resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot)
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (-not $resolvedFixture.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolvedFixture) -notlike "$prefix-codex-tps-tests-*") {
        throw 'Refusing cleanup outside this test fixture.'
    }
    if (Test-Path -LiteralPath $resolvedFixture) { Remove-Item -LiteralPath $resolvedFixture -Recurse -Force }
}

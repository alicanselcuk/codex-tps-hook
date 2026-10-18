#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Install', 'Uninstall')][string]$Action = 'Install',
    [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex' }),
    [ValidateSet('en', 'tr')][string]$Language = 'en',
    [switch]$HideCost,
    [string]$PythonPath,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$CodexHome = [IO.Path]::GetFullPath($CodexHome)
$configPath = Join-Path $CodexHome 'hooks.json'
$installDirectory = Join-Path $CodexHome 'hooks/codex-tps-hook'
$scriptPath = Join-Path $installDirectory 'turn-metrics.ps1'
$assets = @(
    'turn-metrics.ps1', 'turn-metrics-pricing.json', 'turn-metrics-reader.ps1',
    'turn-metrics-summary.ps1', 'turn-metrics-store.ps1', 'turn-metrics-display.ps1',
    'usage/store.py', 'usage/child_transcripts.py'
)
$generatedAssets = @('turn-metrics-store.json', 'usage/settings.json')

function Quote-Posix {
    param([string]$Value)
    return "'" + $Value.Replace("'", "'\''") + "'"
}

$posixScript = Quote-Posix $scriptPath
$windowsScript = '"' + $scriptPath + '"'
function Test-OwnedHook {
    param($Handler)
    if ($Handler -isnot [Collections.IDictionary] -or $Handler.type -ne 'command') { return $false }
    return ([string]$Handler.command).Contains($posixScript) -or
        ([string]$Handler.commandWindows).Contains($windowsScript)
}


function Resolve-Python {
    $candidates = if ($PythonPath) { @($PythonPath) } else { @('python', 'python3') }
    foreach ($candidate in $candidates) {
        $command = Get-Command $candidate -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $command) { continue }
        $resolved = & $command.Source -c 'import sys; assert sys.version_info >= (3, 10); print(sys.executable)' 2>$null
        if ($LASTEXITCODE -eq 0 -and $resolved) { return [string]($resolved | Select-Object -Last 1) }
    }
    throw 'Python 3.10+ is required. Install it separately or pass -PythonPath /absolute/path/to/python.'
}

$configuration = if (Test-Path -LiteralPath $configPath) {
    Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -AsHashtable -NoEnumerate -Depth 100
} else { [ordered]@{} }
if ($configuration -isnot [Collections.IDictionary]) { throw 'hooks.json must contain a JSON object.' }
if (-not $configuration.Contains('hooks')) { $configuration['hooks'] = [ordered]@{} }
if ($configuration.hooks -isnot [Collections.IDictionary]) { throw 'hooks must be a JSON object.' }

$eventGroups = @{}
$ownedCount = 0
foreach ($event in @('Stop', 'SubagentStop')) {
    if ($configuration.hooks.Contains($event) -and $configuration.hooks[$event] -isnot [array]) {
        throw "hooks.$event must be a JSON array."
    }
    $groups = @()
    foreach ($group in $configuration.hooks[$event]) {
        if ($group -isnot [Collections.IDictionary] -or $group.hooks -isnot [array]) {
            throw "Each $event group must be an object with a hooks array."
        }
        $remaining = @($group.hooks | Where-Object {
            if (Test-OwnedHook $_) { $script:ownedCount++; return $false }
            return $true
        })
        if ($remaining.Count -gt 0 -or $group.hooks.Count -eq 0) {
            $group['hooks'] = $remaining
            $groups += $group
        }
    }
    $eventGroups[$event] = $groups
}

if ($Action -eq 'Install') {
    [void](Get-Command pwsh -ErrorAction Stop)
    foreach ($asset in $assets) {
        if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $asset) -PathType Leaf)) {
            throw "Missing package file: $asset"
        }
    }
    $pythonExecutable = Resolve-Python
    $settingsPath = Join-Path $installDirectory 'usage/settings.json'
    $usageSettings = if (Test-Path -LiteralPath $settingsPath) {
        Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json -AsHashtable -NoEnumerate
    } else { [ordered]@{} }
    if ($usageSettings -isnot [Collections.IDictionary]) { throw 'usage/settings.json must be a JSON object.' }
    $usageSettings['python'] = $pythonExecutable
    if (-not $usageSettings.Contains('database')) { $usageSettings['database'] = 'data/usage.sqlite3' }
    $arguments = " -NoLogo -NoProfile -NonInteractive -File "
    $options = " -Language $Language" + $(if ($HideCost) { ' -HideCost' } else { '' })
    $windowsInvocation = "& '" + $scriptPath.Replace("'", "''") + "'" + $options
    $encodedInvocation = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($windowsInvocation))
    foreach ($event in @('Stop', 'SubagentStop')) {
        $eventGroups[$event] += [ordered]@{
            hooks = @([ordered]@{
                type = 'command'
                command = 'pwsh' + $arguments + $posixScript + $options
                commandWindows = 'pwsh -NoLogo -NoProfile -NonInteractive -EncodedCommand ' + $encodedInvocation
                timeout = if ($event -eq 'Stop') { 30 } else { 5 }
                statusMessage = "Collecting $event metrics (codex-tps-hook)"
            })
        }
    }
} elseif ($ownedCount -eq 0) {
    Write-Output "No codex-tps-hook registration found in $configPath. Nothing changed."
    return
}

foreach ($event in @('Stop', 'SubagentStop')) {
    if ($eventGroups[$event].Count -gt 0) { $configuration.hooks[$event] = @($eventGroups[$event]) }
    else { [void]$configuration.hooks.Remove($event) }
}
$json = ConvertTo-Json -InputObject $configuration -Depth 100
if ($DryRun) {
    Write-Output "Dry run: $Action; target $configPath; scripts $installDirectory"
    Write-Output $json
    return
}

$existingAssets = @(($assets + $generatedAssets) | Where-Object { Test-Path -LiteralPath (Join-Path $installDirectory $_) })
if ((Test-Path -LiteralPath $configPath) -or ($Action -eq 'Install' -and $existingAssets.Count -gt 0)) {
    $backupDirectory = Join-Path $CodexHome ("backups/codex-tps-hook/" + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fffffff') + '-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($backupDirectory)
    if (Test-Path -LiteralPath $configPath) { Copy-Item -LiteralPath $configPath -Destination (Join-Path $backupDirectory 'hooks.json') }
    if ($Action -eq 'Install') {
        foreach ($asset in $existingAssets) {
            $backupPath = Join-Path $backupDirectory $asset
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($backupPath))
            Copy-Item -LiteralPath (Join-Path $installDirectory $asset) -Destination $backupPath
        }
    }
    Write-Output "Backup: $backupDirectory"
}

if ($Action -eq 'Install') {
    [void][IO.Directory]::CreateDirectory($installDirectory)
    foreach ($asset in $assets) {
        $targetPath = Join-Path $installDirectory $asset
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($targetPath))
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $asset) -Destination $targetPath -Force
    }
    $storeSettings = @{ project_dir = Join-Path $installDirectory 'usage' } | ConvertTo-Json
    [IO.File]::WriteAllText((Join-Path $installDirectory 'turn-metrics-store.json'), $storeSettings, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $installDirectory 'usage/settings.json'), (ConvertTo-Json $usageSettings), [Text.UTF8Encoding]::new($false))
}
[void][IO.Directory]::CreateDirectory($CodexHome)
[IO.File]::WriteAllText($configPath, $json + "`n", [Text.UTF8Encoding]::new($false))
Write-Output "$Action complete: $configPath"
if ($Action -eq 'Install') {
    Write-Output 'Open a new Codex session and review/trust Stop and SubagentStop in /hooks (CLI), or the Desktop hook review UI.'
} else {
    Write-Output 'Registrations removed. Installed scripts, usage database and backups were kept. Open a new Codex session.'
}

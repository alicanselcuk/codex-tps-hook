#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Install', 'Uninstall')][string]$Action = 'Install',
    [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex' }),
    [ValidateSet('en', 'tr')][string]$Language = 'en',
    [switch]$HideCost,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$CodexHome = [IO.Path]::GetFullPath($CodexHome)
$configPath = Join-Path $CodexHome 'hooks.json'
$installDirectory = Join-Path $CodexHome 'hooks/codex-tps-hook'
$scriptPath = Join-Path $installDirectory 'turn-metrics.ps1'
$assets = @('turn-metrics.ps1', 'turn-metrics-pricing.json')

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

# Parse and validate before writing anything. Do not repair a broken user file.
$configuration = if (Test-Path -LiteralPath $configPath) {
    Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -AsHashtable -NoEnumerate -Depth 100
} else { [ordered]@{} }
if ($configuration -isnot [Collections.IDictionary]) { throw 'hooks.json must contain a JSON object.' }
if (-not $configuration.Contains('hooks')) { $configuration['hooks'] = [ordered]@{} }
if ($configuration.hooks -isnot [Collections.IDictionary]) { throw 'hooks must be a JSON object.' }
if ($configuration.hooks.Contains('Stop') -and $configuration.hooks.Stop -isnot [array]) {
    throw 'hooks.Stop must be a JSON array.'
}

$stopGroups = @()
$ownedCount = 0
foreach ($group in $configuration.hooks.Stop) {
    if ($group -isnot [Collections.IDictionary] -or $group.hooks -isnot [array]) {
        throw 'Each Stop group must be an object with a hooks array.'
    }
    $remaining = @($group.hooks | Where-Object {
        if (Test-OwnedHook $_) { $script:ownedCount++; return $false }
        return $true
    })
    if ($remaining.Count -gt 0 -or $group.hooks.Count -eq 0) {
        $group['hooks'] = $remaining
        $stopGroups += $group
    }
}

if ($Action -eq 'Install') {
    [void](Get-Command pwsh -ErrorAction Stop)
    foreach ($asset in $assets) {
        if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $asset) -PathType Leaf)) {
            throw "Missing package file: $asset"
        }
    }
    $arguments = " -NoLogo -NoProfile -NonInteractive -File "
    $options = " -Language $Language" + $(if ($HideCost) { ' -HideCost' } else { '' })
    # cmd.exe expands %ENV% even inside double quotes. Encode the small launcher
    # so Windows paths remain literal; the runtime file itself stays plain text.
    $windowsInvocation = "& '" + $scriptPath.Replace("'", "''") + "'" + $options
    $encodedInvocation = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($windowsInvocation))
    $stopGroups += [ordered]@{
        hooks = @([ordered]@{
            type = 'command'
            command = 'pwsh' + $arguments + $posixScript + $options
            commandWindows = 'pwsh -NoLogo -NoProfile -NonInteractive -EncodedCommand ' + $encodedInvocation
            timeout = 5
            statusMessage = 'Calculating response speed (codex-tps-hook)'
        })
    }
} elseif ($ownedCount -eq 0) {
    Write-Output "No codex-tps-hook registration found in $configPath. Nothing changed."
    return
}

if ($stopGroups.Count -gt 0) { $configuration.hooks['Stop'] = $stopGroups }
else { [void]$configuration.hooks.Remove('Stop') }
$json = ConvertTo-Json -InputObject $configuration -Depth 100
if ($DryRun) {
    Write-Output "Dry run: $Action; target $configPath; scripts $installDirectory"
    Write-Output $json
    return
}

# Back up both registration and previously installed (possibly customized) assets.
$existingAssets = @($assets | Where-Object { Test-Path -LiteralPath (Join-Path $installDirectory $_) })
if ((Test-Path -LiteralPath $configPath) -or ($Action -eq 'Install' -and $existingAssets.Count -gt 0)) {
    $backupDirectory = Join-Path $CodexHome ("backups/codex-tps-hook/" + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fffffff') + '-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($backupDirectory)
    if (Test-Path -LiteralPath $configPath) { Copy-Item -LiteralPath $configPath -Destination (Join-Path $backupDirectory 'hooks.json') }
    if ($Action -eq 'Install') {
        foreach ($asset in $existingAssets) {
            Copy-Item -LiteralPath (Join-Path $installDirectory $asset) -Destination (Join-Path $backupDirectory $asset)
        }
    }
    Write-Output "Backup: $backupDirectory"
}

if ($Action -eq 'Install') {
    [void][IO.Directory]::CreateDirectory($installDirectory)
    foreach ($asset in $assets) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $asset) -Destination (Join-Path $installDirectory $asset) -Force
    }
}
[void][IO.Directory]::CreateDirectory($CodexHome)
[IO.File]::WriteAllText($configPath, $json + "`n", [Text.UTF8Encoding]::new($false))
Write-Output "$Action complete: $configPath"
if ($Action -eq 'Install') {
    Write-Output 'Open a new Codex session and review/trust this hook in /hooks (CLI). In Desktop, use the hook review UI if available, or review it with the CLI using the same Codex home.'
} else {
    Write-Output 'Registration removed. Installed scripts and backups were kept. Open a new Codex session.'
}

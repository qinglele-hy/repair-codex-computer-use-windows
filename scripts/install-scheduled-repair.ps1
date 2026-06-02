param(
    [string]$CodexHome = "D:\Codex\.codex",
    [string]$TaskName = "CodexComputerUseRepairAtLogon",
    [int[]]$DelayMinutes = @(1, 5, 15, 30, 60, 120),
    [switch]$RunNow
)

$ErrorActionPreference = "Stop"

function Resolve-CodexHomePath {
    param([string]$Value)
    if ($Value -and (Test-Path -LiteralPath $Value)) {
        return (Resolve-Path -LiteralPath $Value).Path
    }
    if ($env:CODEX_HOME -and (Test-Path -LiteralPath $env:CODEX_HOME)) {
        return (Resolve-Path -LiteralPath $env:CODEX_HOME).Path
    }
    if (Test-Path -LiteralPath "D:\Codex\.codex") {
        return "D:\Codex\.codex"
    }
    throw "Could not locate CODEX_HOME. Pass -CodexHome explicitly."
}

function New-DelayedLogonTrigger {
    param([int]$DelayMinute)
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    if ($DelayMinute -gt 0) {
        $trigger.Delay = "PT${DelayMinute}M"
    }
    return $trigger
}

$resolvedCodexHome = Resolve-CodexHomePath $CodexHome
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$sourceScript = Join-Path $scriptRoot "repair-at-logon.ps1"
if (-not (Test-Path -LiteralPath $sourceScript)) {
    throw "Missing repair-at-logon.ps1 next to installer: $sourceScript"
}

$maintenanceDir = Join-Path $resolvedCodexHome "maintenance"
if (-not (Test-Path -LiteralPath $maintenanceDir)) {
    New-Item -ItemType Directory -Force -Path $maintenanceDir | Out-Null
}
$targetScript = Join-Path $maintenanceDir "repair-codex-computer-use-at-logon.ps1"
Copy-Item -LiteralPath $sourceScript -Destination $targetScript -Force

$uniqueDelays = @($DelayMinutes | Where-Object { $_ -ge 0 } | Sort-Object -Unique)
if ($uniqueDelays.Count -eq 0) {
    throw "At least one non-negative delay is required."
}

$triggers = @()
foreach ($delay in $uniqueDelays) {
    $triggers += New-DelayedLogonTrigger -DelayMinute $delay
}

$arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$targetScript`" -CodexHome `"$resolvedCodexHome`" -Attempts 1 -InitialDelaySeconds 0 -IntervalSeconds 0"
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arguments
$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -Hidden `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
$principal = New-ScheduledTaskPrincipal `
    -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) `
    -LogonType Interactive `
    -RunLevel Limited

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $triggers `
    -Settings $settings `
    -Principal $principal `
    -Force | Out-Null

if ($RunNow) {
    Start-ScheduledTask -TaskName $TaskName
}

Write-Host "[install-scheduled-repair] Installed task: $TaskName"
Write-Host "[install-scheduled-repair] Script: $targetScript"
Write-Host "[install-scheduled-repair] Delays after logon: $($uniqueDelays -join ', ') minute(s)"

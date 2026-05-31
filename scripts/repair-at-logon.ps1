param(
    [string]$CodexHome = "D:\Codex\.codex",
    [string]$RepairScript,
    [int]$Attempts = 8,
    [int]$InitialDelaySeconds = 10,
    [int]$IntervalSeconds = 20
)

$ErrorActionPreference = "Continue"

function Write-LogLine {
    param(
        [string]$LogPath,
        [string]$Message
    )
    $line = "[repair-at-logon] $(Get-Date -Format o) $Message"
    Add-Content -LiteralPath $LogPath -Value $line
}

if (-not $RepairScript) {
    $RepairScript = Join-Path $CodexHome "skills\repair-codex-computer-use-windows\scripts\repair-bundled-marketplace.ps1"
}

$logDir = Join-Path $CodexHome "logs"
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
}
$logPath = Join-Path $logDir "repair-codex-computer-use-at-logon.log"
Write-LogLine -LogPath $logPath -Message "started attempts=$Attempts repairScript=$RepairScript"

if ($InitialDelaySeconds -gt 0) {
    Start-Sleep -Seconds $InitialDelaySeconds
}

for ($attempt = 1; $attempt -le $Attempts; $attempt += 1) {
    Write-LogLine -LogPath $logPath -Message "attempt $attempt begin"
    if (-not (Test-Path -LiteralPath $RepairScript)) {
        Write-LogLine -LogPath $logPath -Message "missing repair script: $RepairScript"
        break
    }

    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $RepairScript -CodexHome $CodexHome -Apply -SelfTest 2>&1
    $exitCode = $LASTEXITCODE
    Add-Content -LiteralPath $logPath -Value ($output -join [Environment]::NewLine)
    Write-LogLine -LogPath $logPath -Message "attempt $attempt exit=$exitCode"

    if ($attempt -lt $Attempts) {
        Start-Sleep -Seconds $IntervalSeconds
    }
}

Write-LogLine -LogPath $logPath -Message "finished"

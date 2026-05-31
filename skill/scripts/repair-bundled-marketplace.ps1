param(
    [string]$CodexHome,
    [string]$MarketplaceRoot,
    [string]$LogPath,
    [switch]$Apply,
    [switch]$Overwrite,
    [switch]$SelfTest,
    [switch]$SkipChromeHostStabilization,
    [int]$RetryCount = 3,
    [int]$RetryDelayMilliseconds = 700
)

$ErrorActionPreference = "Stop"
$script:LogPath = $null
$script:CopyErrors = New-Object System.Collections.Generic.List[object]

function Write-Step {
    param([string]$Message)
    $line = "[repair-codex-computer-use] $Message"
    Write-Host $line
    if ($script:LogPath) {
        Add-Content -LiteralPath $script:LogPath -Value $line
    }
}

function Initialize-RepairLog {
    param(
        [string]$RequestedLogPath,
        [string]$CodexHomePath
    )
    if ($RequestedLogPath) {
        $path = $RequestedLogPath
    } else {
        $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $path = Join-Path $CodexHomePath "logs\repair-codex-computer-use-$stamp.log"
    }

    $parent = Split-Path -Parent $path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $script:LogPath = $path
    Set-Content -LiteralPath $script:LogPath -Value "repair-codex-computer-use log $(Get-Date -Format o)"
    Write-Step "Log: $script:LogPath"
}

function Resolve-CodexHome {
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
    $homeCandidate = Join-Path $HOME ".codex"
    if (Test-Path -LiteralPath $homeCandidate) {
        return (Resolve-Path -LiteralPath $homeCandidate).Path
    }
    throw "Could not locate CODEX_HOME. Pass -CodexHome explicitly."
}

function Convert-ConfigPath {
    param([string]$Raw)
    if (-not $Raw) {
        return $null
    }
    $value = $Raw.Trim().Trim("'").Trim('"')
    if ($value.StartsWith("\\?\")) {
        return $value.Substring(4)
    }
    return $value
}

function Get-ConfiguredBundledMarketplace {
    param([string]$CodexHomePath)
    $configPath = Join-Path $CodexHomePath "config.toml"
    if (-not (Test-Path -LiteralPath $configPath)) {
        return $null
    }

    $lines = Get-Content -LiteralPath $configPath
    $inBundled = $false
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed -eq "[marketplaces.openai-bundled]") {
            $inBundled = $true
            continue
        }
        if ($inBundled -and $trimmed.StartsWith("[") -and $trimmed.EndsWith("]")) {
            break
        }
        if ($inBundled -and $trimmed -match '^source\s*=\s*(.+)$') {
            return Convert-ConfigPath $Matches[1]
        }
    }
    return $null
}

function Get-PluginConfigState {
    param(
        [string]$CodexHomePath,
        [string]$PluginId
    )
    $configPath = Join-Path $CodexHomePath "config.toml"
    if (-not (Test-Path -LiteralPath $configPath)) {
        return [pscustomobject]@{ Plugin = $PluginId; Status = "config-missing"; Enabled = $null }
    }

    $section = "[plugins.`"$PluginId`"]"
    $lines = Get-Content -LiteralPath $configPath
    $inSection = $false
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed -eq $section) {
            $inSection = $true
            continue
        }
        if ($inSection -and $trimmed.StartsWith("[") -and $trimmed.EndsWith("]")) {
            break
        }
        if ($inSection -and $trimmed -match '^enabled\s*=\s*(true|false)\s*$') {
            $enabled = [bool]::Parse($Matches[1])
            return [pscustomobject]@{
                Plugin = $PluginId
                Status = $(if ($enabled) { "enabled" } else { "disabled" })
                Enabled = $enabled
            }
        }
    }

    return [pscustomobject]@{ Plugin = $PluginId; Status = "not-configured"; Enabled = $null }
}

function Find-PackagedBundledRoot {
    $packageRoot = Join-Path $env:ProgramFiles "WindowsApps"
    if (Test-Path -LiteralPath $packageRoot) {
        $candidates = Get-ChildItem -LiteralPath $packageRoot -Directory -Filter "OpenAI.Codex_*_x64__2p2nqsd0c76g0" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending
        foreach ($candidate in $candidates) {
            $root = Join-Path $candidate.FullName "app\resources\plugins\openai-bundled"
            if (Test-Path -LiteralPath (Join-Path $root ".agents\plugins\marketplace.json")) {
                return $root
            }
        }
    }
    throw "Could not find packaged openai-bundled resources under Program Files\WindowsApps."
}

function Get-LatestPluginCacheRoot {
    param(
        [string]$CodexHomePath,
        [string]$PluginName
    )
    $pluginRoot = Join-Path $CodexHomePath "plugins\cache\openai-bundled\$PluginName"
    if (-not (Test-Path -LiteralPath $pluginRoot)) {
        return $null
    }
    $candidates = Get-ChildItem -LiteralPath $pluginRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName ".codex-plugin\plugin.json") } |
        Sort-Object LastWriteTime -Descending
    if ($candidates.Count -gt 0) {
        return $candidates[0].FullName
    }
    return $null
}

function Copy-ItemWithRetry {
    param(
        [string]$Source,
        [string]$Destination,
        [switch]$ReplaceExisting,
        [int]$Attempts,
        [int]$DelayMilliseconds
    )

    $lastError = $null
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            Copy-Item -LiteralPath $Source -Destination $Destination -Force:$ReplaceExisting -ErrorAction Stop
            return $true
        } catch {
            $lastError = $_.Exception.Message
            if ($attempt -lt $Attempts) {
                Start-Sleep -Milliseconds $DelayMilliseconds
            }
        }
    }

    $script:CopyErrors.Add([pscustomobject]@{
        Source = $Source
        Destination = $Destination
        Error = $lastError
    })
    return $false
}

function Copy-TreeConservative {
    param(
        [string]$Source,
        [string]$Destination,
        [switch]$ApplyChanges,
        [switch]$ReplaceExisting,
        [int]$Attempts,
        [int]$DelayMilliseconds
    )
    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Missing source: $Source"
    }

    $planned = New-Object System.Collections.Generic.List[string]
    if ($ApplyChanges -and -not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Force -Path $Destination -ErrorAction Stop | Out-Null
    }

    Get-ChildItem -LiteralPath $Source -Force -Recurse -ErrorAction Stop | ForEach-Object {
        $relative = $_.FullName.Substring($Source.Length).TrimStart("\")
        $target = Join-Path $Destination $relative
        if ($_.PSIsContainer) {
            if (-not (Test-Path -LiteralPath $target)) {
                $planned.Add("dir  $target")
                if ($ApplyChanges) {
                    New-Item -ItemType Directory -Force -Path $target -ErrorAction Stop | Out-Null
                }
            }
            return
        }

        $shouldCopy = $ReplaceExisting -or -not (Test-Path -LiteralPath $target)
        if ($shouldCopy) {
            $planned.Add("file $target")
            if ($ApplyChanges) {
                $parent = Split-Path -Parent $target
                if (-not (Test-Path -LiteralPath $parent)) {
                    New-Item -ItemType Directory -Force -Path $parent -ErrorAction Stop | Out-Null
                }
                [void](Copy-ItemWithRetry -Source $_.FullName -Destination $target -ReplaceExisting:$ReplaceExisting -Attempts $Attempts -DelayMilliseconds $DelayMilliseconds)
            }
        }
    }
    return $planned
}

function Test-RequiredFiles {
    param([string]$Root)
    $required = @(
        ".agents\plugins\marketplace.json",
        "plugins\browser\.codex-plugin\plugin.json",
        "plugins\chrome\.codex-plugin\plugin.json",
        "plugins\computer-use\.codex-plugin\plugin.json",
        "plugins\computer-use\scripts\computer-use-client.mjs",
        "plugins\computer-use\node_modules\@oai\sky\package.json",
        "plugins\computer-use\node_modules\@oai\sky\bin\windows\codex-computer-use.exe",
        "plugins\computer-use\node_modules\@oai\sky\dist\project\cua\sky_js\src\targets\windows\internal\helper_transport.js"
    )

    foreach ($relative in $required) {
        $path = Join-Path $Root $relative
        $item = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
        [pscustomobject]@{
            Exists = $null -ne $item
            SizeBytes = $(if ($item) { $item.Length } else { $null })
            Path = $path
        }
    }

    $helperPath = Join-Path $Root "plugins\computer-use\node_modules\@oai\sky\dist\project\cua\sky_js\src\targets\windows\internal\helper_transport.js"
    if (Test-Path -LiteralPath $helperPath) {
        $helperText = Get-Content -LiteralPath $helperPath -Raw
        $match = [regex]::Match($helperText, 'from"([^"]*tslib\.es6\.js)"')
        if ($match.Success) {
            $relativeImport = $match.Groups[1].Value.Replace("/", "\")
            $dependencyPath = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $helperPath) $relativeImport))
            $item = Get-Item -LiteralPath $dependencyPath -ErrorAction SilentlyContinue
            [pscustomobject]@{
                Exists = $null -ne $item
                SizeBytes = $(if ($item) { $item.Length } else { $null })
                Path = $dependencyPath
            }
        }
    }
}

function Get-StableChromeCacheRoot {
    param([string]$CodexHomePath)
    $chromeCacheRoot = Join-Path $CodexHomePath "plugins\cache\openai-bundled\chrome"
    if (-not (Test-Path -LiteralPath $chromeCacheRoot)) {
        return $null
    }

    $candidates = Get-ChildItem -LiteralPath $chromeCacheRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -ne "latest" -and
            (Test-Path -LiteralPath (Join-Path $_.FullName "extension-host\windows\x64\extension-host.exe")) -and
            (Test-Path -LiteralPath (Join-Path $_.FullName "scripts\browser-client.mjs"))
        } |
        Sort-Object LastWriteTime -Descending

    if ($candidates.Count -gt 0) {
        return $candidates[0].FullName
    }
    return $null
}

function Stop-ChromeHostsUsingMarketplace {
    param(
        [string]$CodexHomePath,
        [string]$TargetMarketplacePath,
        [switch]$ApplyChanges
    )
    $latestHost = Join-Path $CodexHomePath "plugins\cache\openai-bundled\chrome\latest\extension-host\windows\x64\extension-host.exe"
    $marketplaceHost = Join-Path $TargetMarketplacePath "plugins\chrome\extension-host\windows\x64\extension-host.exe"
    $latestPattern = [regex]::Escape($latestHost)
    $marketplacePattern = [regex]::Escape($marketplaceHost)
    $targets = @(Get-CimInstance Win32_Process | Where-Object {
        ($_.Name -in @("cmd.exe", "extension-host.exe")) -and
        (($_.CommandLine -match $latestPattern) -or ($_.CommandLine -match $marketplacePattern))
    })

    if ($targets.Count -eq 0) {
        Write-Step "No Chrome native hosts are running from the marketplace/latest path."
        return
    }

    Write-Step "Chrome native hosts using marketplace/latest path: $($targets.Count)"
    foreach ($process in $targets) {
        Write-Step ("host pid={0} name={1}" -f $process.ProcessId, $process.Name)
        if ($ApplyChanges) {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
        }
    }

    if ($ApplyChanges) {
        Start-Sleep -Milliseconds 800
        $remaining = @(Get-CimInstance Win32_Process | Where-Object {
            ($_.Name -in @("cmd.exe", "extension-host.exe")) -and
            (($_.CommandLine -match $latestPattern) -or ($_.CommandLine -match $marketplacePattern))
        })
        if ($remaining.Count -gt 0) {
            throw "Chrome native host stabilization incomplete: $($remaining.Count) old host process(es) still use marketplace/latest path."
        }
        Write-Step "Stopped Chrome native hosts using marketplace/latest path."
    }
}

function Update-JsonFile {
    param(
        [string]$Path,
        [scriptblock]$Mutate,
        [switch]$ApplyChanges
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    $original = Get-Content -LiteralPath $Path -Raw
    $json = $original | ConvertFrom-Json
    & $Mutate $json
    $updated = ($json | ConvertTo-Json -Depth 30)

    if ($updated -ne $original.Trim()) {
        Write-Step "Chrome native host config needs update: $Path"
        if ($ApplyChanges) {
            $updated | Set-Content -LiteralPath $Path -Encoding UTF8
        }
        return $true
    }
    return $false
}

function Protect-ChromeNativeHostFromMarketplaceLock {
    param(
        [string]$CodexHomePath,
        [string]$TargetMarketplacePath,
        [string]$PackagedChromeSource,
        [switch]$ApplyChanges,
        [switch]$Skip
    )

    if ($Skip) {
        Write-Step "Chrome native host stabilization skipped."
        return
    }

    $stableChromeRoot = Get-StableChromeCacheRoot $CodexHomePath
    if (-not $stableChromeRoot) {
        $chromeCacheRoot = Join-Path $CodexHomePath "plugins\cache\openai-bundled\chrome"
        $version = "0.1.7"
        $stableChromeRoot = Join-Path $chromeCacheRoot $version
        if ($ApplyChanges -and -not (Test-Path -LiteralPath $stableChromeRoot)) {
            New-Item -ItemType Directory -Force -Path $stableChromeRoot | Out-Null
        }
    }

    Write-Step "Stable Chrome cache: $stableChromeRoot"
    if (-not (Test-Path -LiteralPath $stableChromeRoot)) {
        Write-Step "Stable Chrome cache does not exist yet."
        return
    }

    if (Test-Path -LiteralPath $PackagedChromeSource) {
        $planned = Copy-TreeConservative -Source $PackagedChromeSource -Destination $stableChromeRoot -ApplyChanges:$ApplyChanges -ReplaceExisting:$false -Attempts 3 -DelayMilliseconds 700
        if ($planned.Count -gt 0) {
            Write-Step "Stable Chrome cache missing items: $($planned.Count)"
        }
    }

    $stableHost = Join-Path $stableChromeRoot "extension-host\windows\x64\extension-host.exe"
    $stableClient = Join-Path $stableChromeRoot "scripts\browser-client.mjs"
    if (-not (Test-Path -LiteralPath $stableHost)) {
        throw "Missing stable Chrome extension host: $stableHost"
    }
    if (-not (Test-Path -LiteralPath $stableClient)) {
        throw "Missing stable Chrome browser client: $stableClient"
    }

    $changed = 0
    $manifestPath = Join-Path $env:LOCALAPPDATA "OpenAI\extension\com.openai.codexextension.json"
    if (Update-JsonFile -Path $manifestPath -ApplyChanges:$ApplyChanges -Mutate {
            param($json)
            $json.path = $stableHost
        }) {
        $changed += 1
    }

    $hostListPaths = @(
        (Join-Path $CodexHomePath "chrome-native-hosts.json"),
        (Join-Path $env:LOCALAPPDATA "OpenAI\Codex\chrome-native-hosts.json")
    )
    foreach ($hostListPath in $hostListPaths) {
        if (Update-JsonFile -Path $hostListPath -ApplyChanges:$ApplyChanges -Mutate {
                param($json)
                foreach ($entry in $json.chromeNativeHosts) {
                    $entry.extensionHostPath = $stableHost
                    $entry.browserClientPath = $stableClient
                    $entry.updatedAt = (Get-Date).ToUniversalTime().ToString("o")
                }
            }) {
            $changed += 1
        }
    }

    if ($changed -eq 0) {
        Write-Step "Chrome native host configs already point at stable cache."
    }

    Stop-ChromeHostsUsingMarketplace -CodexHomePath $CodexHomePath -TargetMarketplacePath $TargetMarketplacePath -ApplyChanges:$ApplyChanges
}

function Find-CodexCli {
    $binRoot = Join-Path $env:LOCALAPPDATA "OpenAI\Codex\bin"
    if (Test-Path -LiteralPath $binRoot) {
        $candidates = Get-ChildItem -LiteralPath $binRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending
        foreach ($candidate in $candidates) {
            $exe = Join-Path $candidate.FullName "codex.exe"
            if (Test-Path -LiteralPath $exe) {
                return $exe
            }
        }
    }

    $command = Get-Command "codex.exe" -ErrorAction SilentlyContinue
    if ($command -and $command.Source -and (Test-Path -LiteralPath $command.Source)) {
        return $command.Source
    }

    $command = Get-Command "codex" -ErrorAction SilentlyContinue
    if ($command -and $command.Source -and (Test-Path -LiteralPath $command.Source)) {
        return $command.Source
    }

    return $null
}

function Invoke-CodexPluginList {
    param(
        [string]$CodexHomePath,
        [string]$CodexExe
    )
    $oldCodexHome = $env:CODEX_HOME
    try {
        $env:CODEX_HOME = $CodexHomePath
        $output = & $CodexExe plugin list 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $env:CODEX_HOME = $oldCodexHome
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = ($output -join [Environment]::NewLine)
    }
}

function Test-PluginListOutput {
    param([string]$Output)
    $requiredPlugins = @(
        "browser@openai-bundled",
        "chrome@openai-bundled",
        "computer-use@openai-bundled"
    )

    foreach ($plugin in $requiredPlugins) {
        $line = ($Output -split "`r?`n") | Where-Object { $_ -match [regex]::Escape($plugin) } | Select-Object -First 1
        [pscustomobject]@{
            Plugin = $plugin
            Healthy = [bool]($line -and $line -match "installed" -and $line -match "enabled")
            Line = $line
        }
    }
}

$resolvedCodexHome = Resolve-CodexHome $CodexHome
Initialize-RepairLog -RequestedLogPath $LogPath -CodexHomePath $resolvedCodexHome

$configuredMarketplace = Get-ConfiguredBundledMarketplace $resolvedCodexHome
if ($MarketplaceRoot) {
    $targetMarketplace = $MarketplaceRoot
} elseif ($configuredMarketplace) {
    $targetMarketplace = $configuredMarketplace
} else {
    $targetMarketplace = Join-Path $resolvedCodexHome ".tmp\bundled-marketplaces\openai-bundled"
}

$resourceRoot = Find-PackagedBundledRoot
$browserSource = Get-LatestPluginCacheRoot $resolvedCodexHome "browser"
if (-not $browserSource) { $browserSource = Join-Path $resourceRoot "plugins\browser" }
$computerSource = Get-LatestPluginCacheRoot $resolvedCodexHome "computer-use"
if (-not $computerSource) { $computerSource = Join-Path $resourceRoot "plugins\computer-use" }
$chromeSource = Join-Path $resourceRoot "plugins\chrome"
$latexSource = Join-Path $resourceRoot "plugins\latex"

Write-Step "CodexHome: $resolvedCodexHome"
Write-Step "Marketplace target: $targetMarketplace"
Write-Step "Packaged resources: $resourceRoot"
Write-Step "Browser source: $browserSource"
Write-Step "Computer Use source: $computerSource"
Write-Step "Chrome source: $chromeSource"
Write-Step "mode: $(if ($Apply) { "APPLY" } else { "DRY-RUN" })"
Write-Step "overwrite: $([bool]$Overwrite)"
Write-Step "self-test: $([bool]$SelfTest)"
Write-Step "chrome-host-stabilization: $(-not [bool]$SkipChromeHostStabilization)"

Write-Step "Config check:"
$configStates = @(
    Get-PluginConfigState $resolvedCodexHome "browser@openai-bundled"
    Get-PluginConfigState $resolvedCodexHome "chrome@openai-bundled"
    Get-PluginConfigState $resolvedCodexHome "computer-use@openai-bundled"
)
$configStates | Format-Table -AutoSize
$configStates | ForEach-Object { Write-Step ("config {0}: {1}" -f $_.Plugin, $_.Status) }

$disabled = @($configStates | Where-Object { $_.Enabled -eq $false })
if ($disabled.Count -gt 0) {
    throw "One or more bundled plugins are disabled in config.toml. Enable them before repairing files."
}

$allPlanned = New-Object System.Collections.Generic.List[string]
$copyJobs = @(
    @{ Source = (Join-Path $resourceRoot ".agents"); Destination = (Join-Path $targetMarketplace ".agents") },
    @{ Source = $browserSource; Destination = (Join-Path $targetMarketplace "plugins\browser") },
    @{ Source = $computerSource; Destination = (Join-Path $targetMarketplace "plugins\computer-use") },
    @{ Source = $chromeSource; Destination = (Join-Path $targetMarketplace "plugins\chrome") },
    @{ Source = $latexSource; Destination = (Join-Path $targetMarketplace "plugins\latex") }
)

foreach ($job in $copyJobs) {
    $planned = Copy-TreeConservative -Source $job.Source -Destination $job.Destination -ApplyChanges:$Apply -ReplaceExisting:$Overwrite -Attempts $RetryCount -DelayMilliseconds $RetryDelayMilliseconds
    foreach ($item in $planned) {
        $allPlanned.Add($item)
    }
}

Protect-ChromeNativeHostFromMarketplaceLock -CodexHomePath $resolvedCodexHome -TargetMarketplacePath $targetMarketplace -PackagedChromeSource $chromeSource -ApplyChanges:$Apply -Skip:$SkipChromeHostStabilization

if ($allPlanned.Count -eq 0) {
    Write-Step "No missing files found."
} else {
    Write-Step "Planned/copied items: $($allPlanned.Count)"
    $allPlanned | Select-Object -First 80 | ForEach-Object {
        Write-Host $_
        if ($script:LogPath) { Add-Content -LiteralPath $script:LogPath -Value $_ }
    }
    if ($allPlanned.Count -gt 80) {
        Write-Host "... $($allPlanned.Count - 80) more"
        if ($script:LogPath) { Add-Content -LiteralPath $script:LogPath -Value "... $($allPlanned.Count - 80) more" }
    }
}

if ($script:CopyErrors.Count -gt 0) {
    Write-Step "Copy errors:"
    $script:CopyErrors | Format-Table -AutoSize
    foreach ($errorItem in $script:CopyErrors) {
        Write-Step ("copy failed: {0} -> {1}: {2}" -f $errorItem.Source, $errorItem.Destination, $errorItem.Error)
    }
    throw "Repair incomplete: $($script:CopyErrors.Count) copy operation(s) failed."
}

Write-Step "Required file check:"
$results = @(Test-RequiredFiles $targetMarketplace)
$results | Format-Table -AutoSize
foreach ($result in $results) {
    Write-Step ("required {0}: {1} bytes={2}" -f $(if ($result.Exists) { "ok" } else { "missing" }), $result.Path, $result.SizeBytes)
}

$missing = @($results | Where-Object { -not $_.Exists })
if ($missing.Count -gt 0) {
    throw "Repair incomplete: $($missing.Count) required files are missing."
}

$zeroByte = @($results | Where-Object { $_.Exists -and $_.SizeBytes -eq 0 })
if ($zeroByte.Count -gt 0) {
    throw "Repair incomplete: $($zeroByte.Count) required files are zero bytes."
}

if ($SelfTest) {
    $codexExe = Find-CodexCli
    if (-not $codexExe) {
        throw "Self-test requested, but codex.exe was not found."
    }
    Write-Step "Codex CLI: $codexExe"
    $pluginList = Invoke-CodexPluginList -CodexHomePath $resolvedCodexHome -CodexExe $codexExe
    Write-Step "codex plugin list exit code: $($pluginList.ExitCode)"
    if ($script:LogPath) {
        Add-Content -LiteralPath $script:LogPath -Value "----- codex plugin list -----"
        Add-Content -LiteralPath $script:LogPath -Value $pluginList.Output
        Add-Content -LiteralPath $script:LogPath -Value "-----------------------------"
    }
    if ($pluginList.ExitCode -ne 0) {
        throw "codex plugin list failed with exit code $($pluginList.ExitCode)."
    }

    $pluginRows = @(Test-PluginListOutput -Output $pluginList.Output)
    $pluginRows | Format-Table -AutoSize
    foreach ($row in $pluginRows) {
        Write-Step ("plugin-list {0}: {1}" -f $row.Plugin, $(if ($row.Healthy) { "installed, enabled" } else { "not healthy" }))
    }
    $unhealthy = @($pluginRows | Where-Object { -not $_.Healthy })
    if ($unhealthy.Count -gt 0) {
        throw "Self-test failed: $($unhealthy.Count) bundled plugin row(s) are not installed and enabled."
    }
}

if (-not $Apply) {
    Write-Step "Dry-run completed. Re-run with -Apply to copy missing files."
} elseif ($SelfTest) {
    Write-Step "Repair and self-test completed. Fully quit and reopen Codex desktop if an existing thread still reports Computer Use unavailable."
} else {
    Write-Step "Repair completed. Fully quit and reopen Codex desktop before retrying Computer Use."
}

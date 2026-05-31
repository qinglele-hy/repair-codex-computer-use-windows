param(
    [string]$CodexHome,
    [string]$MarketplaceRoot,
    [switch]$Apply,
    [switch]$Overwrite
)

$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "[repair-codex-computer-use] $Message"
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

function Find-PackagedBundledRoot {
    $roots = @(
        Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps"
    )
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

function Copy-TreeConservative {
    param(
        [string]$Source,
        [string]$Destination,
        [switch]$ApplyChanges,
        [switch]$ReplaceExisting
    )
    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Missing source: $Source"
    }

    $planned = New-Object System.Collections.Generic.List[string]
    if ($ApplyChanges -and -not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    }

    Get-ChildItem -LiteralPath $Source -Force -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $relative = $_.FullName.Substring($Source.Length).TrimStart("\")
        $target = Join-Path $Destination $relative
        if ($_.PSIsContainer) {
            if (-not (Test-Path -LiteralPath $target)) {
                $planned.Add("dir  $target")
                if ($ApplyChanges) {
                    New-Item -ItemType Directory -Force -Path $target | Out-Null
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
                    New-Item -ItemType Directory -Force -Path $parent | Out-Null
                }
                Copy-Item -LiteralPath $_.FullName -Destination $target -Force:$ReplaceExisting -ErrorAction SilentlyContinue
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
        [pscustomobject]@{
            Exists = Test-Path -LiteralPath $path
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
            [pscustomobject]@{
                Exists = Test-Path -LiteralPath $dependencyPath
                Path = $dependencyPath
            }
        }
    }
}

$resolvedCodexHome = Resolve-CodexHome $CodexHome
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
Write-Step ($(if ($Apply) { "mode: APPLY" } else { "mode: DRY-RUN" }))

$allPlanned = New-Object System.Collections.Generic.List[string]
$copyJobs = @(
    @{ Source = (Join-Path $resourceRoot ".agents"); Destination = (Join-Path $targetMarketplace ".agents") },
    @{ Source = $browserSource; Destination = (Join-Path $targetMarketplace "plugins\browser") },
    @{ Source = $computerSource; Destination = (Join-Path $targetMarketplace "plugins\computer-use") },
    @{ Source = $chromeSource; Destination = (Join-Path $targetMarketplace "plugins\chrome") },
    @{ Source = $latexSource; Destination = (Join-Path $targetMarketplace "plugins\latex") }
)

foreach ($job in $copyJobs) {
    $planned = Copy-TreeConservative -Source $job.Source -Destination $job.Destination -ApplyChanges:$Apply -ReplaceExisting:$Overwrite
    foreach ($item in $planned) {
        $allPlanned.Add($item)
    }
}

if ($allPlanned.Count -eq 0) {
    Write-Step "No missing files found."
} else {
    Write-Step "Planned/copied items: $($allPlanned.Count)"
    $allPlanned | Select-Object -First 80 | ForEach-Object { Write-Host $_ }
    if ($allPlanned.Count -gt 80) {
        Write-Host "... $($allPlanned.Count - 80) more"
    }
}

Write-Step "Required file check:"
$results = Test-RequiredFiles $targetMarketplace
$results | Format-Table -AutoSize

$missing = @($results | Where-Object { -not $_.Exists })
if ($missing.Count -gt 0) {
    throw "Repair incomplete: $($missing.Count) required files are missing."
}

if (-not $Apply) {
    Write-Step "Dry-run completed. Re-run with -Apply to copy missing files."
} else {
    Write-Step "Repair completed. Fully quit and reopen Codex desktop before retrying Computer Use."
}

# Repair Codex Computer Use on Windows

A small community repair utility for a common Codex Desktop on Windows issue where **Computer Use**, **in-app Browser**, or the bundled **Chrome** plugin appears as unavailable even though the plugin files are installed.

This is not an official OpenAI project.

## Symptoms

You may see one of these in Codex settings or logs:

- `Computer Use plugin unavailable`
- `in-app browser plugin unavailable`
- `Windows Computer Use helper paths are unavailable`
- `Computer Use native pipe path is unavailable`
- `bundled_plugins_marketplace_resolve_failed`
- `EBUSY ... chrome\extension-host\windows\x64`

## What It Fixes

The script repairs a partial or corrupted local `openai-bundled` marketplace snapshot under:

```text
%CODEX_HOME%\.tmp\bundled-marketplaces\openai-bundled
```

It conservatively copies missing bundled plugin files from known-good locations:

- `%CODEX_HOME%\plugins\cache\openai-bundled`
- the packaged Codex Desktop resources under `C:\Program Files\WindowsApps`

It does not delete plugin caches by default.

## Quick Start

Open PowerShell and run a health check first. This checks the marketplace files, plugin config, and `codex plugin list` without changing files:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\repair-bundled-marketplace.ps1" -SelfTest
```

If the health check reports missing files, apply the repair and immediately run the same self-test:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\repair-bundled-marketplace.ps1" -Apply -SelfTest
```

If your Codex home is not auto-detected, pass it explicitly:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\repair-bundled-marketplace.ps1" -CodexHome "D:\Codex\.codex" -Apply -SelfTest
```

The script is idempotent: when the machine is already healthy, `-Apply -SelfTest` should report `No missing files found` and leave the cache untouched. Each run writes a log under:

```text
%CODEX_HOME%\logs\repair-codex-computer-use-*.log
```

After repair, fully quit and reopen Codex Desktop. Existing Codex sessions will not receive the restored Computer Use native pipe path until a restart.

On Windows, the script also stabilizes the Chrome native messaging host when needed. If Chrome is running the Codex extension host from `plugins\cache\openai-bundled\chrome\latest` and that `latest` path points into the temporary bundled marketplace, the script rewrites the host config to use the stable cached Chrome plugin version instead. This prevents Chrome from locking the temporary marketplace and causing repeated `EBUSY` refresh failures.

For machines where Codex or Chrome rewrites these paths after reboot, install the included logon repair script as a Windows scheduled task. It runs the same repair a few times after login so startup races are corrected automatically:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\install-scheduled-repair.ps1" -CodexHome "D:\Codex\.codex" -RunNow
```

The installer registers a hidden user logon task named `CodexComputerUseRepairAtLogon`. Instead of one long-running repair loop, it schedules short one-shot repair passes at 1, 5, 15, 30, 60, and 120 minutes after logon. This is more resilient when a Codex Desktop update finishes after Windows login and rewrites the bundled plugin paths again.

## Verify

If you have the Codex CLI available, run:

```powershell
$env:CODEX_HOME = "D:\Codex\.codex"
codex plugin list
```

Expected rows:

```text
browser@openai-bundled       installed, enabled
chrome@openai-bundled        installed, enabled
computer-use@openai-bundled  installed, enabled
```

## Included Codex Skill

The `skill/` directory contains the Codex skill version of the same workflow. To install it manually, copy that folder into:

```text
%CODEX_HOME%\skills\repair-codex-computer-use-windows
```

## Safety Notes

- Run the `-SelfTest` health check before `-Apply`.
- Prefer `-SelfTest` on this machine so failures are visible immediately.
- Leave Chrome native host stabilization enabled unless you are debugging the Chrome plugin cache itself.
- Do not run `-Overwrite` unless you know existing files are stale or malformed.
- Do not manually start `codex-computer-use.exe`; Codex Desktop needs to manage the native pipe and approval flow.
- Restart Codex Desktop after repair.

## License

MIT

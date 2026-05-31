---
name: repair-codex-computer-use-windows
description: Diagnose, repair, and self-test Codex desktop bundled plugin cache issues on Windows when Computer Use, the in-app Browser, or Chrome plugin settings show unavailable; use when logs mention Windows Computer Use helper paths unavailable, Computer Use native pipe path unavailable, bundled marketplace resolve failures, EBUSY locked chrome extension-host folders, stale openai-bundled plugin paths, or the user wants this Windows machine kept stable for Computer Use.
---

# Repair Codex Computer Use on Windows

## Goal

Restore Codex desktop's Windows Computer Use and bundled Browser/Chrome plugin availability when the plugin files exist but the settings UI shows "plugin unavailable".

The common failure is a corrupted or partial `openai-bundled` marketplace snapshot under `CODEX_HOME\.tmp\bundled-marketplaces\openai-bundled`. Codex may still have complete plugin copies in `CODEX_HOME\plugins\cache\openai-bundled` or in the packaged app resources.

## Workflow

1. Inspect before editing.
   - Check `D:\Codex\.codex\config.toml` or `$env:CODEX_HOME\config.toml` for `[plugins."computer-use@openai-bundled"] enabled = true`.
   - Search Codex desktop logs for signatures in `references/failure-signatures.md`.
   - Verify the helper files exist in the cache:
     `plugins\cache\openai-bundled\computer-use\<version>\node_modules\@oai\sky\bin\windows\codex-computer-use.exe`
     and
     `plugins\cache\openai-bundled\computer-use\<version>\node_modules\@oai\sky\dist\project\cua\sky_js\src\targets\windows\internal\helper_transport.js`.

2. Prefer the bundled repair script.
   - Health-check first. This does not change files; it checks required files, config, and `codex plugin list`:
     ```powershell
     powershell -NoProfile -ExecutionPolicy Bypass -File "<skill-root>\scripts\repair-bundled-marketplace.ps1" -CodexHome "D:\Codex\.codex" -SelfTest
     ```
   - Apply only when the health check shows missing marketplace/plugin files:
     ```powershell
     powershell -NoProfile -ExecutionPolicy Bypass -File "<skill-root>\scripts\repair-bundled-marketplace.ps1" -CodexHome "D:\Codex\.codex" -Apply -SelfTest
     ```
   - Treat `-Apply -SelfTest` as the local stability command; when already healthy it should report `No missing files found` and pass.
   - Use `-Overwrite` only when files exist but are clearly stale or malformed.
   - Leave Chrome native host stabilization enabled. It prevents Chrome from running the Codex extension host from `chrome\latest` when `latest` points into the temporary marketplace.
   - Check the generated log under `CODEX_HOME\logs\repair-codex-computer-use-*.log` when any step fails.

3. Verify with the CLI from an explicit path if `codex` on PATH is blocked by WindowsApps:
   ```powershell
   $env:CODEX_HOME = "D:\Codex\.codex"
   & "$env:LOCALAPPDATA\OpenAI\Codex\bin\7dea4a003bc76627\codex.exe" plugin list
   ```
   The important rows should read `installed, enabled` for:
   - `computer-use@openai-bundled`
   - `browser@openai-bundled`
   - `chrome@openai-bundled`

   The bundled script performs this check automatically when run with `-SelfTest`.

4. Restart Codex desktop.
   - Existing tool sessions do not receive the restored Computer Use native pipe path after creation.
   - After repair, fully quit and reopen Codex, then start a fresh thread or retry Computer Use.

## Interpretation

- If Browser runtime works but settings says unavailable, treat it as a settings/status UI stale state until CLI and logs disagree.
- If Computer Use reports `Computer Use native pipe path is unavailable`, the current tool session lacks the injected pipe path; file repair alone will not fix that already-running session.
- If logs show `Windows Computer Use helper paths are unavailable`, repair the bundled marketplace snapshot so Codex can resolve the helper path on the next refresh/restart.
- If logs show repeated `EBUSY` under `plugins\chrome\extension-host\windows\x64`, check whether Chrome is running `extension-host.exe` from `plugins\cache\openai-bundled\chrome\latest`. If `latest` is a junction into `.tmp\bundled-marketplaces`, run the repair script with `-Apply -SelfTest` so it rewrites the Chrome native host config to the stable cache path and stops the old host process.
- Do not manually spawn `codex-computer-use.exe` or build a custom helper protocol. App approvals and interruption handling depend on Codex's native pipe flow.

## Safety

- Do not delete plugin caches as the first step.
- Do not kill the running Codex desktop from inside the active Codex session unless the user explicitly accepts that the thread may disconnect.
- Copy missing files conservatively from known-good sources; keep destructive cleanup out of the default workflow.
- Do not ignore copy failures. The script retries transient locked-file errors and then fails loudly with the source, destination, and error.
- If the script cannot find packaged resources or cache sources, stop and report the exact missing path.

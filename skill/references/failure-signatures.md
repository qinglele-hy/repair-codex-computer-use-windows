# Failure Signatures

Search these logs first:

```powershell
$logRoot = "$env:LOCALAPPDATA\Packages\OpenAI.Codex_2p2nqsd0c76g0\LocalCache\Local\Codex\Logs"
Select-String -Path "$logRoot\**\*.log" -Pattern `
  'computer-use native pipe startup ready',
  'computer-use native pipe startup failed',
  'Windows Computer Use helper paths are unavailable',
  'Computer Use native pipe path is unavailable',
  'computer-use native pipe helper paths changed',
  'bundled_plugins_marketplace_resolve_failed',
  'EBUSY',
  'browser_use_availability_resolved' `
  -CaseSensitive:$false -Context 2,3
```

Interpretation:

- `browser_use_availability_resolved available=true` means the in-app Browser backend is actually available even if the settings page is stale.
- `computer-use native pipe startup ready pipePath=...` followed later by `helper paths changed` and `Windows Computer Use helper paths are unavailable` points to a broken marketplace/plugin path refresh.
- `bundled_plugins_marketplace_resolve_failed` with `EBUSY ... chrome\extension-host\windows\x64` means the bundled marketplace refresh was interrupted by a locked Chrome extension host directory.
- `Computer Use native pipe path is unavailable` inside a current tool call means the current tool session was created without `SKY_CUA_NATIVE_PIPE_DIRECTORY`; restart Codex after repairing files.

Useful verification commands:

```powershell
$env:CODEX_HOME = "D:\Codex\.codex"
& "C:\Users\Administrator\AppData\Local\OpenAI\Codex\bin\7dea4a003bc76627\codex.exe" plugin list
& "C:\Users\Administrator\AppData\Local\OpenAI\Codex\bin\7dea4a003bc76627\codex.exe" doctor --summary --ascii
```

Expected plugin-list rows after repair:

```text
browser@openai-bundled       installed, enabled
chrome@openai-bundled        installed, enabled
computer-use@openai-bundled  installed, enabled
```

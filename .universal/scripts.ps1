# One job at a time per script: a slow run is skipped over, never stacked up.
New-PSUScript -Name 'Scripts/Sync-DebugLogs.ps1' -Path 'Scripts/Sync-DebugLogs.ps1' -ConcurrentJobs 1 -TimeOut 30 -MaxHistory 500 `
    -Description 'Reads new lmgrd debug-log lines for every enabled server.'
New-PSUScript -Name 'Scripts/Sync-LiveStatus.ps1' -Path 'Scripts/Sync-LiveStatus.ps1' -ConcurrentJobs 1 -TimeOut 30 -MaxHistory 500 `
    -Description 'Polls every enabled server with lmstat: live usage, seat limits, up/down.'
New-PSUScript -Name 'Scripts/Initialize-Database.ps1' -Path 'Scripts/Initialize-Database.ps1' -ConcurrentJobs 1 -TimeOut 5 `
    -Description 'Creates or upgrades the Fathom tables. Run after installing or updating.'

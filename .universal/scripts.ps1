# One job at a time per script: a slow run is skipped over, never stacked up.
New-PSUScript -Name 'Scripts/Sync-DebugLogs.ps1' -Path 'Scripts/Sync-DebugLogs.ps1' -ConcurrentJobs 1 -TimeOut 30 -MaxHistory 500 `
    -Description 'Reads new lmgrd debug-log lines for every enabled server.'
New-PSUScript -Name 'Scripts/Sync-LiveStatus.ps1' -Path 'Scripts/Sync-LiveStatus.ps1' -ConcurrentJobs 1 -TimeOut 30 -MaxHistory 500 `
    -Description 'Polls every enabled server with lmstat: live usage, seat limits, up/down.'
# No time limit: a big log can take a while, and a second run carries on from where this one stopped.
New-PSUScript -Name 'Scripts/Import-DebugLog.ps1' -Path 'Scripts/Import-DebugLog.ps1' -ConcurrentJobs 1 -MaxHistory 100 `
    -Description 'Imports an existing debug log file as a server''s usage history.'
New-PSUScript -Name 'Scripts/Initialize-Database.ps1' -Path 'Scripts/Initialize-Database.ps1' -ConcurrentJobs 1 -TimeOut 5 `
    -Description 'Creates or upgrades the Fathom tables. Run after installing or updating.'
New-PSUScript -Name 'Scripts/Send-Alerts.ps1' -Path 'Scripts/Send-Alerts.ps1' -ConcurrentJobs 1 -TimeOut 10 -MaxHistory 500 `
    -Description 'Records current alerts and mails a digest. Sends nothing until alerts are enabled.'
New-PSUScript -Name 'Scripts/Sync-Directory.ps1' -Path 'Scripts/Sync-Directory.ps1' -ConcurrentJobs 1 -TimeOut 30 -MaxHistory 200 `
    -Description 'Looks up seen users and hosts in Active Directory. Does nothing until directory lookups are on.'

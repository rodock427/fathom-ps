New-PSUSchedule -Name 'Fathom: read debug logs' -Script 'Scripts/Sync-DebugLogs.ps1' -Cron '* * * * *'
New-PSUSchedule -Name 'Fathom: poll lmstat' -Script 'Scripts/Sync-LiveStatus.ps1' -Cron '*/5 * * * *'

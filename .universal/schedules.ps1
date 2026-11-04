New-PSUSchedule -Name 'Fathom: read debug logs' -Script 'Scripts/Sync-DebugLogs.ps1' -Cron '* * * * *'
New-PSUSchedule -Name 'Fathom: poll lmstat' -Script 'Scripts/Sync-LiveStatus.ps1' -Cron '*/5 * * * *'
New-PSUSchedule -Name 'Fathom: alerts' -Script 'Scripts/Send-Alerts.ps1' -Cron '2-59/5 * * * *'
New-PSUSchedule -Name 'Fathom: directory' -Script 'Scripts/Sync-Directory.ps1' -Cron '17 * * * *'

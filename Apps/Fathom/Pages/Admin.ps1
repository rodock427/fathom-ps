# Administrators: add, edit and pause monitored servers, poll one now, and the alert settings.
# Every handler checks the tier again: it runs later, on its own request.
. "$PSScriptRoot/../Common.ps1"

if (-not (Test-FathomAccess -Tier Admin -Role $Roles)) {
    return New-FathomNotAuthorized
}

Use-FathomDatabase {
    New-UDTypography -Variant h4 -Text 'Administration' -GutterBottom

    New-UDCard -Title 'Monitored servers' -Content {
        $rows = Get-FathomServer | Sort-Object Name | ForEach-Object {
            [pscustomobject] @{
                ServerId    = $_.ServerId
                Name        = $_.Name
                LicenseSpec = $_.LicenseSpec
                LogPath     = $_.LogPath
                Vendor      = $_.Vendor
                UsageSource = $_.UsageSource
                Enabled     = $_.Enabled
                Status      = if ($_.Enabled) { $_.PollStatus ?? 'Not polled' } else { 'Paused' }
                LastPoll    = Format-FathomTime $_.LastPolled
            }
        }
        $table = @{
            Id      = 'admin-servers'
            Data    = $rows
            Columns = [ordered] @{
                Name        = 'Name'
                ServerId    = 'Id'
                LicenseSpec = 'License server'
                LogPath     = 'Debug log'
                UsageSource = 'Usage from'
                Status      = 'Status'
                LastPoll    = 'Last poll'
                Actions     = ''
            }
            # Runs in PSU's scope (see New-FathomTable): the handlers use only the row and Fathom commands.
            Render  = @{
                Actions = {
                    $server = $EventData
                    New-UDStack -Direction row -Spacing 1 -Children {
                        New-UDButton -Text 'Edit' -Size small -OnClick {
                            Show-UDModal -Header { New-UDTypography -Variant h6 -Text "Edit $($server.Name)" } -Content {
                                # Ids differ from the add form's: one page, one id per input.
                                New-UDForm -Id 'admin-edit-server' -Children {
                                    New-UDTextbox -Id 'editName' -Label 'Name' -Value $server.Name -FullWidth
                                    New-UDTextbox -Id 'editLicenseSpec' -Label 'License server (port@host), blank for none' -Value $server.LicenseSpec -FullWidth
                                    New-UDTextbox -Id 'editLogPath' -Label 'Debug log path, blank for none' -Value $server.LogPath -FullWidth
                                    New-UDTextbox -Id 'editVendor' -Label 'Vendor daemon' -Value $server.Vendor -FullWidth
                                    New-UDSelect -Id 'editUsageSource' -Label 'Usage history from' -DefaultValue ('Auto', 'Log', 'Lmstat' -eq $server.UsageSource)[0] -Option {
                                        New-UDSelectOption -Name 'Auto: the debug log while healthy, else lmstat' -Value 'Auto'
                                        New-UDSelectOption -Name 'The debug log' -Value 'Log'
                                        New-UDSelectOption -Name 'lmstat' -Value 'Lmstat'
                                    }
                                } -OnSubmit {
                                    if (-not (Test-FathomAccess -Tier Admin -Role $Roles)) { throw 'Not authorized.' }
                                    $change = @{
                                        ServerId    = $server.ServerId
                                        LicenseSpec = [string] $EventData.editLicenseSpec
                                        LogPath     = [string] $EventData.editLogPath
                                        Vendor      = [string] $EventData.editVendor
                                        UsageSource = $EventData.editUsageSource
                                    }
                                    if ($EventData.editName) { $change.Name = $EventData.editName }
                                    $null = Use-FathomDatabase { Set-FathomServer @change }
                                    Hide-UDModal
                                    Invoke-UDRedirect -Url 'admin'
                                }
                            }
                        }
                        New-UDButton -Text 'Poll now' -Size small -ShowLoading -Disabled:(-not ($server.Enabled -and $server.LicenseSpec)) -OnClick {
                            if (-not (Test-FathomAccess -Tier Admin -Role $Roles)) { throw 'Not authorized.' }
                            $result = Use-FathomDatabase { Get-FathomServer -ServerId $server.ServerId | Sync-FathomLiveStatus }
                            Show-UDToast -Message "$($server.Name): $($result.Status)"
                            Invoke-UDRedirect -Url 'admin'
                        }
                        New-UDButton -Text ($server.Enabled ? 'Pause' : 'Resume') -Size small -OnClick {
                            if (-not (Test-FathomAccess -Tier Admin -Role $Roles)) { throw 'Not authorized.' }
                            $null = Use-FathomDatabase { Set-FathomServer -ServerId $server.ServerId -Enabled (-not $server.Enabled) }
                            Invoke-UDRedirect -Url 'admin'
                        }
                    }
                }
            }
            Empty   = 'No servers yet. Add one below.'
        }
        New-FathomTable @table
    }

    New-UDCard -Title 'Add a server' -Content {
        New-UDForm -Id 'admin-add-server' -SubmitText 'Add server' -Children {
            New-UDTextbox -Id 'ServerId' -Label 'Id (letters, digits, . _ -; never changes)'
            New-UDTextbox -Id 'Name' -Label 'Name'
            New-UDTextbox -Id 'LicenseSpec' -Label 'License server, e.g. 27000@licsrv01'
            New-UDTextbox -Id 'LogPath' -Label 'Debug log, e.g. \\licsrv01\flexlm$\debug.log'
            New-UDTextbox -Id 'Vendor' -Label 'Vendor daemon'
        } -OnSubmit {
            if (-not (Test-FathomAccess -Tier Admin -Role $Roles)) { throw 'Not authorized.' }
            $server = @{ ServerId = $EventData.ServerId }
            foreach ($field in 'Name', 'LicenseSpec', 'LogPath', 'Vendor') {
                if ($EventData.$field) { $server[$field] = $EventData.$field }
            }
            $null = Use-FathomDatabase { Register-FathomServer @server }
            Show-UDToast -Message "Added $($server.ServerId). It's picked up on the next poll."
            Invoke-UDRedirect -Url 'admin'
        }
    }

    $settings = Get-FathomAlertSetting
    New-UDCard -Title 'Email alerts' -Content {
        New-UDForm -Id 'admin-alerts' -SubmitText 'Save' -Children {
            New-UDSwitch -Id 'Enabled' -Label 'Send alert email' -Checked $settings.Enabled
            New-UDTextbox -Id 'SmtpServer' -Label 'SMTP server' -Value $settings.SmtpServer
            New-UDTextbox -Id 'SmtpPort' -Label 'Port' -Type number -Value $settings.SmtpPort
            New-UDSwitch -Id 'UseSsl' -Label 'STARTTLS' -Checked $settings.UseSsl
            New-UDTextbox -Id 'From' -Label 'From' -Value $settings.From
            New-UDTextbox -Id 'To' -Label 'To (comma-separated)' -Value ($settings.To -join ', ')
            New-UDTextbox -Id 'DownMinutes' -Label 'Report a server down after (minutes)' -Type number -Value $settings.DownMinutes
            New-UDTextbox -Id 'CapacityMinutes' -Label 'Report full capacity after (minutes)' -Type number -Value $settings.CapacityMinutes
            New-UDTextbox -Id 'ExpiryDays' -Label 'Report licenses expiring within (days)' -Type number -Value $settings.ExpiryDays
            New-UDTextbox -Id 'RepeatHours' -Label 'Repeat active alerts every (hours, 0 for never)' -Type number -Value $settings.RepeatHours
        } -OnSubmit {
            if (-not (Test-FathomAccess -Tier Admin -Role $Roles)) { throw 'Not authorized.' }
            $change = @{
                Enabled         = [bool] $EventData.Enabled
                SmtpServer      = [string] $EventData.SmtpServer
                SmtpPort        = [int] $EventData.SmtpPort
                UseSsl          = [bool] $EventData.UseSsl
                From            = [string] $EventData.From
                To              = @(([string] $EventData.To) -split ',' | ForEach-Object Trim | Where-Object { $_ })
                DownMinutes     = [int] $EventData.DownMinutes
                CapacityMinutes = [int] $EventData.CapacityMinutes
                ExpiryDays      = [int] $EventData.ExpiryDays
                RepeatHours     = [int] $EventData.RepeatHours
            }
            $null = Use-FathomDatabase { Set-FathomAlertSetting @change }
            Show-UDToast -Message 'Alert settings saved.'
        }
        New-UDButton -Text 'Send a test message' -Variant outlined -ShowLoading -OnClick {
            if (-not (Test-FathomAccess -Tier Admin -Role $Roles)) { throw 'Not authorized.' }
            # The same optional login the alert schedule uses.
            Use-FathomDatabase { Send-FathomAlert -Test -Credential $FathomSmtpCredential }
            Show-UDToast -Message 'Test message sent.'
        }
    }
    $directory = Get-FathomDirectorySetting
    New-UDCard -Title 'Active Directory' -Content {
        New-UDTypography -Variant body2 -Text (
            'Looks up each FlexLM user and host in Active Directory every hour. Every attribute it returns is listed ' +
            'below: only recorded ones are stored; shown ones appear on a person''s page for license administrators ' +
            'and managers, and those in lists also as columns of who holds a seat. Turning recording off deletes ' +
            'that attribute''s stored values.')
        New-UDForm -Id 'admin-directory' -SubmitText 'Save' -Children {
            New-UDSwitch -Id 'directoryEnabled' -Label 'Look up users and hosts' -Checked $directory.Enabled
            New-UDTextbox -Id 'directoryServer' -Label 'Domain controller or domain (blank for this server''s own)' -Value $directory.Server
            New-UDTextbox -Id 'directoryRefreshHours' -Label 'Look each one up again after (hours)' -Type number -Value $directory.RefreshHours
        } -OnSubmit {
            if (-not (Test-FathomAccess -Tier Admin -Role $Roles)) { throw 'Not authorized.' }
            $change = @{
                Enabled      = [bool] $EventData.directoryEnabled
                Server       = [string] $EventData.directoryServer
                RefreshHours = [int] $EventData.directoryRefreshHours
            }
            $null = Use-FathomDatabase { Set-FathomDirectorySetting @change }
            Show-UDToast -Message 'Directory settings saved.'
        }
        New-UDButton -Text 'Look up now' -Variant outlined -ShowLoading -OnClick {
            if (-not (Test-FathomAccess -Tier Admin -Role $Roles)) { throw 'Not authorized.' }
            # The same optional login the hourly lookup uses.
            $result = Use-FathomDatabase { Sync-FathomDirectory -Credential $FathomDirectoryCredential }
            Show-UDToast -Message "Looked up $($result.Looked): $($result.Found) found, $($result.NotFound) not in the directory, $($result.NewAttributes) new attribute(s)."
            Sync-UDElement -Id 'admin-directory-attributes'
        }

        # Its own region, so a switch refreshes the list (showing records, unrecording hides) in
        # place. It runs on its own request, without this page's helpers: load them again.
        $common = "$PSScriptRoot/../Common.ps1"
        New-UDDynamic -Id 'admin-directory-attributes' -Content {
            if (-not (Test-FathomAccess -Tier Admin -Role $Roles)) { return }
            . $common
            $rows = Use-FathomDatabase { Get-FathomDirectoryAttribute } | ForEach-Object {
                [pscustomobject] @{ Kind = $_.Kind; Name = $_.Name; Recorded = $_.Recorded; Shown = $_.Shown; Listed = $_.Listed }
            }
            # Runs in PSU's scope (see New-FathomTable): the handlers use only the row and Fathom commands.
            $table = @{
                Id      = 'admin-directory-attribute-table'
                Data    = $rows
                Columns = [ordered] @{ Name = 'Attribute'; Kind = 'Of'; Recorded = 'Recorded'; Shown = 'Shown'; Listed = 'In lists' }
                Render  = @{
                    Recorded = { $attribute = $EventData; New-UDSwitch -Checked $attribute.Recorded -OnChange {
                            if (-not (Test-FathomAccess -Tier Admin -Role $Roles)) { throw 'Not authorized.' }
                            $null = Use-FathomDatabase { Set-FathomDirectoryAttribute -Kind $attribute.Kind -Name $attribute.Name -Recorded ($EventData -in $true, 'true') }
                            Sync-UDElement -Id 'admin-directory-attributes'
                        } }
                    Shown    = { $attribute = $EventData; New-UDSwitch -Checked $attribute.Shown -OnChange {
                            if (-not (Test-FathomAccess -Tier Admin -Role $Roles)) { throw 'Not authorized.' }
                            $null = Use-FathomDatabase { Set-FathomDirectoryAttribute -Kind $attribute.Kind -Name $attribute.Name -Shown ($EventData -in $true, 'true') }
                            Sync-UDElement -Id 'admin-directory-attributes'
                        } }
                    Listed   = { $attribute = $EventData; New-UDSwitch -Checked $attribute.Listed -OnChange {
                            if (-not (Test-FathomAccess -Tier Admin -Role $Roles)) { throw 'Not authorized.' }
                            $null = Use-FathomDatabase { Set-FathomDirectoryAttribute -Kind $attribute.Kind -Name $attribute.Name -Listed ($EventData -in $true, 'true') }
                            Sync-UDElement -Id 'admin-directory-attributes'
                        } }
                }
                Empty   = 'No attributes yet: turn lookups on, save, then Look up now.'
            }
            New-FathomTable @table
        }
    }
}

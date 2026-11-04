function Set-FathomAlertSetting {
    <#
    .SYNOPSIS
        Changes the alert settings. Only the parameters you pass change.
    .EXAMPLE
        Set-FathomAlertSetting -SmtpServer smtp.corp.example -From fathom@corp.example -To licensing@corp.example
    .EXAMPLE
        Set-FathomAlertSetting -Enabled $true
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('Fathom.AlertSetting')]
    param(
        # Off by default: alerts are evaluated and recorded, but no mail goes out.
        [bool] $Enabled,

        [AllowEmptyString()]
        [string] $SmtpServer,

        [ValidateRange(1, 65535)]
        [int] $SmtpPort,

        [bool] $UseSsl,

        [AllowEmptyString()]
        [string] $From,

        [AllowEmptyCollection()]
        [string[]] $To,

        # Testing only: write each message as an .eml file here instead of sending it.
        [AllowEmptyString()]
        [string] $PickupDirectory,

        # A server or vendor daemon must be down this long before it's reported.
        [ValidateRange(0, 1440)]
        [int] $DownMinutes,

        # A feature must be fully used this long before it's reported.
        [ValidateRange(0, 10080)]
        [int] $CapacityMinutes,

        # Licenses expiring within this many days are reported.
        [ValidateRange(0, 365)]
        [int] $ExpiryDays,

        # Alerts still active are mailed again after this many hours. 0 never repeats.
        [ValidateRange(0, 720)]
        [int] $RepeatHours
    )

    # Reject a bad address now rather than at 3 a.m. when the first alert fails to send.
    foreach ($address in @($From) + $To | Where-Object { $_ }) {
        try {
            $null = [System.Net.Mail.MailAddress]::new($address)
        } catch {
            throw "'$address' isn't a valid email address."
        }
    }

    $columns = [ordered] @{
        Enabled         = 'enabled'
        SmtpServer      = 'smtp_server'
        SmtpPort        = 'smtp_port'
        UseSsl          = 'use_ssl'
        From            = 'mail_from'
        To              = 'mail_to'
        PickupDirectory = 'pickup_directory'
        DownMinutes     = 'down_minutes'
        CapacityMinutes = 'capacity_minutes'
        ExpiryDays      = 'expiry_days'
        RepeatHours     = 'repeat_hours'
    }

    $assignments = [System.Collections.Generic.List[string]]::new()
    $parameters = @{ updated_at = Get-Date | ConvertTo-FathomSqlTime }
    foreach ($name in $columns.Keys) {
        if ($PSBoundParameters.ContainsKey($name)) {
            $column = $columns[$name]
            $value = $PSBoundParameters[$name]
            $assignments.Add("$column = @$column")
            $parameters[$column] = if ($name -eq 'To') {
                if ($value) { $value -join ',' } else { [DBNull]::Value }
            } elseif ($value -is [string] -and -not $value) {
                [DBNull]::Value
            } else {
                $value
            }
        }
    }

    if (-not $assignments.Count) {
        throw 'Nothing to change: pass at least one setting.'
    }
    if ($PSCmdlet.ShouldProcess('Fathom alert settings', "Set $($assignments -join ', ')")) {
        # Column names come from the fixed map above, never from input; values are parameters.
        $query = "UPDATE alert_settings SET $($assignments -join ', '), updated_at = @updated_at::timestamp WHERE id = 1"
        $null = Invoke-FathomSql -Query $query -Parameters $parameters
    }

    Get-FathomAlertSetting
}

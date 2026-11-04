function Get-FathomAlertSetting {
    <#
    .SYNOPSIS
        The alert settings: whether mail is sent, where to, and each rule's threshold.
    #>
    [CmdletBinding()]
    [OutputType('Fathom.AlertSetting')]
    param()

    $row = Invoke-FathomQuery -Query 'SELECT * FROM alert_settings WHERE id = 1'
    [pscustomobject] @{
        PSTypeName      = 'Fathom.AlertSetting'
        Enabled         = $row.enabled
        SmtpServer      = $row.smtp_server
        SmtpPort        = $row.smtp_port
        UseSsl          = $row.use_ssl
        From            = $row.mail_from
        To              = if ($row.mail_to) { @($row.mail_to -split ',') } else { @() }
        PickupDirectory = $row.pickup_directory
        DownMinutes     = $row.down_minutes
        CapacityMinutes = $row.capacity_minutes
        ExpiryDays      = $row.expiry_days
        RepeatHours     = $row.repeat_hours
        UpdatedAt       = $row.updated_at
    }
}

function Send-FathomMail {
    <#
    .SYNOPSIS
        Sends one plain-text message using the alert settings' SMTP server (or pickup folder).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSTypeName('Fathom.AlertSetting')] $Settings,
        [Parameter(Mandatory)] [string] $Subject,
        [Parameter(Mandatory)] [string] $Body,
        [pscredential] $Credential
    )

    if (-not ($Settings.SmtpServer -or $Settings.PickupDirectory) -or -not $Settings.From -or -not $Settings.To) {
        throw 'Alert mail needs an SMTP server, a From address and at least one To address: see Set-FathomAlertSetting.'
    }

    $message = [System.Net.Mail.MailMessage]::new()
    # ponytail: .NET's SmtpClient covers an internal relay (plain, STARTTLS, basic auth). Move to MailKit if OAuth or a picky server is needed.
    $client = [System.Net.Mail.SmtpClient]::new()
    try {
        $message.From = $Settings.From
        foreach ($address in $Settings.To) {
            $message.To.Add($address)
        }
        $message.Subject = $Subject
        $message.Body = $Body

        if ($Settings.PickupDirectory) {
            $client.DeliveryMethod = [System.Net.Mail.SmtpDeliveryMethod]::SpecifiedPickupDirectory
            $client.PickupDirectoryLocation = $Settings.PickupDirectory
        } else {
            $client.Host = $Settings.SmtpServer
            $client.Port = $Settings.SmtpPort
            $client.EnableSsl = $Settings.UseSsl
            if ($Credential) {
                $client.Credentials = $Credential.GetNetworkCredential()
            }
        }

        $client.Send($message)
    } finally {
        $message.Dispose()
        $client.Dispose()
    }
}

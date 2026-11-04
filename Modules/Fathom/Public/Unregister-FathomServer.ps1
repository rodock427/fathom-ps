function Unregister-FathomServer {
    <#
    .SYNOPSIS
        Stops monitoring a license server. Its usage history is kept.
    .EXAMPLE
        Unregister-FathomServer -ServerId licsrv01
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [string] $ServerId
    )

    process {
        if (-not $PSCmdlet.ShouldProcess($ServerId, 'Unregister license server')) {
            return
        }

        # Read positions go too, so re-registering re-reads the log. Event ids make that harmless.
        $query = @'
DELETE FROM _ingest_manifest WHERE starts_with(file_key, 'psu:' || @server_id || ':');
DELETE FROM log_coverage WHERE server_id = @server_id;
DELETE FROM monitored_servers WHERE server_id = @server_id;
'@
        $null = Invoke-SqlUpdate -ConnectionName $script:ConnectionName -Query $query -Parameters @{ server_id = $ServerId }
    }
}

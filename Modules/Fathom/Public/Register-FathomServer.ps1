function Register-FathomServer {
    <#
    .SYNOPSIS
        Adds a FlexLM license server to monitor, by lmstat (port@host), debug log path, or both.
    .EXAMPLE
        Register-FathomServer -ServerId licsrv01 -LicenseSpec 27000@licsrv01 -LogPath '\\licsrv01\flexlm$\debug.log'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('Fathom.Server')]
    param(
        # Stable id that every usage event is stored under. Letters, digits, '.', '_' and '-'.
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')]
        [string] $ServerId,

        # Display name. Defaults to the id.
        [ValidateNotNullOrEmpty()]
        [string] $Name = $ServerId,

        # What lmutil -c is given, e.g. 27000@licsrv01 (or a redundant triad list).
        [ValidateNotNullOrEmpty()]
        [string] $LicenseSpec,

        # The lmgrd debug log, usually a UNC path the PSU service account can read.
        [ValidateNotNullOrEmpty()]
        [string] $LogPath,

        [ValidateNotNullOrEmpty()]
        [string] $Vendor
    )

    if (-not ($LicenseSpec -or $LogPath)) {
        throw 'Give -LicenseSpec, -LogPath, or both; otherwise there is nothing to monitor.'
    }

    if (-not $PSCmdlet.ShouldProcess($ServerId, 'Register license server')) {
        return
    }

    $query = @'
INSERT INTO monitored_servers (server_id, name, license_spec, log_path, vendor, created_at)
VALUES (@server_id, @name, @license_spec, @log_path, @vendor, @created_at::timestamp)
ON CONFLICT (server_id) DO NOTHING
'@
    $parameters = @{
        server_id    = $ServerId
        name         = $Name
        license_spec = if ($LicenseSpec) { $LicenseSpec } else { [DBNull]::Value }
        log_path     = if ($LogPath) { $LogPath } else { [DBNull]::Value }
        vendor       = if ($Vendor) { $Vendor } else { [DBNull]::Value }
        # Local clock, consistent with every other timestamp Fathom stores.
        created_at   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }

    if ((Invoke-FathomSql -Query $query -Parameters $parameters) -eq 0) {
        throw "Server '$ServerId' is already registered."
    }

    Get-FathomServer -ServerId $ServerId
}

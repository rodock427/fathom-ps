function Set-FathomServer {
    <#
    .SYNOPSIS
        Changes a monitored server's settings: name, sources, usage source, or whether it's monitored.
    .DESCRIPTION
        Only the parameters you pass change. Pass an empty string to -LicenseSpec or -LogPath to
        stop using that source; a server must keep at least one.
    .EXAMPLE
        Set-FathomServer -ServerId licsrv01 -UsageSource Lmstat
    .EXAMPLE
        Set-FathomServer -ServerId licsrv01 -Enabled $false
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('Fathom.Server')]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [string] $ServerId,

        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [AllowEmptyString()]
        [string] $LicenseSpec,

        [AllowEmptyString()]
        [string] $LogPath,

        [AllowEmptyString()]
        [string] $Vendor,

        [bool] $Enabled,

        # What drives usage history. Auto: the debug log while it's healthy, lmstat otherwise.
        [ValidateSet('Auto', 'Log', 'Lmstat')]
        [string] $UsageSource
    )

    process {
        $columns = @{
            Name        = 'name'
            LicenseSpec = 'license_spec'
            LogPath     = 'log_path'
            Vendor      = 'vendor'
            Enabled     = 'enabled'
            UsageSource = 'usage_source'
        }

        $assignments = [System.Collections.Generic.List[string]]::new()
        $parameters = @{ server_id = $ServerId }
        foreach ($name in $columns.Keys) {
            if ($PSBoundParameters.ContainsKey($name)) {
                $value = $PSBoundParameters[$name]
                $column = $columns[$name]
                $assignments.Add("$column = @$column")
                # Empty clears a text setting; usage_source is stored lower case.
                $parameters[$column] = if ($name -eq 'UsageSource') {
                    $value.ToLowerInvariant()
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
        if (-not $PSCmdlet.ShouldProcess($ServerId, "Set $($assignments -join ', ')")) {
            return
        }

        # Column names come from the fixed map above, never from input; values are parameters.
        $query = "UPDATE monitored_servers SET $($assignments -join ', ') WHERE server_id = @server_id"
        try {
            $updated = Invoke-FathomSql -Query $query -Parameters $parameters
        } catch {
            # 23514 is Postgres's check_violation: both sources cleared.
            if ($_.Exception.Message -match '23514') {
                throw "Server '$ServerId' needs a license spec or a log path; it can't have neither."
            }
            throw
        }
        if ($updated -eq 0) {
            throw "Server '$ServerId' isn't registered."
        }

        Get-FathomServer -ServerId $ServerId
    }
}

function Get-FathomDefaultDsn {
    <#
    .SYNOPSIS
        The DSN to use when none is given: PSU's FathomDsn secret if there is one, else LM_POSTGRES_DSN.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    # PSU serves secrets through a Secret: drive (what $Secret:Name reads) in every job, app page
    # and event handler. The Universal module adds the drive outside PSU too, where reading throws.
    try {
        $secret = Get-Content -LiteralPath 'Secret:FathomDsn' -ErrorAction Stop | Select-Object -First 1
    } catch {
        $secret = $null
    }
    $secret ?? $env:LM_POSTGRES_DSN
}

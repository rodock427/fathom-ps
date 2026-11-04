function Initialize-FathomSchema {
    <#
    .SYNOPSIS
        Creates any missing Fathom tables. Safe to run repeatedly, and alongside the Python Fathom.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $ddl = Get-Content -Raw -LiteralPath (Join-Path -Path $script:SqlPath -ChildPath 'schema.sql')

    if ($PSCmdlet.ShouldProcess('Fathom database', 'Create missing tables')) {
        $null = Invoke-SqlUpdate -ConnectionName $script:ConnectionName -Query $ddl
    }
}

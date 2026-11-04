# Helpers for the pages. Each page dot-sources this file, so they exist only while it renders.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions', '', Justification = 'New-* here builds UI components; nothing changes.')]
param()

function Format-FathomTime {
    <#
    .SYNOPSIS
        A timestamp as the pages show it, or nothing for no value.
    #>
    param([Nullable[datetime]] $Value)

    if ($Value) {
        $Value.ToString('yyyy-MM-dd HH:mm')
    }
}

function New-FathomTable {
    <#
    .SYNOPSIS
        A sortable table of already-shaped rows, or a line of text when there are none.
    .DESCRIPTION
        PSU sends every property of every row to the browser, so pass only what the user may see.
    #>
    param(
        [Parameter(Mandatory)] [string] $Id,
        [AllowNull()] [object[]] $Data,
        # Property name to column title, in display order.
        [Parameter(Mandatory)] [System.Collections.Specialized.OrderedDictionary] $Columns,
        # Property name to an OnRender script block; the row is in $EventData. These run in PSU's own
        # scope: use only UD cmdlets, Fathom commands and the row's own fields.
        [hashtable] $Render = @{},
        [string] $Empty = 'Nothing to show.',
        [switch] $ShowExport
    )

    if (-not $Data) {
        return New-UDTypography -Id $Id -Variant body2 -Text $Empty
    }

    $tableColumns = foreach ($property in $Columns.Keys) {
        $column = @{ Property = $property; Title = $Columns[$property]; ShowSort = $true; IncludeInExport = $true; IncludeInSearch = $true }
        if ($Render[$property]) {
            $column.OnRender = $Render[$property]
        }
        New-UDTableColumn @column
    }
    $table = @{
        Id         = $Id
        Data       = $Data
        Columns    = $tableColumns
        ShowSort   = $true
        Dense      = $true
        PageSize   = 25
        ShowExport = $ShowExport
    }
    if ($Data.Count -gt 25) {
        $table.ShowPagination = $true
        $table.ShowSearch = $true
    }
    New-UDTable @table
}

function Get-FathomStatusColor {
    <#
    .SYNOPSIS
        The chip colour for a server status. Table OnRender blocks can't see page helpers, so rows carry it.
    #>
    param([string] $Status)

    # Health statuses (Get-FathomServerHealth) and lmstat poll statuses.
    switch ($Status) {
        { $_ -in 'Healthy', 'Up' } { 'success' }
        { $_ -in 'Degraded', 'Stale', 'Drifted' } { 'warning' }
        { $_ -in 'Down', 'Timeout' } { 'error' }
        default { 'default' }
    }
}

function New-FathomRangePicker {
    <#
    .SYNOPSIS
        Buttons that reload the page for another number of days, keeping the rest of the query.
    #>
    param(
        [Parameter(Mandatory)] [int[]] $Days,
        [Parameter(Mandatory)] [int] $Selected,
        [Parameter(Mandatory)] [string] $Page,
        [hashtable] $Query = @{}
    )

    $buttons = foreach ($option in $Days) {
        $parameters = $Query.Clone()
        $parameters.days = $option
        $queryString = ($parameters.GetEnumerator() | Where-Object Value | ForEach-Object {
                '{0}={1}' -f $_.Key, [uri]::EscapeDataString([string] $_.Value)
            }) -join '&'
        $label = if ($option -eq 1) { '24 hours' } else { "$option days" }
        $variant = if ($option -eq $Selected) { 'contained' } else { 'outlined' }
        New-UDButton -Text $label -Variant $variant -Size small -Href "$Page`?$queryString"
    }
    New-UDStack -Direction row -Spacing 1 -Children { $buttons }
}

function Get-FathomQueryRange {
    <#
    .SYNOPSIS
        The ?days= value from the query string if it's one of the offered ranges, else the default.
    #>
    param(
        [AllowNull()] [string] $Value,
        [Parameter(Mandatory)] [int[]] $Days,
        [Parameter(Mandatory)] [int] $Default
    )

    if ($Value -in $Days) { [int] $Value } else { $Default }
}

function New-FathomNotAuthorized {
    <#
    .SYNOPSIS
        What a page shows a user below its tier, whatever PSU's page roles allowed through.
    #>
    New-UDAlert -Id 'not-authorized' -Severity info -Text 'You do not have access to this page. Ask a license administrator.'
}

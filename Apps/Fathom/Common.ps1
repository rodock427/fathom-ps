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

function Format-FathomDirectoryValue {
    <#
    .SYNOPSIS
        A directory attribute value as one line of text: a distinguished name as its name, a list joined.
    #>
    param([AllowNull()] $Value)

    $parts = foreach ($item in @($Value)) {
        if ($item -is [datetime]) {
            Format-FathomTime $item
        } elseif ($item -is [string] -and $item -match '^CN=((?:\\,|[^,])+),') {
            $Matches[1] -replace '\\,', ','
        } else {
            [string] $item
        }
    }
    $parts -join '; '
}

function Add-FathomDirectoryColumn {
    <#
    .SYNOPSIS
        Adds the shown directory attributes of each row's user and host as extra properties and columns.
    .DESCRIPTION
        Rows need User and Host properties. Columns is changed in place. Individual data: call it
        only on pages for the Operator tier.
    #>
    param(
        [AllowNull()] [object[]] $Rows,
        [Parameter(Mandatory)] [System.Collections.Specialized.OrderedDictionary] $Columns
    )

    if (-not $Rows) {
        return $Rows
    }
    foreach ($kind in 'user', 'computer') {
        $source = if ($kind -eq 'user') { 'User' } else { 'Host' }
        $objects = @{}
        Get-FathomDirectoryObject -Kind $kind -Name @($Rows.$source) | ForEach-Object { $objects[$_.Name] = $_.Attributes }
        $attributes = @(Get-FathomDirectoryAttribute -Kind $kind | Where-Object Shown).Name
        $index = 0
        foreach ($attribute in $attributes) {
            # Plain property names: PSU puts them in the page as JSON field names.
            $property = "${kind}Attribute$index"
            $Columns[$property] = if ($kind -eq 'user') { $attribute } else { "Host $attribute" }
            foreach ($row in $Rows) {
                # Keyed as the directory tables key names: lower case, a host without its domain.
                $key = ([string] $row.$source).ToLowerInvariant()
                if ($kind -eq 'computer') { $key = $key.Split('.')[0] }
                $values = $objects[$key]
                $text = if ($values -and $values.Contains($attribute)) { Format-FathomDirectoryValue $values[$attribute] }
                $row | Add-Member -NotePropertyName $property -NotePropertyValue $text
            }
            $index++
        }
    }
    $Rows
}

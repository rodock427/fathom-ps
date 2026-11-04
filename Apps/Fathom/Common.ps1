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
    # A fixed height with the header kept in view: long lists scroll inside their card.
    $table = @{
        Id           = $Id
        Data         = $Data
        Columns      = $tableColumns
        ShowSort     = $true
        Dense        = $true
        PageSize     = 25
        ShowExport   = $ShowExport
        StickyHeader = $true
        MaxHeight    = 520
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

function Get-FathomTimeframe {
    <#
    .SYNOPSIS
        The page's time window, from the query string: ?from=&to= (a custom range), else ?days=
        (a preset), else the default number of days.
    .DESCRIPTION
        Also picks the chart bucket size and time label format for the window's length, so a chart
        has roughly 100 to 400 points whatever the window.
    #>
    param(
        [hashtable] $Query = @{},
        [Parameter(Mandatory)] [int[]] $Presets,
        [Parameter(Mandatory)] [int] $DefaultDays
    )

    $now = Get-Date
    $from = [datetime]::MinValue
    $to = [datetime]::MinValue
    $style = [Globalization.DateTimeStyles]::None
    $culture = [cultureinfo]::InvariantCulture
    $custom = $false
    if ($Query.from -and $Query.to) {
        $parsed = [datetime]::TryParse([string] $Query.from, $culture, $style, [ref] $from) -and
        [datetime]::TryParse([string] $Query.to, $culture, $style, [ref] $to)
        $custom = $parsed -and $from -lt $to
    }
    if ($custom) {
        if ($to -gt $now) { $to = $now }
        $days = $null
    } else {
        $days = if ($Query.days -in $Presets) { [int] $Query.days } else { $DefaultDays }
        $from = $now.AddDays(-$days)
        $to = $now
    }

    $hours = ($to - $from).TotalHours
    $bucket = switch ($hours) {
        { $_ -le 6 } { 5; break }
        { $_ -le 24 } { 15; break }
        { $_ -le 24 * 7 } { 60; break }
        { $_ -le 24 * 31 } { 240; break }
        { $_ -le 24 * 92 } { 720; break }
        default { 1440 }
    }
    $label = if ($custom) {
        '{0} to {1}' -f (Format-FathomTime $from), (Format-FathomTime $to)
    } elseif ($days -eq 1) {
        'the last 24 hours'
    } else {
        "the last $days days"
    }
    [pscustomobject] @{
        From          = $from
        To            = $to
        Days          = $days
        Custom        = [bool] $custom
        Label         = $label
        BucketMinutes = $bucket
        LabelFormat   = if ($hours -le 48) { 'MM-dd HH:mm' } else { 'MM-dd' }
        Query         = if ($custom) { @{ from = $from.ToString('s'); to = $to.ToString('s') } } else { @{ days = $days } }
    }
}

function ConvertTo-FathomQueryString {
    <#
    .SYNOPSIS
        A query string from a hashtable, leaving out empty values.
    #>
    param([hashtable] $Query = @{})

    ($Query.GetEnumerator() | Where-Object { $null -ne $_.Value -and '' -ne $_.Value } | Sort-Object Key | ForEach-Object {
        '{0}={1}' -f $_.Key, [uri]::EscapeDataString([string] $_.Value)
    }) -join '&'
}

function New-FathomTimeframePicker {
    <#
    .SYNOPSIS
        Preset buttons and a custom From/To range, each reloading the page with the rest of its query kept.
    #>
    param(
        [Parameter(Mandatory)] $Timeframe,
        [Parameter(Mandatory)] [int[]] $Presets,
        [Parameter(Mandatory)] [string] $Page,
        # The page's other query values (server id, user...), kept across a change of window.
        [hashtable] $Keep = @{}
    )

    $buttons = foreach ($option in $Presets) {
        $label = if ($option -eq 1) { '24 hours' } elseif ($option -eq 365) { '1 year' } else { "$option days" }
        $variant = if (-not $Timeframe.Custom -and $option -eq $Timeframe.Days) { 'contained' } else { 'outlined' }
        New-UDButton -Text $label -Variant $variant -Size small -Href "$Page`?$(ConvertTo-FathomQueryString ($Keep + @{ days = $option }))"
    }
    $customVariant = if ($Timeframe.Custom) { 'contained' } else { 'outlined' }
    $base = "$Page`?$(ConvertTo-FathomQueryString $Keep)"
    $from = $Timeframe.From
    $to = $Timeframe.To

    New-UDStack -Direction row -Spacing 1 -AlignItems center -Children {
        $buttons
        New-UDButton -Text 'Custom range' -Variant $customVariant -Size small -OnClick {
            Show-UDModal -Header { New-UDTypography -Variant h6 -Text 'Custom range' } -Content {
                New-UDForm -Id 'timeframe-custom' -SubmitText 'Show' -Children {
                    New-UDDatePicker -Id 'timeframeFrom' -Label 'From' -ShowTime -Format 'YYYY-MM-DD HH:mm' -Value $from
                    New-UDDatePicker -Id 'timeframeTo' -Label 'To' -ShowTime -Format 'YYYY-MM-DD HH:mm' -Value $to
                } -OnSubmit {
                    # The pickers send ISO 8601, in UTC or with no zone: either way, back to local time.
                    $start = [DateTimeOffset]::Parse([string] $EventData.timeframeFrom).LocalDateTime.ToString('yyyy-MM-ddTHH:mm:00')
                    $end = [DateTimeOffset]::Parse([string] $EventData.timeframeTo).LocalDateTime.ToString('yyyy-MM-ddTHH:mm:00')
                    Hide-UDModal
                    Invoke-UDRedirect -Url ('{0}{1}from={2}&to={3}' -f $base, ($base.EndsWith('?') ? '' : '&'), $start, $end)
                }
            }
        }
        New-UDTypography -Variant body2 -Text "Showing $($Timeframe.Label)"
    }
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
        Adds the directory attributes chosen for lists, of each row's user and host, as extra properties and columns.
    .DESCRIPTION
        Rows need User and Host properties, and get a UserLabel: the display name with the username. Columns is changed in place. Individual data: call it
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
        $catalog = @(Get-FathomDirectoryAttribute -Kind $kind)
        # Only the attributes chosen for lists get a column; the profile page has the rest.
        $attributes = @($catalog | Where-Object { $_.Listed -and $_.Name -ne 'DisplayName' }).Name
        if ($kind -eq 'user') {
            # A shown display name goes with the username (UserLabel), not in a column of its own.
            $showName = [bool] ($catalog | Where-Object { $_.Name -eq 'DisplayName' -and $_.Shown })
            foreach ($row in $Rows) {
                $values = $objects[([string] $row.User).ToLowerInvariant()]
                $label = if ($showName -and $values.DisplayName) { "$($values.DisplayName) ($($row.User))" } else { $row.User }
                $row | Add-Member -NotePropertyName UserLabel -NotePropertyValue $label -Force
            }
        }
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

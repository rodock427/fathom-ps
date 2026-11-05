function Get-FathomReportCatalog {
    <#
    .SYNOPSIS
        The standard reports and the options each one takes. The Reports pages are built from this list.
    .DESCRIPTION
        Presets are the period buttons a report offers; a report without them looks at right now.
        An option's Kind is Server, Feature, Features (several), Number or Choice.
    .EXAMPLE
        Get-FathomReportCatalog | Select-Object Name, Title
    #>
    [CmdletBinding()]
    [OutputType('Fathom.ReportDefinition')]
    param(
        # One report by name. All of them when omitted.
        [string] $Name
    )

    $server = @{ Name = 'server'; Label = 'Server'; Kind = 'Server' }
    $feature = @{ Name = 'feature'; Label = 'Feature (blank for all)'; Kind = 'Feature' }
    $reports = @(
        @{
            Name        = 'seat-planning'
            Title       = 'Seat planning'
            Icon        = 'chart-line'
            Description = 'Too many seats or too few, per feature. Typical is the 95th percentile of seats in use. Denials need a debug log.'
            Presets     = 30, 90, 365
            DefaultDays = 90
            Empty       = 'No usage recorded in this period.'
            Options     = @(
                $server
                @{ Name = 'underused'; Label = 'Underused when the peak stays below (% of seats)'; Kind = 'Number'; Default = 50; Minimum = 1; Maximum = 100 }
            )
        }
        @{
            Name        = 'usage-history'
            Title       = 'Usage history'
            Icon        = 'chart-area'
            Description = 'Peak seats in use against seats over time. The Excel export charts each feature.'
            Presets     = 1, 7, 30, 90, 365
            DefaultDays = 30
            Empty       = 'No usage recorded in this period.'
            Options     = @(
                $server
                @{ Name = 'features'; Label = 'Features (blank for the busiest)'; Kind = 'Features' }
                @{ Name = 'top'; Label = 'Busiest features per server'; Kind = 'Number'; Default = 8; Minimum = 1; Maximum = 50 }
                @{
                    Name    = 'step'
                    Label   = 'Time step'
                    Kind    = 'Choice'
                    Default = 'auto'
                    Choices = [ordered] @{ auto = 'Suit the period'; '5' = '5 minutes'; '15' = '15 minutes'; '60' = '1 hour'; '240' = '4 hours'; '1440' = '1 day' }
                }
            )
        }
        @{
            Name        = 'denials'
            Title       = 'Denials'
            Icon        = 'ban'
            Description = 'Checkouts the license server turned away. These need a debug log.'
            Presets     = 7, 30, 90, 365
            DefaultDays = 30
            Empty       = 'No denials in this period.'
            Options     = @(
                $server
                $feature
                @{
                    Name    = 'group'
                    Label   = 'Show'
                    Kind    = 'Choice'
                    Default = 'feature'
                    Choices = [ordered] @{ event = 'Every denial'; feature = 'By feature'; user = 'By user' }
                }
            )
        }
        @{
            Name        = 'top-users'
            Title       = 'Top users'
            Icon        = 'users'
            Description = 'Who held licenses the longest, counting every username a person has used.'
            Presets     = 7, 30, 90, 365
            DefaultDays = 30
            Empty       = 'No usage recorded in this period.'
            Options     = @(
                $server
                $feature
                @{ Name = 'top'; Label = 'How many people'; Kind = 'Number'; Default = 25; Minimum = 1; Maximum = 1000 }
            )
        }
        @{
            Name        = 'expiring'
            Title       = 'Expiring licenses'
            Icon        = 'calendar'
            Description = 'Features that expire soon, soonest first.'
            Empty       = 'Nothing expires in this time.'
            Options     = @(
                $server
                @{ Name = 'days'; Label = 'Days ahead'; Kind = 'Number'; Default = 90; Minimum = 0; Maximum = 3650 }
                @{
                    Name    = 'expired'
                    Label   = 'Already expired'
                    Kind    = 'Choice'
                    Default = 'hide'
                    Choices = [ordered] @{ hide = 'Leave out'; show = 'Include' }
                }
            )
        }
        @{
            Name        = 'uptime'
            Title       = 'Server uptime'
            Icon        = 'server'
            Description = 'The share of lmstat polls that found each server up. Servers with no polls are left out.'
            Presets     = 7, 30, 90, 365
            DefaultDays = 30
            Empty       = 'No polls in this period.'
            Options     = @($server)
        }
        @{
            Name        = 'seat-holders'
            Title       = 'Current seat holders'
            Icon        = 'user-clock'
            Description = 'Who holds a seat as of the latest lmstat poll, longest first.'
            Empty       = 'Nobody matches right now.'
            Options     = @(
                $server
                $feature
                @{ Name = 'hours'; Label = 'Held at least (hours)'; Kind = 'Number'; Default = 0; Minimum = 0; Maximum = 8760 }
            )
        }
    )

    foreach ($report in $reports | Where-Object { -not $Name -or $_.Name -eq $Name }) {
        [pscustomobject] ($report + @{ PSTypeName = 'Fathom.ReportDefinition' })
    }
}

function Set-FathomDirectoryAttribute {
    <#
    .SYNOPSIS
        Chooses whether a directory attribute is recorded, shown, and a column in lists of people.
    .DESCRIPTION
        Each needs the one before: listing an attribute shows it, showing records it. Turning one
        off turns off those that need it. Stopping recording deletes its stored values at once,
        history included. Starting recording makes every user or host of that kind due,
        so the next lookup (hourly, or Sync-FathomDirectory) fills it in.
    .EXAMPLE
        Set-FathomDirectoryAttribute -Kind user -Name EmployeeID -Recorded $false
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('Fathom.DirectoryAttribute')]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [ValidateSet('user', 'computer')]
        [string] $Kind,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [string] $Name,

        [bool] $Recorded,

        [bool] $Shown,

        # A column in lists of people (who holds a seat now), not only on a person's own page.
        [bool] $Listed
    )

    process {
        $current = Get-FathomDirectoryAttribute -Kind $Kind | Where-Object Name -EQ $Name
        if (-not $current) {
            throw "The directory hasn't returned a $Kind attribute named '$Name'."
        }
        $recordedNow = if ($PSBoundParameters.ContainsKey('Recorded')) { $Recorded } else { $current.Recorded }
        $shownNow = if ($PSBoundParameters.ContainsKey('Shown')) { $Shown } else { $current.Shown }
        $listedNow = if ($PSBoundParameters.ContainsKey('Listed')) { $Listed } else { $current.Listed }
        # Off cascades down to what needs it; on cascades up to what it needs.
        if ($PSBoundParameters.ContainsKey('Recorded') -and -not $Recorded) {
            $shownNow = $false
            $listedNow = $false
        }
        if ($PSBoundParameters.ContainsKey('Shown') -and -not $Shown) {
            $listedNow = $false
        }
        if ($listedNow) { $shownNow = $true }
        if ($shownNow) { $recordedNow = $true }

        if ($PSCmdlet.ShouldProcess("$Kind attribute $Name", "Recorded: $recordedNow, shown: $shownNow, in lists: $listedNow")) {
            $parameters = @{
                kind     = $Kind
                name     = $Name
                recorded = $recordedNow
                shown    = $shownNow
                listed   = $listedNow
                newly    = $recordedNow -and -not $current.Recorded
            }
            $update = @'
UPDATE ad_attributes SET recorded = @recorded, shown = @shown, listed = @listed WHERE kind = @kind AND name = @name;
UPDATE ad_objects SET attributes = attributes - @name WHERE kind = @kind AND NOT @recorded;
UPDATE ad_history SET attributes = attributes - @name WHERE kind = @kind AND NOT @recorded;
UPDATE ad_objects SET fetched_at = '-infinity' WHERE kind = @kind AND @newly;
'@
            $null = Invoke-FathomSql -Query $update -Parameters $parameters
        }
        Get-FathomDirectoryAttribute -Kind $Kind | Where-Object Name -EQ $Name
    }
}

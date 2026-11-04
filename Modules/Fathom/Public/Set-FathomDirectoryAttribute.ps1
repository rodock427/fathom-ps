function Set-FathomDirectoryAttribute {
    <#
    .SYNOPSIS
        Chooses whether a directory attribute is recorded and shown.
    .DESCRIPTION
        Showing an attribute records it too. Stopping recording also stops showing it and deletes
        its stored values at once. Starting recording makes every user or host of that kind due,
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

        [bool] $Shown
    )

    process {
        $current = Get-FathomDirectoryAttribute -Kind $Kind | Where-Object Name -EQ $Name
        if (-not $current) {
            throw "The directory hasn't returned a $Kind attribute named '$Name'."
        }
        $recordedNow = if ($PSBoundParameters.ContainsKey('Recorded')) { $Recorded } else { $current.Recorded -or $Shown }
        $shownNow = if ($PSBoundParameters.ContainsKey('Shown')) { $Shown } else { $current.Shown }
        # Stopping recording wins (and hides it); otherwise showing an attribute records it.
        if (-not $recordedNow) {
            $shownNow = $false
        } elseif ($shownNow) {
            $recordedNow = $true
        }

        if ($PSCmdlet.ShouldProcess("$Kind attribute $Name", "Recorded: $recordedNow, shown: $shownNow")) {
            $parameters = @{ kind = $Kind; name = $Name; recorded = $recordedNow; shown = $shownNow; newly = $recordedNow -and -not $current.Recorded }
            $update = @'
UPDATE ad_attributes SET recorded = @recorded, shown = @shown WHERE kind = @kind AND name = @name;
UPDATE ad_objects SET attributes = attributes - @name WHERE kind = @kind AND NOT @recorded;
UPDATE ad_objects SET fetched_at = '-infinity' WHERE kind = @kind AND @newly;
'@
            $null = Invoke-FathomSql -Query $update -Parameters $parameters
        }
        Get-FathomDirectoryAttribute -Kind $Kind | Where-Object Name -EQ $Name
    }
}

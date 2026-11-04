function Sync-FathomDirectory {
    <#
    .SYNOPSIS
        Looks up the users and hosts Fathom has seen in Active Directory, recording the chosen attributes.
    .DESCRIPTION
        Meant for a schedule. Does nothing while directory lookups are off (the default). Each run
        takes the names not yet looked up, or not refreshed in RefreshHours, up to -Limit. Every
        attribute name returned joins the catalog (Get-FathomDirectoryAttribute); only recorded
        attributes' values are stored. Needs the ActiveDirectory module (RSAT) on the PSU server.
    .EXAMPLE
        Sync-FathomDirectory -Credential $FathomDirectoryCredential
    #>
    [CmdletBinding()]
    [OutputType('Fathom.DirectorySync')]
    param(
        # For a directory that needs a login other than the PSU service account's.
        [pscredential] $Credential,

        # Most lookups per run, so a first run against years of history stays bounded.
        [ValidateRange(1, 100000)]
        [int] $Limit = 500
    )

    $settings = Get-FathomDirectorySetting
    $result = [pscustomobject] @{ PSTypeName = 'Fathom.DirectorySync'; Looked = 0; Found = 0; NotFound = 0; NewAttributes = 0 }
    if (-not $settings.Enabled) {
        Write-Verbose 'Directory lookups are off. Turn them on with Set-FathomDirectorySetting -Enabled $true.'
        return $result
    }
    # FATHOM_AD_MODULE: a module to use instead of ActiveDirectory (the dev/test fake), as
    # FATHOM_LMUTIL is for lmutil.
    if ($env:FATHOM_AD_MODULE) {
        Import-Module -Name $env:FATHOM_AD_MODULE -Global
    }
    if (-not (Get-Command -Name Get-ADUser -ErrorAction Ignore)) {
        throw 'Directory lookups need the ActiveDirectory module (RSAT) on the PSU server.'
    }

    # Users and hosts in the live sessions, the lmstat history and the last 90 days of log events.
    $now = Get-Date
    $due = @'
WITH seen AS (
    SELECT 'user' AS kind, lower("user") AS name FROM live_sessions
    UNION SELECT 'user', lower("user") FROM observed_sessions
    UNION SELECT 'user', lower("user") FROM license_events WHERE "user" <> '' AND timestamp >= @recent::timestamp
    UNION SELECT 'computer', lower(split_part(host, '.', 1)) FROM live_sessions
    UNION SELECT 'computer', lower(split_part(host, '.', 1)) FROM observed_sessions
    UNION SELECT 'computer', lower(split_part(host, '.', 1)) FROM license_events WHERE host <> '' AND timestamp >= @recent::timestamp
)
SELECT s.kind, s.name FROM seen s
LEFT JOIN ad_objects d ON d.kind = s.kind AND d.name = s.name
WHERE s.name <> '' AND (d.name IS NULL OR d.fetched_at < @stale::timestamp)
ORDER BY d.fetched_at NULLS FIRST, s.kind, s.name
LIMIT @limit
'@
    $parameters = @{
        recent = $now.AddDays(-90) | ConvertTo-FathomSqlTime
        stale  = $now.AddHours(-$settings.RefreshHours) | ConvertTo-FathomSqlTime
        limit  = $Limit
    }
    $names = @(Invoke-FathomQuery -Query $due -Parameters $parameters)
    if (-not $names) {
        return $result
    }

    # What a fresh catalog records and shows; everything else starts off.
    $defaults = @{
        user     = 'DisplayName', 'Department', 'Title', 'EmailAddress', 'Manager', 'Office'
        computer = 'Description', 'OperatingSystem', 'Location'
    }
    # And which of those are also columns in lists of people.
    $listedByDefault = @{ user = @('Department'); computer = @() }
    # Bookkeeping members of AD objects, not attributes.
    $meta = 'PropertyNames', 'AddedProperties', 'RemovedProperties', 'ModifiedProperties', 'PropertyCount', 'Item'
    $lookup = @{ Properties = '*'; ErrorAction = 'Stop' }
    if ($settings.Server) { $lookup.Server = $settings.Server }
    if ($Credential) { $lookup.Credential = $Credential }

    # The catalog, loaded once: every attribute name known, and those recorded, per kind.
    # AD attribute names ignore case.
    $newSet = { , [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase) }
    $known = @{ user = & $newSet; computer = & $newSet }
    $recorded = @{ user = & $newSet; computer = & $newSet }
    foreach ($attribute in Get-FathomDirectoryAttribute) {
        $null = $known[$attribute.Kind].Add($attribute.Name)
        if ($attribute.Recorded) { $null = $recorded[$attribute.Kind].Add($attribute.Name) }
    }

    $addAttribute = @'
INSERT INTO ad_attributes (kind, name, recorded, shown, listed, first_seen_at)
VALUES (@kind, @name, @default, @default, @listed, @now::timestamp) ON CONFLICT DO NOTHING
'@
    # A history row when a found object's recorded values differ from what was stored.
    $save = @'
INSERT INTO ad_history (kind, name, attributes, changed_at)
SELECT @kind, @name, @attributes::jsonb, @now::timestamp
WHERE @found AND NOT EXISTS (
    SELECT 1 FROM ad_objects WHERE kind = @kind AND name = @name AND attributes = @attributes::jsonb
)
ON CONFLICT (kind, name, changed_at) DO UPDATE SET attributes = EXCLUDED.attributes;
INSERT INTO ad_objects (kind, name, found, attributes, fetched_at)
VALUES (@kind, @name, @found, @attributes::jsonb, @now::timestamp)
ON CONFLICT (kind, name) DO UPDATE SET found = EXCLUDED.found, attributes = EXCLUDED.attributes, fetched_at = EXCLUDED.fetched_at
'@
    foreach ($entry in $names) {
        $result.Looked++
        try {
            $object = if ($entry.kind -eq 'user') { Get-ADUser -Identity $entry.name @lookup } else { Get-ADComputer -Identity $entry.name @lookup }
        } catch {
            # A name that isn't in the directory (a local account, a renamed host) is normal;
            # anything else (no domain controller, no access) stops the run to be retried.
            if ($_.CategoryInfo.Category -ne 'ObjectNotFound') { throw }
            $object = $null
        }

        $values = [ordered] @{}
        if ($object) {
            $result.Found++
            foreach ($property in $object.PSObject.Properties | Where-Object Name -NotIn $meta) {
                # Binary values (photos, certificates) are never recorded, so not offered either.
                if ($property.Value -is [byte[]]) {
                    continue
                }
                if ($known[$entry.kind].Add($property.Name)) {
                    $default = $property.Name -in $defaults[$entry.kind]
                    $null = Invoke-FathomSql -Query $addAttribute -Parameters @{
                        kind    = $entry.kind
                        name    = $property.Name
                        default = $default
                        listed  = $property.Name -in $listedByDefault[$entry.kind]
                        now     = $now | ConvertTo-FathomSqlTime
                    }
                    $result.NewAttributes++
                    if ($default) { $null = $recorded[$entry.kind].Add($property.Name) }
                }
                if ($recorded[$entry.kind].Contains($property.Name)) {
                    $value = ConvertTo-FathomDirectoryValue -Value $property.Value
                    if ($null -ne $value) { $values[$property.Name] = $value }
                }
            }
        } else {
            $result.NotFound++
        }

        $null = Invoke-FathomSql -Query $save -Parameters @{
            kind       = $entry.kind
            name       = $entry.name
            found      = [bool] $object
            attributes = $values | ConvertTo-Json -Compress -Depth 4
            now        = $now | ConvertTo-FathomSqlTime
        }
    }
    $result
}

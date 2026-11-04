function Save-FathomFeatureStatus {
    <#
    .SYNOPSIS
        Stores one feature's lmstat snapshot: live usage, plus its seat count in feature_inventory.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSTypeName('Fathom.LiveFeatureStatus')] $Status
    )

    # Same writes as Fathom's ingest_lmstat_text, with one fix: an existing row keeps its
    # version and expiration, which lmstat doesn't report (Fathom blanks them).
    $query = @'
INSERT INTO live_status (server_id, feature, licenses_issued, licenses_in_use, vendor_daemon, captured_at)
VALUES (@server_id, @feature, @issued, @in_use, @vendor, @captured_at::timestamp)
ON CONFLICT (server_id, feature) DO UPDATE SET
    licenses_issued = EXCLUDED.licenses_issued,
    licenses_in_use = EXCLUDED.licenses_in_use,
    vendor_daemon = EXCLUDED.vendor_daemon,
    captured_at = EXCLUDED.captured_at;

INSERT INTO feature_inventory (server_id, feature, vendor_daemon, version, licenses_issued, updated_at)
VALUES (@server_id, @feature, @vendor, '', @issued, @captured_at::timestamp)
ON CONFLICT (server_id, feature) DO UPDATE SET
    vendor_daemon = EXCLUDED.vendor_daemon,
    licenses_issued = EXCLUDED.licenses_issued,
    updated_at = EXCLUDED.updated_at;
'@
    $parameters = @{
        server_id   = $Status.ServerId
        feature     = $Status.Feature
        issued      = $Status.LicensesIssued
        in_use      = $Status.LicensesInUse
        vendor      = $Status.VendorDaemon ?? [DBNull]::Value
        captured_at = $Status.CapturedAt.ToString('yyyy-MM-dd HH:mm:ss')
    }
    $null = Invoke-SqlUpdate -ConnectionName $script:ConnectionName -Query $query -Parameters $parameters
}

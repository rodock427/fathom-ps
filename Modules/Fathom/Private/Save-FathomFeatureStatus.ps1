function Save-FathomFeatureStatus {
    <#
    .SYNOPSIS
        Stores one feature's lmstat snapshot: live usage, history sample, holders, seat count and expiry.
    .DESCRIPTION
        Call inside a transaction, after clearing the server's previous holders.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSTypeName('Fathom.LiveFeatureStatus')] $Status
    )

    # live_status and feature_inventory are Fathom's tables, written as Fathom does, with two
    # fixes: version is never blanked, and expiration changes only when lmstat reports one
    # (a real date, or "permanent" stored as NULL, Fathom's convention). Cost and token family
    # are admin-entered and never touched.
    $query = @'
INSERT INTO live_status (server_id, feature, licenses_issued, licenses_in_use, vendor_daemon, captured_at)
VALUES (@server_id, @feature, @issued, @in_use, @vendor, @captured_at::timestamp)
ON CONFLICT (server_id, feature) DO UPDATE SET
    licenses_issued = EXCLUDED.licenses_issued,
    licenses_in_use = EXCLUDED.licenses_in_use,
    vendor_daemon = EXCLUDED.vendor_daemon,
    captured_at = EXCLUDED.captured_at;

INSERT INTO usage_samples (server_id, feature, captured_at, licenses_issued, licenses_in_use)
VALUES (@server_id, @feature, @captured_at::timestamp, @issued, @in_use)
ON CONFLICT DO NOTHING;

INSERT INTO feature_inventory (server_id, feature, vendor_daemon, version, licenses_issued, expiration, updated_at)
VALUES (@server_id, @feature, @vendor, '', @issued, @expiry::date, @captured_at::timestamp)
ON CONFLICT (server_id, feature) DO UPDATE SET
    vendor_daemon = EXCLUDED.vendor_daemon,
    licenses_issued = EXCLUDED.licenses_issued,
    expiration = CASE WHEN @expiry_reported THEN EXCLUDED.expiration ELSE feature_inventory.expiration END,
    updated_at = EXCLUDED.updated_at;
'@
    $parameters = @{
        server_id       = $Status.ServerId
        feature         = $Status.Feature
        issued          = $Status.LicensesIssued
        in_use          = $Status.LicensesInUse
        vendor          = $Status.VendorDaemon ?? [DBNull]::Value
        captured_at     = $Status.CapturedAt.ToString('yyyy-MM-dd HH:mm:ss')
        expiry          = if ($Status.Expiry) { $Status.Expiry.ToString('yyyy-MM-dd') } else { [DBNull]::Value }
        expiry_reported = $Status.ExpiryReported
    }
    $null = Invoke-FathomSql -Query $query -Parameters $parameters

    $holderQuery = @'
INSERT INTO live_sessions (server_id, feature, "user", host, display, version, handle, licenses, started_at, captured_at)
VALUES (@server_id, @feature, @user, @host, @display, @version, @handle, @licenses, @started_at::timestamp, @captured_at::timestamp);

INSERT INTO observed_sessions (server_id, feature, "user", host, handle, started_at, licenses, first_seen_at, last_seen_at)
VALUES (@server_id, @feature, @user, @host, @handle, @started_at::timestamp, @licenses, @captured_at::timestamp, @captured_at::timestamp)
ON CONFLICT (server_id, feature, "user", host, handle, started_at) DO UPDATE SET last_seen_at = EXCLUDED.last_seen_at;
'@
    # A holder whose start time couldn't be read can't be told apart from its next session.
    foreach ($holder in $Status.Holders | Where-Object StartedAt) {
        $holderParameters = @{
            server_id   = $Status.ServerId
            feature     = $Status.Feature
            user        = $holder.User
            host        = $holder.Host
            display     = $holder.Display
            version     = $holder.Version
            handle      = $holder.Handle
            licenses    = $holder.Licenses
            started_at  = if ($holder.StartedAt) { $holder.StartedAt.ToString('yyyy-MM-dd HH:mm:ss') } else { [DBNull]::Value }
            captured_at = $parameters.captured_at
        }
        $null = Invoke-FathomSql -Query $holderQuery -Parameters $holderParameters
    }
}

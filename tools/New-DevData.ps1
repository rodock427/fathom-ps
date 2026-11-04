<#
.SYNOPSIS
    Fills a local dev database with realistic license usage: a dev server with the last few days of
    activity, optionally a very big server, and Active Directory details from the fake.
.DESCRIPTION
    Simulates the fake-AD users at their workstations (working-hours sessions, denials when a
    feature is full) and writes it as an lmgrd debug log ending now (.dev/debug.log), plus the
    lmstat answer for whoever still holds a seat (.dev/licsrv.txt, for tests/fakes/lmutil). Then
    registers the server and reads both once, so the app has data straight away.

    Only touches its own servers, dev-licsrv and dev-big, and starts them over on every run.
    Refuses a database that isn't on this machine, unless -Force.
.EXAMPLE
    ./tools/New-DevData.ps1                   # dev-licsrv, the last 7 days
.EXAMPLE
    ./tools/New-DevData.ps1 -Big              # plus 400 features with 30 days of lmstat samples
.EXAMPLE
    ./tools/New-DevData.ps1 -Remove           # take both away again
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The script itself asks once (ShouldProcess) before its helpers change anything.')]
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $Dsn = $env:LM_POSTGRES_DSN,

    # Days of debug-log history for dev-licsrv, ending now.
    [ValidateRange(1, 90)]
    [int] $Days = 7,

    # Also dev-big: hundreds of features with lmstat samples every 5 minutes, for scale testing.
    [switch] $Big,

    [ValidateRange(1, 2000)]
    [int] $BigFeatures = 400,

    [ValidateRange(1, 365)]
    [int] $BigDays = 30,

    # Remove the dev servers and their data instead.
    [switch] $Remove,

    # Same seed, same history (relative to now).
    [int] $Seed = 42,

    # Write to a database that isn't on this machine: only one that's yours to fill, such as the
    # compose stack's own (podman compose exec fathom pwsh /app/tools/New-DevData.ps1 -Force).
    [switch] $Force,

    # Where the generated log, lmstat answers and alert mail go: where the fake lmutil reads
    # (FAKE_LMUTIL_DIR), else .dev in this repo.
    [string] $DevDirectory = ($env:FAKE_LMUTIL_DIR ? $env:FAKE_LMUTIL_DIR : (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath '.dev'))
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Path $PSScriptRoot -Parent
$devDir = $DevDirectory
Import-Module (Join-Path -Path $root -ChildPath 'Modules/Fathom/Fathom.psd1') -Force

if (-not $Force -and $Dsn -notmatch '@(localhost|127\.0\.0\.1|\[::1\])[:/]') {
    throw 'New-DevData only writes to a database on this machine (localhost in the DSN). -Force overrides.'
}

$owned = 'dev-licsrv', 'dev-big'
$featureSeats = [ordered] @{ MATLAB = 10; SIMULINK = 5; INVENTOR_PRO = 2; AUTOCAD = 25; ANSYS_MECH = 3 }
# Some log in with their user logon name (userPrincipalName) rather than the pre-Windows 2000 one,
# as after a naming change, and Kory with both (starfire, kory.anders): one person either way.
$users = 'alice', 'bob', 'carol', 'dave', 'blossom', 'buttercup', 'bubbles', 'starfire', 'kory.anders', 'rachel.roth', 'jbravo'

function Remove-DevServer {
    # Every row these servers own, then the servers. Leaves everything else alone.
    foreach ($id in $owned) {
        $tables = 'license_events', 'usage_samples', 'live_status', 'live_sessions', 'observed_sessions',
        'poll_history', 'vendor_daemon_status', 'feature_inventory', 'alert_state', 'log_coverage'
        foreach ($table in $tables) {
            $null = Invoke-DevSql -Query "DELETE FROM $table WHERE server_id = @id" -Parameters @{ id = $id }
        }
        if (Get-FathomServer -ServerId $id) {
            Unregister-FathomServer -ServerId $id -Confirm:$false
        }
    }
}

function Invoke-DevSql([string] $Query, [hashtable] $Parameters = @{}, [int] $CommandTimeout = 30, [switch] $Rows) {
    # On the module's own connection, through its own (private) SQL helpers.
    & (Get-Module -Name Fathom) {
        param($Query, $Parameters, $CommandTimeout, $Rows)
        if ($Rows) {
            Invoke-FathomQuery -Query $Query -Parameters $Parameters -CommandTimeout $CommandTimeout
        } else {
            Invoke-FathomSql -Query $Query -Parameters $Parameters -CommandTimeout $CommandTimeout
        }
    } $Query $Parameters $CommandTimeout $Rows
}

# Working-hours sessions for every user on every day, turned into checkouts, checkins and denials.
function Get-DevActivity([datetime] $From, [datetime] $To, [int] $Seed) {
    $random = [Random]::new($Seed)
    $requests = foreach ($day in 0..([int] ($To.Date - $From.Date).TotalDays)) {
        $date = $From.Date.AddDays($day)
        $weekend = $date.DayOfWeek -in 'Saturday', 'Sunday'
        for ($u = 0; $u -lt $users.Count; $u++) {
            $sessions = if ($weekend) { [int] ($random.NextDouble() -lt 0.1) } else { $random.Next(1, 4) }
            for ($s = 0; $s -lt $sessions; $s++) {
                [pscustomobject] @{
                    Time    = $date.AddMinutes($random.Next(7 * 60 + 30, 17 * 60 + 30))
                    Minutes = $random.Next(15, 300)
                    Feature = @($featureSeats.Keys)[$random.Next(0, $featureSeats.Count)]
                    User    = $users[$u]
                    Host    = 'WS-{0:d2}' -f ($u + 1)
                }
            }
        }
    }

    $open = @{}
    foreach ($feature in $featureSeats.Keys) { $open[$feature] = [Collections.Generic.List[object]]::new() }
    $events = [Collections.Generic.List[object]]::new()
    foreach ($request in $requests | Where-Object Time -LT $To | Sort-Object Time) {
        $held = $open[$request.Feature]
        # Seats given back before this request free up first.
        foreach ($done in @($held | Where-Object Ends -LE $request.Time)) {
            $events.Add([pscustomobject] @{ Time = $done.Ends; Kind = 'IN'; Feature = $request.Feature; User = $done.User; Host = $done.Host })
            $null = $held.Remove($done)
        }
        if ($held.Count -lt $featureSeats[$request.Feature]) {
            $events.Add([pscustomobject] @{ Time = $request.Time; Kind = 'OUT'; Feature = $request.Feature; User = $request.User; Host = $request.Host })
            $held.Add([pscustomobject] @{ Ends = $request.Time.AddMinutes($request.Minutes); Started = $request.Time; User = $request.User; Host = $request.Host })
        } else {
            $events.Add([pscustomobject] @{ Time = $request.Time; Kind = 'DENIED'; Feature = $request.Feature; User = $request.User; Host = $request.Host })
        }
    }
    # Close what ended before now; the rest still holds a seat.
    $holders = foreach ($feature in $featureSeats.Keys) {
        foreach ($session in @($open[$feature])) {
            if ($session.Ends -le $To) {
                $events.Add([pscustomobject] @{ Time = $session.Ends; Kind = 'IN'; Feature = $feature; User = $session.User; Host = $session.Host })
            } else {
                [pscustomobject] @{ Feature = $feature; User = $session.User; Host = $session.Host; Started = $session.Started }
            }
        }
    }
    @{ Events = $events | Sort-Object Time, @{ Expression = { $_.Kind -ne 'IN' } }; Holders = @($holders) }
}

function Write-DevDebugLog([object[]] $Events, [datetime] $From, [datetime] $To, [string] $Path) {
    $invariant = [cultureinfo]::InvariantCulture
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add("00:00:00 (lmgrd) FLEXnet Licensing (v11.16.4.0 build 262069) started on licsrv (Linux) ($($From.ToString('M/d/yyyy', $invariant)))")
    $index = 0
    for ($date = $From.Date; $date -le $To.Date; $date = $date.AddDays(1)) {
        $lines.Add("00:00:00 (mlm) TIMESTAMP $($date.ToString('M/d/yyyy', $invariant))")
        while ($index -lt $Events.Count -and $Events[$index].Time.Date -eq $date) {
            $entry = $Events[$index++]
            $line = "$($entry.Time.ToString('HH:mm:ss')) (mlm) $($entry.Kind): `"$($entry.Feature)`" $($entry.User)@$($entry.Host)"
            if ($entry.Kind -eq 'DENIED') { $line += ' (Licensed number of users already reached. (-4,342))' }
            $lines.Add($line)
        }
    }
    [IO.File]::WriteAllLines($Path, $lines)
}

function Write-DevLmstat([object[]] $Holders, [datetime] $At, [string] $Path) {
    $invariant = [cultureinfo]::InvariantCulture
    $expiry = @{ ANSYS_MECH = $At.Date.AddDays(20); AUTOCAD = $At.Date.AddYears(1) }
    $text = [Text.StringBuilder]::new()
    $null = $text.AppendLine('lmutil - Copyright (c) 1989-2024 Flexera. All Rights Reserved.')
    $null = $text.AppendLine("Flexible License Manager status on $($At.ToString('ddd M/d/yyyy HH:mm', $invariant))")
    $null = $text.AppendLine("`nLicense server status: 27000@licsrv`n    License file(s) on licsrv: /opt/flexlm/licenses/dev.lic:`n")
    $null = $text.AppendLine("  licsrv: license server UP (MASTER) v11.19.4`n`nVendor daemon status (on licsrv):`n`n       mlm: UP v11.19.4`n`nFeature usage info:`n")
    $handle = 2100
    foreach ($feature in $featureSeats.Keys) {
        $held = @($Holders | Where-Object Feature -EQ $feature)
        $expires = if ($expiry[$feature]) { $expiry[$feature].ToString('d-MMM-yyyy', $invariant).ToLowerInvariant() } else { 'permanent' }
        $null = $text.AppendLine("Users of ${feature}:  (Total of $($featureSeats[$feature]) licenses issued;  Total of $($held.Count) licenses in use)`n")
        $null = $text.AppendLine("  `"$feature`" v1.000, vendor: mlm, expiry: $expires`n  floating license`n")
        foreach ($holder in $held) {
            $null = $text.AppendLine("    $($holder.User) $($holder.Host) $($holder.Host) (v1.0) (licsrv/27000 $(($handle++))), start $($holder.Started.ToString('ddd M/d H:mm', $invariant))")
        }
        $null = $text.AppendLine()
    }
    [IO.File]::WriteAllText($Path, $text.ToString())
}

function Add-DevBigServer([int] $Features, [int] $Days) {
    $null = Register-FathomServer -ServerId dev-big -Name 'Big license server' -LicenseSpec 27000@big -Vendor bigvendor
    # Daily-shaped use for $Features features, every 5 minutes for $Days days, in SQL: millions of rows.
    $samples = @'
INSERT INTO usage_samples (server_id, feature, captured_at, licenses_issued, licenses_in_use)
SELECT 'dev-big', 'FEATURE_' || lpad(f::text, 4, '0'), t, seats,
       LEAST(seats, GREATEST(0, round(seats * load * GREATEST(0, sin(pi() * (extract(hour FROM t) + extract(minute FROM t) / 60.0 - 7) / 11)))))::int
FROM (SELECT f, CASE WHEN f % 10 = 0 THEN 500 ELSE 1 + (f * 37) % 60 END AS seats, ((f * 53) % 100) / 100.0 AS load
      FROM generate_series(1, @features) f) features,
     generate_series(@from::timestamp, @to::timestamp, interval '5 minutes') t
'@
    $now = Get-Date
    $parameters = @{ features = $Features; from = $now.AddDays(-$Days).ToString('s'); to = $now.ToString('s') }
    $null = Invoke-DevSql -Query $samples -Parameters $parameters -CommandTimeout 1800

    # The lmstat answer: each feature's latest sample, no holders.
    $latest = 'SELECT DISTINCT ON (feature) feature, licenses_issued, licenses_in_use FROM usage_samples WHERE server_id = ''dev-big'' ORDER BY feature, captured_at DESC'
    $text = [Text.StringBuilder]::new("lmutil - Copyright (c) 1989-2024 Flexera. All Rights Reserved.`n`nLicense server status: 27000@big`n`n      big: license server UP (MASTER) v11.19.4`n`nVendor daemon status (on big):`n`n bigvendor: UP v11.19.4`n`nFeature usage info:`n`n")
    foreach ($row in Invoke-DevSql -Query $latest -Rows) {
        $null = $text.AppendLine("Users of $($row.feature):  (Total of $($row.licenses_issued) licenses issued;  Total of $($row.licenses_in_use) licenses in use)`n")
        $null = $text.AppendLine("  `"$($row.feature)`" v1.0, vendor: bigvendor, expiry: permanent`n  floating license`n")
    }
    [IO.File]::WriteAllText((Join-Path -Path $devDir -ChildPath 'big.txt'), $text.ToString())
}

Connect-FathomDatabase -Dsn $Dsn
try {
    Initialize-FathomSchema
    if (-not $PSCmdlet.ShouldProcess(($owned -join ', '), $Remove ? 'Remove dev servers' : 'Recreate dev servers with generated data')) {
        return
    }
    Remove-DevServer
    if ($Remove) {
        foreach ($file in 'debug.log', 'licsrv.txt', 'big.txt') {
            Remove-Item -LiteralPath (Join-Path -Path $devDir -ChildPath $file) -ErrorAction Ignore
        }
        return
    }

    $null = New-Item -ItemType Directory -Path (Join-Path -Path $devDir -ChildPath 'mail') -Force
    $now = Get-Date
    $from = $now.Date.AddDays(1 - $Days)
    $activity = Get-DevActivity -From $from -To $now -Seed $Seed
    $log = Join-Path -Path $devDir -ChildPath 'debug.log'
    Write-DevDebugLog -Events $activity.Events -From $from -To $now -Path $log
    Write-DevLmstat -Holders $activity.Holders -At $now -Path (Join-Path -Path $devDir -ChildPath 'licsrv.txt')

    $null = Register-FathomServer -ServerId dev-licsrv -Name 'Dev license server' -LicenseSpec 27000@licsrv -LogPath $log -Vendor mlm
    if ($Big) {
        Add-DevBigServer -Features $BigFeatures -Days $BigDays
    } else {
        Remove-Item -LiteralPath (Join-Path -Path $devDir -ChildPath 'big.txt') -ErrorAction Ignore
    }

    # Read both sources once, as the PSU schedules would.
    $env:FAKE_LMUTIL_DIR = $devDir
    $null = Get-FathomServer -ServerId dev-licsrv | Sync-FathomDebugLog
    $null = Get-FathomServer | Where-Object ServerId -In $owned | Sync-FathomLiveStatus -LmutilPath (Join-Path -Path $root -ChildPath ($IsWindows ? 'tests/fakes/lmutil.cmd' : 'tests/fakes/lmutil'))

    # Mail to a folder, and Active Directory from the fake, both as dev PSU is set up.
    $null = Set-FathomAlertSetting -PickupDirectory (Join-Path -Path $devDir -ChildPath 'mail') -From fathom@dev.local -To you@dev.local
    $env:FATHOM_AD_MODULE = Join-Path -Path $root -ChildPath 'tests/fakes/ActiveDirectory/ActiveDirectory.psm1'
    $wasOn = (Get-FathomDirectorySetting).Enabled
    $null = Set-FathomDirectorySetting -Enabled $true
    $directory = Sync-FathomDirectory
    $null = Set-FathomDirectorySetting -Enabled $wasOn

    [pscustomobject] @{
        Servers   = @(Get-FathomServer | Where-Object ServerId -In $owned).ServerId -join ', '
        LogEvents = $activity.Events.Count
        Denials   = @($activity.Events | Where-Object Kind -EQ 'DENIED').Count
        Holding   = $activity.Holders.Count
        Directory = "$($directory.Found) found, $($directory.NotFound) not found"
    }
} finally {
    Disconnect-FathomDatabase
}

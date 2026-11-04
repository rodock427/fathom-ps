# Fathom license monitoring. PSU runs a page's script on every visit. Pages are hidden from roles
# below their tier, and each page checks the tier again itself.
$AppRoot = $PSScriptRoot

$pages = @(
    New-UDPage -Name 'Overview' -Url '/overview' -Icon (New-UDIcon -Icon 'gauge') -DefaultHomePage -Role (Get-FathomRole -Tier Reader) -Content {
        . "$AppRoot/Pages/Overview.ps1"
    }
    New-UDPage -Name 'Server detail' -Url '/server' -Icon (New-UDIcon -Icon 'server') -Role (Get-FathomRole -Tier Reader) -Content {
        . "$AppRoot/Pages/Server.ps1"
    }
    New-UDPage -Name 'Capacity and renewal' -Url '/capacity' -Icon (New-UDIcon -Icon 'chart-line') -Role (Get-FathomRole -Tier Operator) -Content {
        . "$AppRoot/Pages/Capacity.ps1"
    }
    New-UDPage -Name 'People' -Url '/people' -Icon (New-UDIcon -Icon 'users') -Role (Get-FathomRole -Tier Operator) -Content {
        . "$AppRoot/Pages/People.ps1"
    }
    New-UDPage -Name 'Administration' -Url '/admin' -Icon (New-UDIcon -Icon 'gear') -Role (Get-FathomRole -Tier Admin) -Content {
        . "$AppRoot/Pages/Admin.ps1"
    }
)

New-UDApp -Title 'Fathom' -Pages $pages -NavigationLayout permanent

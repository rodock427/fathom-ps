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
    New-UDPage -Name 'People' -Url '/people' -Icon (New-UDIcon -Icon 'users') -Role (Get-FathomRole -Tier Operator) -Content {
        . "$AppRoot/Pages/People.ps1"
    }
    New-UDPage -Name 'Seat planning' -Url '/seat-planning' -Icon (New-UDIcon -Icon 'chart-line') -Role (Get-FathomRole -Tier Operator) -Content {
        . "$AppRoot/Pages/SeatPlanning.ps1"
    }
    New-UDPage -Name 'Administration' -Url '/admin' -Icon (New-UDIcon -Icon 'gear') -Role (Get-FathomRole -Tier Admin) -Content {
        . "$AppRoot/Pages/Admin.ps1"
    }
)

# The menu, built per user: only what their tier can open, with reports in their own group.
$navigation = {
    New-UDList -Children {
        New-UDListItem -Label 'Overview' -Icon (New-UDIcon -Icon 'gauge') -Href 'overview'
        New-UDListItem -Label 'Server detail' -Icon (New-UDIcon -Icon 'server') -Href 'server'
        if (Test-FathomAccess -Tier Operator -Role $Roles) {
            New-UDListItem -Label 'People' -Icon (New-UDIcon -Icon 'users') -Href 'people'
            New-UDListItem -Label 'Reports' -Icon (New-UDIcon -Icon 'folder-open') -Open -Children {
                New-UDListItem -Label 'Seat planning' -Icon (New-UDIcon -Icon 'chart-line') -Href 'seat-planning' -Nested
            }
        }
        if (Test-FathomAccess -Tier Admin -Role $Roles) {
            New-UDListItem -Label 'Administration' -Icon (New-UDIcon -Icon 'gear') -Href 'admin'
        }
    }
}

New-UDApp -Title 'Fathom' -Pages $pages -NavigationLayout permanent -LoadNavigation $navigation

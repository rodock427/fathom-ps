New-PSURole -Name 'Administrator' -Description 'Full access to PSU, and every Fathom tier.' -Policy {
    param($User)
    $false
}
New-PSURole -Name 'Operator' -Description 'Manages PSU scripts, schedules and apps. Not needed for Fathom.' -Policy {
    param($User)
    $false
}
New-PSURole -Name 'Reader' -Description 'Read-only access to the PSU admin console. Not needed for Fathom.' -Policy {
    param($User)
    $false
}
New-PSURole -Name 'Execute' -Description 'Runs PSU scripts. Not needed for Fathom.' -Policy {
    param($User)
    $false
}
New-PSURole -Name 'FathomReader' -Description 'Fathom: free seats, server health, usage history and expiry. No individuals.' -Policy {
    param($User)
    $false
}
New-PSURole -Name 'FathomOperator' -Description 'Fathom: everything a reader sees, plus who holds and was denied seats, and the capacity report.' -Policy {
    param($User)
    $false
}
New-PSURole -Name 'FathomAdmin' -Description 'Fathom: everything, plus managing servers and alert settings.' -Policy {
    param($User)
    $false
}

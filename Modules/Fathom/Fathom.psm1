# SimplySql tracks connections by name; every Fathom command uses this one.
$script:ConnectionName = 'Fathom'
$script:SqlPath = Join-Path -Path $PSScriptRoot -ChildPath 'Sql'

# SimplySql reports a failed statement as a non-terminating error, so a failed write would
# carry on (even mid-transaction) unless the caller happened to set ErrorAction Stop. Every
# database call in this module must stop on failure, whatever the caller's preference; the
# module's own deliberate non-terminating errors (an unreachable share) are unaffected.
$PSDefaultParameterValues = @{
    'Invoke-Sql*:ErrorAction'            = 'Stop'
    'Open-PostGreConnection:ErrorAction' = 'Stop'
    '*-SqlTransaction:ErrorAction'       = 'Stop'
}

foreach ($folder in 'Classes', 'Private', 'Public') {
    $path = Join-Path -Path $PSScriptRoot -ChildPath $folder
    foreach ($file in Get-ChildItem -Path $path -Filter '*.ps1' -ErrorAction Ignore) {
        . $file.FullName
    }
}

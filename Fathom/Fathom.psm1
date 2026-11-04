# SimplySql tracks connections by name; every Fathom command uses this one.
$script:ConnectionName = 'Fathom'
$script:SqlPath = Join-Path -Path $PSScriptRoot -ChildPath 'Sql'

foreach ($folder in 'Classes', 'Private', 'Public') {
    $path = Join-Path -Path $PSScriptRoot -ChildPath $folder
    foreach ($file in Get-ChildItem -Path $path -Filter '*.ps1' -ErrorAction Ignore) {
        . $file.FullName
    }
}

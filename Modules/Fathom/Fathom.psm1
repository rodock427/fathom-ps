# Open connections, one per runspace (Private/Get-FathomConnectionName.ps1). Thread-safe:
# PSU's concurrent jobs and app pages can share this module's state.
$script:Sessions = [System.Collections.Concurrent.ConcurrentDictionary[string, object]]::new()
$script:SqlPath = Join-Path -Path $PSScriptRoot -ChildPath 'Sql'

foreach ($folder in 'Classes', 'Private', 'Public') {
    $path = Join-Path -Path $PSScriptRoot -ChildPath $folder
    foreach ($file in Get-ChildItem -Path $path -Filter '*.ps1' -ErrorAction Ignore) {
        . $file.FullName
    }
}

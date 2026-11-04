<#
.SYNOPSIS
    Lints and tests fathom-ps. CI runs exactly this.
.EXAMPLE
    ./build.ps1 -Task Test
#>
[CmdletBinding()]
param(
    [ValidateSet('Lint', 'Test', 'All')]
    [string] $Task = 'All'
)

$ErrorActionPreference = 'Stop'

if ($Task -in 'Lint', 'All') {
    $settings = Join-Path -Path $PSScriptRoot -ChildPath 'PSScriptAnalyzerSettings.psd1'
    # Not .universal/: PSU rewrites those files in its own format whenever the admin console saves.
    $paths = 'Apps', 'Modules', 'Scripts', 'tests', 'build.ps1', 'PSScriptAnalyzerSettings.psd1' |
        ForEach-Object { Join-Path -Path $PSScriptRoot -ChildPath $_ }
    $findings = $paths | ForEach-Object { Invoke-ScriptAnalyzer -Path $_ -Recurse -Settings $settings }
    if ($findings) {
        $findings | Format-Table -AutoSize RuleName, Severity, ScriptName, Line, Message | Out-String | Write-Information -InformationAction Continue
        throw "PSScriptAnalyzer reported $($findings.Count) finding(s)."
    }
}

if ($Task -in 'Test', 'All') {
    $config = New-PesterConfiguration
    $config.Run.Path = Join-Path -Path $PSScriptRoot -ChildPath 'tests'
    $config.Run.Throw = $true
    $config.Output.Verbosity = 'Detailed'
    $config.TestResult.Enabled = $true
    $config.TestResult.OutputFormat = 'JUnitXml'
    $config.TestResult.OutputPath = Join-Path -Path $PSScriptRoot -ChildPath 'testResults.xml'
    Invoke-Pester -Configuration $config
}

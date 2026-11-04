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
    # Per file, with one retry: PSScriptAnalyzer 1.25 intermittently throws internal errors
    # (NullReferenceException) shortly after startup. Findings are results, not exceptions,
    # so a retry can't hide one.
    $findings = Get-ChildItem -Path $PSScriptRoot -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1' | ForEach-Object {
        $analyzer = @{ Path = $_.FullName; Settings = $settings; ErrorAction = 'Stop' }
        try {
            Invoke-ScriptAnalyzer @analyzer
        } catch {
            Write-Warning "PSScriptAnalyzer crashed on $($_.TargetObject ?? $analyzer.Path); retrying once."
            Invoke-ScriptAnalyzer @analyzer
        }
    }
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

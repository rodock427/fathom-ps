@{
    RootModule        = 'Fathom.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '5f0c6a2e-8d3b-4c71-9a54-2b7e1f6d9c40'
    Author            = 'rodock427'
    Description       = 'FlexLM license monitoring for PowerShell Universal.'
    PowerShellVersion = '7.4'
    RequiredModules   = @(@{ ModuleName = 'SimplySql'; ModuleVersion = '2.2.0' })
    FunctionsToExport = @(
        'Connect-FathomDatabase'
        'ConvertFrom-FathomDebugLog'
        'ConvertFrom-FathomLmstat'
        'Disconnect-FathomDatabase'
        'Get-FathomServer'
        'Initialize-FathomSchema'
        'New-FathomParserContext'
        'Register-FathomServer'
        'Set-FathomServer'
        'Sync-FathomDebugLog'
        'Sync-FathomLiveStatus'
        'Unregister-FathomServer'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}

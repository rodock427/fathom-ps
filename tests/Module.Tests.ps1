BeforeAll {
    $moduleRoot = Join-Path -Path $PSScriptRoot -ChildPath '../Fathom'
    Import-Module (Join-Path -Path $moduleRoot -ChildPath 'Fathom.psd1') -Force
}

Describe 'Fathom module' {
    It 'exports exactly the functions in Public/' {
        $public = (Get-ChildItem -Path (Join-Path -Path $moduleRoot -ChildPath 'Public') -Filter '*.ps1').BaseName
        $exported = (Get-Module -Name Fathom).ExportedFunctions.Keys

        $exported | Sort-Object | Should -Be ($public | Sort-Object)
    }

    It 'gives every exported function a synopsis' {
        foreach ($name in (Get-Module -Name Fathom).ExportedFunctions.Keys) {
            (Get-Help -Name $name).Synopsis | Should -Not -BeLike "$name*" -Because "$name needs .SYNOPSIS"
        }
    }
}

Describe 'ConvertTo-NpgsqlConnectionString' {
    It 'converts a libpq URI' {
        InModuleScope Fathom {
            ConvertTo-NpgsqlConnectionString -Dsn 'postgresql://lm:secret@db01:6543/license_manager'
        } | Should -Be 'Host=db01;Port=6543;Database=license_manager;Username=lm;Password=secret'
    }

    It 'defaults the port and unescapes credentials' {
        InModuleScope Fathom {
            ConvertTo-NpgsqlConnectionString -Dsn 'postgres://lm%40corp:p%3Ass@db01/lm'
        } | Should -Be 'Host=db01;Port=5432;Database=lm;Username=lm@corp;Password=p:ss'
    }

    It 'maps sslmode' {
        InModuleScope Fathom {
            ConvertTo-NpgsqlConnectionString -Dsn 'postgresql://lm:x@db01/lm?sslmode=require'
        } | Should -BeLike '*;SSL Mode=require'
    }

    It 'refuses options it would otherwise drop' {
        { InModuleScope Fathom { ConvertTo-NpgsqlConnectionString -Dsn 'postgresql://lm:x@db01/lm?target_session_attrs=any' } } |
            Should -Throw '*target_session_attrs*'
    }

    It 'passes a key=value string through unchanged' {
        InModuleScope Fathom {
            ConvertTo-NpgsqlConnectionString -Dsn 'Host=db01;Database=lm'
        } | Should -Be 'Host=db01;Database=lm'
    }
}

Describe 'Connect-FathomDatabase' {
    It 'fails clearly when no DSN is configured' {
        $saved = $env:LM_POSTGRES_DSN
        try {
            $env:LM_POSTGRES_DSN = $null
            { Connect-FathomDatabase } | Should -Throw '*LM_POSTGRES_DSN*'
        } finally {
            $env:LM_POSTGRES_DSN = $saved
        }
    }
}

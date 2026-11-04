# Stands in for the RSAT ActiveDirectory module in tests and dev: Get-ADUser and Get-ADComputer
# for the usernames and hosts in the fixtures, with the kinds of values the real one returns
# (multi-valued, dates, SIDs, GUIDs, binary, empty). Put tests/fakes on PSModulePath to use it.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSReviewUnusedParameter', '', Justification = 'Parameters match the real cmdlets; the fake ignores them.')]
param()

# SecurityIdentifier is Windows-only; this stands in for it (an object that prints as a SID).
class FakeSecurityIdentifier {
    [string] $Value
    FakeSecurityIdentifier([string] $Value) { $this.Value = $Value }
    [string] ToString() { return $this.Value }
}

$script:Users = @{
    alice     = @{ GivenName = 'Alice'; Surname = 'Archer'; Department = 'Engineering'; Title = 'CAD Designer'; Office = 'B2-104' }
    bob       = @{ GivenName = 'Bob'; Surname = 'Baker'; Department = 'Engineering'; Title = 'Design Lead'; Office = 'B2-110' }
    carol     = @{ GivenName = 'Carol'; Surname = 'Chen'; Department = 'Simulation'; Title = 'Analyst'; Office = 'B1-020' }
    dave      = @{ GivenName = 'Dave'; Surname = 'Diaz'; Department = 'Manufacturing'; Title = 'Process Engineer'; Office = 'Plant 3' }
    blossom   = @{ GivenName = 'Blossom'; Surname = 'Utonium'; Department = 'Research'; Title = 'Scientist'; Office = 'Lab 1' }
    buttercup = @{ GivenName = 'Buttercup'; Surname = 'Utonium'; Department = 'Research'; Title = 'Scientist'; Office = 'Lab 1' }
    bubbles   = @{ GivenName = 'Bubbles'; Surname = 'Utonium'; Department = 'Research'; Title = 'Intern'; Office = 'Lab 2' }
    starfire  = @{ GivenName = 'Kory'; Surname = 'Anders'; Department = 'Simulation'; Title = 'Analyst'; Office = 'B1-022' }
    raven     = @{ GivenName = 'Rachel'; Surname = 'Roth'; Department = 'Simulation'; Title = 'Senior Analyst'; Office = 'B1-030' }
    jbravo    = @{ GivenName = 'Johnny'; Surname = 'Bravo'; Department = 'Sales'; Title = 'Account Manager'; Office = 'HQ-2' }
}

function Get-FakeIdentityError([string] $Identity, [string] $Command) {
    $exception = [System.Exception]::new("Cannot find an object with identity: '$Identity' under: 'DC=corp,DC=local'.")
    $id = "ActiveDirectoryCmdlet:Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException,Microsoft.ActiveDirectory.Management.Commands.$Command"
    [System.Management.Automation.ErrorRecord]::new($exception, $id, 'ObjectNotFound', $Identity)
}

function Get-ADUser {
    <#
    .SYNOPSIS
        A fixture user with -Properties * worth of attributes, or the real module's not-found error.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [string] $Identity,
        [string[]] $Properties,
        [string] $Server,
        [pscredential] $Credential
    )

    $sam = $Identity.ToLowerInvariant()
    $user = $script:Users[$sam]
    if (-not $user) {
        $PSCmdlet.ThrowTerminatingError((Get-FakeIdentityError -Identity $Identity -Command 'GetADUser'))
    }
    $display = "$($user.GivenName) $($user.Surname)"
    $dn = "CN=$display,OU=Staff,DC=corp,DC=local"
    [pscustomobject] [ordered] @{
        DistinguishedName  = $dn
        SamAccountName     = $sam
        UserPrincipalName  = "$sam@corp.local"
        Name               = $display
        DisplayName        = $display
        GivenName          = $user.GivenName
        Surname            = $user.Surname
        Department         = $user.Department
        Title              = $user.Title
        Office             = $user.Office
        Company            = 'Corp'
        EmailAddress       = "$sam@corp.example"
        mail               = "$sam@corp.example"
        telephoneNumber    = '+1 555 0100'
        Fax                = $null
        Manager            = 'CN=Morgan Manager,OU=Staff,DC=corp,DC=local'
        MemberOf           = [string[]] @('CN=CAD Users,OU=Groups,DC=corp,DC=local', "CN=$($user.Department),OU=Groups,DC=corp,DC=local")
        Enabled            = $true
        LockedOut          = $false
        whenCreated        = [datetime] '2021-03-15 09:30:00'
        LastLogonDate      = [datetime] '2026-11-03 08:01:00'
        lastLogonTimestamp = [long] 134064648600000000
        badPwdCount        = 0
        ObjectGUID         = [guid]::new(('{0:x8}-0000-4000-8000-000000000000' -f ($sam.GetHashCode() -band 0x7fffffff)))
        SID                = [FakeSecurityIdentifier]::new("S-1-5-21-1004336348-1177238915-682003330-$(1100 + $sam.Length)")
        thumbnailPhoto     = [byte[]] (1..64)
        ObjectClass        = 'user'
    }
}

function Get-ADComputer {
    <#
    .SYNOPSIS
        A workstation (WS-NN) with -Properties * worth of attributes, or the real module's not-found error.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [string] $Identity,
        [string[]] $Properties,
        [string] $Server,
        [pscredential] $Credential
    )

    # Workstations WS-01..WS-99 and ws-NN exist; anything else doesn't.
    if ($Identity -notmatch '^ws-?\d{2}$') {
        $PSCmdlet.ThrowTerminatingError((Get-FakeIdentityError -Identity $Identity -Command 'GetADComputer'))
    }
    $name = $Identity.ToUpperInvariant()
    [pscustomobject] [ordered] @{
        DistinguishedName      = "CN=$name,OU=Workstations,DC=corp,DC=local"
        Name                   = $name
        DNSHostName            = "$($name.ToLowerInvariant()).corp.local"
        Description            = "Engineering workstation $name"
        Location               = 'Building 2'
        OperatingSystem        = 'Windows 11 Enterprise'
        OperatingSystemVersion = '10.0 (26100)'
        ManagedBy              = 'CN=Desktop Support,OU=Groups,DC=corp,DC=local'
        Enabled                = $true
        IPv4Address            = '10.20.30.40'
        whenCreated            = [datetime] '2024-01-10 12:00:00'
        LastLogonDate          = [datetime] '2026-11-04 07:45:00'
        ObjectGUID             = [guid]::new('11111111-2222-4333-8444-555555555555')
        ObjectClass            = 'computer'
    }
}

Export-ModuleMember -Function Get-ADUser, Get-ADComputer

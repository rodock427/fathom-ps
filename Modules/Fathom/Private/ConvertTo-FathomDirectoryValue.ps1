function ConvertTo-FathomDirectoryValue {
    <#
    .SYNOPSIS
        A directory attribute value as something JSON can hold: text, number, true/false or a list.
    .DESCRIPTION
        Dates become ISO text; SIDs, GUIDs and other objects their text form; multi-valued
        attributes a list. Binary values (photos, certificates) return nothing: never recorded.
    #>
    [CmdletBinding()]
    [OutputType([string], [object[]], [bool], [ValueType])]
    param([AllowNull()] $Value)

    if ($null -eq $Value -or $Value -is [byte[]]) {
        return
    }
    if ($Value -is [datetime]) {
        return $Value.ToString('s')
    }
    # Text, numbers and true/false as they are; enums and GUIDs fall through to their text form.
    if ($Value -is [string] -or ($Value -is [ValueType] -and $Value -isnot [enum] -and $Value -isnot [guid])) {
        return $Value
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        # The comma keeps a one-item list a list.
        return , @($Value | ForEach-Object { ConvertTo-FathomDirectoryValue -Value $_ })
    }
    [string] $Value
}

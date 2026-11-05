function Export-FathomReport {
    <#
    .SYNOPSIS
        Writes a report from Get-FathomReport to a .csv file, or to an .xlsx workbook with its charts.
    .DESCRIPTION
        Excel needs the ImportExcel module. It's loaded here, not required by Fathom, so that a server
        without it only loses this export. Text that a spreadsheet would run as a formula is quoted:
        usernames and hosts come from whoever ran a license client.
    .EXAMPLE
        Get-FathomReport -Name usage-history | Export-FathomReport -Path ./usage.xlsx
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [PSTypeName('Fathom.Report')] $Report,

        [Parameter(Mandatory)]
        [ValidatePattern('\.(csv|xlsx)$')]
        [string] $Path
    )

    process {
        $excel = $Path.EndsWith('.xlsx')
        $rows = foreach ($row in $Report.Rows) {
            $cells = [ordered] @{}
            foreach ($property in $Report.Columns.Keys) {
                $value = $row.$property
                if ($value -is [string] -and $value -match '^[=+\-@\t\r]') {
                    $value = "'$value"
                } elseif ($value -is [datetime] -and -not $excel) {
                    $value = $value.ToString('yyyy-MM-dd HH:mm')
                }
                $cells[$Report.Columns[$property]] = $value
            }
            [pscustomobject] $cells
        }

        if (-not $excel) {
            # With a byte order mark, or Excel reads the file as the machine's old code page.
            $rows | Export-Csv -LiteralPath $Path -Encoding utf8BOM -NoTypeInformation
            return
        }

        try {
            Import-Module -Name ImportExcel -ErrorAction Stop 3> $null
        } catch {
            throw 'Excel export needs the ImportExcel module on the PSU server. CSV export works without it.'
        }
        Remove-Item -LiteralPath $Path -ErrorAction Ignore

        # Text stays text: a host called 1E5 is not a number, and a path is not a link.
        $sheet = @{
            Path                  = $Path
            WorksheetName         = 'Report'
            TableName             = 'ReportData'
            StartRow              = 4
            NoNumberConversion    = '*'
            NoHyperLinkConversion = '*'
            PassThru              = $true
        }
        $package = $rows | Export-Excel @sheet
        $worksheet = $package.Workbook.Worksheets['Report']
        # Text set directly is never taken for a formula, whatever a feature is called.
        $worksheet.Cells['A1'].Value = $Report.Title
        $worksheet.Cells['A1'].Style.Font.Bold = $true
        $worksheet.Cells['A1'].Style.Font.Size = 16
        $worksheet.Cells['A2'].Value = $Report.Summary

        # Column widths by hand: ImportExcel's -AutoSize needs libgdiplus on Linux.
        $headerRow = $worksheet.Tables[0].Address.Start.Row
        $names = @($rows[0].PSObject.Properties.Name)
        foreach ($index in 0..($names.Count - 1)) {
            $name = $names[$index]
            $dates = $rows[0].$name -is [datetime]
            $longest = ($rows.$name | ForEach-Object { ([string] $_).Length } | Measure-Object -Maximum).Maximum
            $column = $worksheet.Column($index + 1)
            $column.Width = [Math]::Min(48, [Math]::Max($name.Length, $dates ? 16 : $longest) + 3)
            if ($dates) {
                $column.Style.Numberformat.Format = 'yyyy-mm-dd hh:mm'
            }
        }
        $worksheet.View.FreezePanes($headerRow + 1, 1)

        if ($Report.Charts) {
            # Charts read a sheet of their own, so each can have its own points in its own order.
            $charts = Add-Worksheet -ExcelPackage $package -WorksheetName 'Charts'
            $start = 1
            $position = 0
            foreach ($chart in $Report.Charts) {
                $data = @{ ExcelPackage = $package; WorksheetName = 'Chart data'; StartRow = $start; NoNumberConversion = '*'; PassThru = $true }
                $package = $chart.Points | Export-Excel @data
                $first = $start + 1
                $last = $start + $chart.Points.Count
                $yRanges = @(foreach ($index in 0..($chart.Series.Count - 1)) {
                        $letter = [char] ([int] [char] 'B' + $index)
                        "'Chart data'!`$$letter`$$first`:`$$letter`$$last"
                    })
                $drawing = @{
                    Worksheet    = $charts
                    ChartType    = $chart.Type
                    Title        = $chart.Title
                    XRange       = "'Chart data'!`$A`$$first`:`$A`$$last"
                    YRange       = $yRanges
                    SeriesHeader = $chart.Series
                    YMinValue    = 0
                    # Two across, in the order the features were picked.
                    Row          = [Math]::Floor($position / 2) * 18
                    Column       = ($position % 2) * 11
                    Width        = 720
                    Height       = 340
                }
                Add-ExcelChart @drawing
                $start = $last + 2
                $position++
            }
        }
        Close-ExcelPackage $package
    }
}

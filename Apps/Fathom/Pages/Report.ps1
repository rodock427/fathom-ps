# One standard report: its own options, a preview, and CSV and Excel exports. The options live in
# the URL, so a report can be bookmarked or sent to a colleague. Operators only.
. "$PSScriptRoot/../Common.ps1"

if (-not (Test-FathomAccess -Tier Operator -Role $Roles)) {
    return New-FathomNotAuthorized
}

$definition = Get-FathomReportCatalog -Name $reportName
if (-not $definition) {
    return New-UDAlert -Id 'report-unknown' -Severity info -Text 'There is no such report.'
}

$run = @{ Name = $definition.Name; Option = $Query }
$window = @{}
if ($definition.Presets) {
    $timeframe = Get-FathomTimeframe -Query $Query -Presets $definition.Presets -DefaultDays $definition.DefaultDays
    $run.From = $timeframe.From
    $run.To = $timeframe.To
    $window = $timeframe.Query
}

Use-FathomDatabase {
    $report = Get-FathomReport @run
    $optionNames = @($definition.Options.Name)
    # The options as the URL carries them: empty ones left out, several values joined.
    $chosen = @{}
    foreach ($name in $optionNames) { $chosen[$name] = $report.Options[$name] -join ',' }

    New-UDTypography -Variant h4 -Text $report.Title -GutterBottom
    New-UDTypography -Variant body2 -Text $definition.Description -GutterBottom

    New-UDCard -Id 'report-options' -Title 'Options' -Content {
        if ($definition.Presets) {
            New-FathomTimeframePicker -Timeframe $timeframe -Presets $definition.Presets -Page "reports/$reportName" -Keep $chosen
        }
        $kinds = @($definition.Options.Kind)
        $features = if ('Feature' -in $kinds -or 'Features' -in $kinds) {
            @(Get-FathomAvailability | Select-Object -ExpandProperty Feature | Sort-Object -Unique)
        }
        New-UDForm -Id 'report-form' -SubmitText 'Run report' -Children {
            New-UDGrid -Container -Spacing 2 -Children {
                foreach ($spec in $definition.Options) {
                    New-UDGrid -Item -ExtraSmallSize 12 -MediumSize 6 -LargeSize 4 -Children {
                        $value = $report.Options[$spec.Name]
                        switch ($spec.Kind) {
                            'Server' {
                                New-UDSelect -Id $spec.Name -Label $spec.Label -FullWidth -DefaultValue ($value ? $value : 'all') -Option {
                                    New-UDSelectOption -Name 'All servers' -Value 'all'
                                    foreach ($server in Get-FathomServer | Sort-Object Name) {
                                        New-UDSelectOption -Name $server.Name -Value $server.ServerId
                                    }
                                }
                            }
                            'Choice' {
                                New-UDSelect -Id $spec.Name -Label $spec.Label -FullWidth -DefaultValue $value -Option {
                                    foreach ($choice in $spec.Choices.GetEnumerator()) {
                                        New-UDSelectOption -Name $choice.Value -Value $choice.Key
                                    }
                                }
                            }
                            'Number' {
                                New-UDTextbox -Id $spec.Name -Label $spec.Label -Type number -FullWidth -Value $value -Minimum $spec.Minimum -Maximum $spec.Maximum
                            }
                            'Feature' {
                                New-UDAutocomplete -Id $spec.Name -Label $spec.Label -FullWidth -Options $features -Value $value
                            }
                            'Features' {
                                New-UDAutocomplete -Id $spec.Name -Label $spec.Label -FullWidth -Options $features -Value $value -Multiple
                            }
                        }
                    }
                }
            }
        } -OnSubmit {
            $target = @{} + $window
            foreach ($name in $optionNames) {
                $value = $EventData.$name -join ','
                if ($value -ne 'all') { $target[$name] = $value }
            }
            Invoke-UDRedirect -Url "reports/$reportName`?$(ConvertTo-FathomQueryString $target)"
        }
    }

    New-UDStack -Direction row -Spacing 1 -AlignItems center -Children {
        foreach ($extension in 'csv', 'xlsx') {
            $text = if ($extension -eq 'csv') { 'Export CSV' } else { 'Export Excel' }
            New-UDButton -Id "report-export-$extension" -Text $text -Variant outlined -Icon (New-UDIcon -Icon 'download') -Disabled:(-not $report.Rows) -OnClick {
                if (-not (Test-FathomAccess -Tier Operator -Role $Roles)) { return }
                $name = '{0}-{1:yyyy-MM-dd}.{2}' -f $definition.Name, (Get-Date), $extension
                # PSU serves the file when the browser asks for it, so it can't be deleted here. It
                # stays in the service account's own folder, not the shared temp one, for an hour.
                $folder = Join-Path -Path ([Environment]::GetFolderPath('LocalApplicationData')) -ChildPath 'Fathom/exports'
                $null = New-Item -ItemType Directory -Path $folder -Force
                Get-ChildItem -LiteralPath $folder -File | Where-Object LastWriteTime -LT (Get-Date).AddHours(-1) | Remove-Item
                $path = Join-Path -Path $folder -ChildPath "$([guid]::NewGuid())-$name"
                try {
                    Use-FathomDatabase { Get-FathomReport @run | Export-FathomReport -Path $path }
                    Start-UDDownload -Path $path -FileName $name
                } catch {
                    Show-UDToast -Message $_.Exception.Message -Duration 8000
                }
            }
        }
        if ($report.Charts) {
            New-UDTypography -Variant body2 -Text "The Excel export includes $(@($report.Charts).Count) chart(s)."
        }
    }

    # Exports hold every row; the browser gets a sample, with dates as the other pages show them.
    # ponytail: 1,000 rows here keeps a year of usage history from swamping the page.
    $previewLimit = 1000
    $rows = foreach ($row in $report.Rows | Select-Object -First $previewLimit) {
        $cells = [ordered] @{}
        foreach ($property in $report.Columns.Keys) {
            $value = $row.$property
            $cells[$property] = if ($value -is [datetime]) { Format-FathomTime $value } else { $value }
        }
        [pscustomobject] $cells
    }
    if ($report.Rows.Count -gt $previewLimit) {
        New-UDTypography -Id 'report-preview-note' -Variant body2 -Text "Showing the first $previewLimit of $($report.Rows.Count) rows. The exports hold them all."
    }
    New-FathomTable -Id "report-$($definition.Name)" -Data $rows -Columns $report.Columns -Empty $definition.Empty
}

@{
    Severity = @('Error', 'Warning', 'Information')

    Rules    = @{
        # Formatting: one consistent style everywhere (OTBS, 4-space indent).
        PSPlaceOpenBrace           = @{
            Enable             = $true
            OnSameLine         = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
        }
        PSPlaceCloseBrace          = @{
            Enable             = $true
            NewLineAfter       = $false
            IgnoreOneLineBlock = $true
            NoEmptyLineBefore  = $false
        }
        PSUseConsistentIndentation = @{
            Enable              = $true
            Kind                = 'space'
            IndentationSize     = 4
            PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
        }
        PSUseConsistentWhitespace  = @{
            Enable                                  = $true
            CheckInnerBrace                         = $true
            CheckOpenBrace                          = $true
            CheckOpenParen                          = $true
            CheckOperator                           = $true
            CheckPipe                               = $true
            CheckSeparator                          = $true
            CheckParameter                          = $true
            # Let PSAlignAssignmentStatement line up '=' in hashtables.
            IgnoreAssignmentOperatorInsideHashTable = $true
        }
        PSAlignAssignmentStatement = @{
            Enable         = $true
            CheckHashtable = $true
        }
        PSUseCorrectCasing         = @{ Enable = $true }

        # Every exported command carries help.
        PSProvideCommentHelp       = @{
            Enable       = $true
            ExportedOnly = $true
            BlockComment = $true
            Placement    = 'begin'
        }
    }
}

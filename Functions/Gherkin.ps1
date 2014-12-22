Add-Type -Path "${Script:PesterRoot}\lib\PowerCuke.dll"

$StepPrefix = "Gherkin-Step "
$GherkinSteps = @{}

function Invoke-Gherkin {
    <#
        .SYNOPSIS
            Invoke testing of .feature files
        .DESCRIPTION
            By default, tests all .feature files in the current folder and child folders recursively.
    #>
    [CmdletBinding(DefaultParameterSetName = 'NewTest')]
    param(
        # Rerun only the scenarios which failed last time
        [Parameter(Mandatory = $True, ParameterSetName = "RetestFailed")]
        [switch]$FailedLast,

        [Parameter(Position=0,Mandatory=0)]
        [Alias('relative_path')]
        [string]$Path = $Pwd,

        [Parameter(Position=1,Mandatory=0)]
        [Alias("Name")]
        [string[]]$ScenarioName,

        [Parameter(Position=2,Mandatory=0)]
        [switch]$EnableExit,

        [Parameter(Position=3,Mandatory=0)]
        [string]$OutputXml,

        [Parameter(Position=4,Mandatory=0)]
        [Alias('Tags')]
        [string[]]$Tag,

        [object[]] $CodeCoverage = @(),

        [switch]$PassThru
    )
    begin {
        Import-LocalizedData -BindingVariable Script:ReportStrings -BaseDirectory $PesterRoot -FileName Gherkin.psd1
    }

    end {

        if($PSCmdlet.ParameterSetName -eq "RetestFailed") {
            if((Test-Path variable:script:pester) -and $script:Pester.FailedScenarios.Count -gt 0 ) {
                $ScenarioName = $Pester.FailedScenarios | Select-Object -Expand Name
            }
            else {
                throw "There's no existing failed tests to re-run"
            }
        }

        # Clear mocks
        $script:mockTable = @{}

        $Script:pester = New-PesterState -Path (Resolve-Path $Path) -TestNameFilter $ScenarioName -TagFilter @($Tag -split "\s+") -SessionState $PSCmdlet.SessionState |
            Add-Member -MemberType NoteProperty -Name Features -Value (New-Object System.Collections.Generic.List[PoshCode.PowerCuke.ObjectModel.Feature]) -PassThru |
            Add-Member -MemberType ScriptProperty -Name FailedScenarios -Value {
                $Names = $this.TestResult | Group Context | Where { $_.Group | Where { -not $_.Passed } } | Select-Object -Expand Name
                $this.Features.Scenarios | Where { $Names -contains $_.Name }
            } -PassThru |
            Add-Member -MemberType ScriptProperty -Name PassedScenarios -Value {
                $Names = $this.TestResult | Group Context | Where { -not ($_.Group | Where { -not $_.Passed }) } | Select-Object -Expand Name
                $this.Features.Scenarios | Where { $Names -contains $_.Name }
            } -PassThru

        Write-PesterStart $pester

        Enter-CoverageAnalysis -CodeCoverage $CodeCoverage -PesterState $pester

        # Remove all the steps
        $Script:GherkinSteps.Clear()
        # Import all the steps (we're going to need them in a minute)
        $StepFiles = Get-ChildItem (Split-Path $pester.Path) -Filter "*.steps.ps1" -Recurse
        foreach($StepFile in $StepFiles){
            . $StepFile.FullName
        }
        Write-Host "Loaded $($Script:GherkinSteps.Count) step definitions from $(@($StepFiles).Count) steps file(s)"

        foreach($FeatureFile in Get-ChildItem $pester.Path -Filter "*.feature" -Recurse ) {
            $Feature = [PoshCode.PowerCuke.Parser]::Parse((gc $FeatureFile -Delim ([char]0)))
            $null = $Pester.Features.Add($Feature)

            ## This is Pesters "Describe" function
            $Pester.EnterDescribe($Feature)
            New-TestDrive

            $Scenarios = $Feature.Scenarios

            if($pester.TagFilter) {
                $Scenarios = $Scenarios | Where { Compare-Object $_.Tags $pester.TagFilter -IncludeEqual -ExcludeDifferent }
            }
            if($pester.TestNameFilter) {
                $Scenarios = foreach($nameFilter in $pester.TestNameFilter) {
                    $Scenarios | Where { $_.Name -like $NameFilter }
                }
                $Scenarios = $Scenarios | Get-Unique
            }

            if($Scenarios) {
                Write-Describe $Feature
            }

            foreach($Scenario in $Scenarios) {
                # This is Pester's Context function
                $Pester.EnterContext($Scenario.Name)
                $TestDriveContent = Get-TestDriveChildItem

                Invoke-GherkinScenario $Pester $Scenario $Feature.Background

                Clear-TestDrive -Exclude ($TestDriveContent | select -ExpandProperty FullName)
                $Pester.LeaveContext()
            }

            ## This is Pesters "Describe" function again
            Remove-TestDrive
            Exit-MockScope
            $Pester.LeaveDescribe()
        }

        # Remove all the steps
        foreach($StepFile in Get-ChildItem $pester.Path -Filter "*.steps.psm1" -Recurse){
            $Script:GherkinSteps.Clear()
            # Remove-Module $StepFile.BaseName
        }
        $pester | Write-PesterReport
        $coverageReport = Get-CoverageReport -PesterState $pester
        Write-CoverageReport -CoverageReport $coverageReport
        Exit-CoverageAnalysis -PesterState $pester

        if($OutputXml) {
            #TODO make this legacy option and move the nUnit report out of invoke-pester
            #TODO add warning message that informs the user how to use the nunit output properly
            Export-NunitReport $pester $OutputXml
        }

        if ($PassThru) {
            # Remove all runtime properties like current* and Scope
            $properties = @(
                "Path","TagFilter","TestNameFilter","TotalCount","PassedCount","FailedCount","Time","TestResult","PassedScenarios","FailedScenarios"

                if ($CodeCoverage)
                {
                    @{ Name = 'CodeCoverage'; Expression = { $coverageReport } }
                }
            )
            $pester | Select -Property $properties
        }
        if ($EnableExit) { Exit-WithCode -FailedCount $pester.FailedCount }
    }
}

function Invoke-GherkinScenario {
    [CmdletBinding()]
    param(
        $Pester, $Scenario, $Background, [Switch]$Quiet
    )

    if(!$Quiet) { Write-Context $Scenario }
    if($Background) {
        Invoke-GherkinScenario $Pester $Background -Quiet
    }

    $TableSteps =   if($Scenario.Examples) {
                        foreach($ExampleSet in $Scenario.Examples) {
                            $Names = $ExampleSet | Get-Member -Type Properties | Select -Expand Name
                            $NamesPattern = "<(?:" + ($Names -join "|") + ")>"
                            foreach($Example in $ExampleSet) {
                                foreach ($Step in $Scenario.Steps) {
                                    $StepName = $Step.Name
                                    if($StepName -match $NamesPattern) {
                                        foreach($Name in $Names) {
                                            if($Example.$Name -and $StepName -match "<${Name}>") {
                                                $StepName = $StepName -replace "<${Name}>", $Example.$Name
                                            }
                                        }
                                    }
                                    if($StepName -ne $Step.Name) {
                                        $S = New-Object PoshCode.PowerCuke.ObjectModel.Step $Step
                                        $S.Name = $StepName
                                        $S
                                    } else {
                                        $Step
                                    }
                                }
                            }
                        }
                    } else {
                        $Scenario.Steps
                    }

    foreach($Step in $TableSteps) {
        Invoke-GherkinStep $Pester $Step
    }
}


function Invoke-GherkinStep {
    [CmdletBinding()]
    param (
        $Pester, $Step
    )
    #  Pick the match with the least grouping wildcards in it...
    $StepCommand = $(
        foreach($StepCommand in $Script:GherkinSteps.Keys) {
            if($Step.Name -match "^${StepCommand}$") {
                $StepCommand | Add-Member MatchCount $Matches.Count -PassThru
            }
        }
    ) | Sort MatchCount | Select -First 1
    $StepName = "{0} {1}" -f $Step.Keyword, $Step.Name

    if(!$StepCommand) {
        $Pester.AddTestResult($Step.Name, $False, $null, "Could not find test for step!", $null )
    } else {
        $NamedArguments, $Parameters = Get-StepParameters $Step $StepCommand

        $Pester.EnterTest($StepName)
        $PesterException = $null
        $watch = New-Object System.Diagnostics.Stopwatch
        $watch.Start()
        try{
            if($NamedArguments.Count) {
                $ScriptBlock = { & $Script:GherkinSteps.$StepCommand @NamedArguments @Parameters }
            } else {
                $ScriptBlock = { & $Script:GherkinSteps.$StepCommand @Parameters }
            }
            # Set-ScriptBlockScope -ScriptBlock $scriptBlock -SessionState $PSCmdlet.SessionState
            $null = & $ScriptBlock
            $Success = $True
        } catch {
            $Success = $False
            $PesterException = $_
        }

        $watch.Stop()
        $Pester.LeaveTest()


        # if($PesterException) {
        #     if ($PesterException.FullyQualifiedErrorID -eq 'PesterAssertionFailed')
        #     {
        #         $failureMessage = $PesterException.exception.message  -replace "Exception calling", "Assert failed on"
        #         $stackTrace = $PesterException.ScriptStackTrace # -split "`n")[3] #-replace "<No File>:"
        #     }
        #     else {
        #         $failureMessage = $PesterException.ToString()
        #         $stackTrace = ($PesterException.ScriptStackTrace -split "`n")[0]
        #     }

        #     $Pester.AddTestResult($name, $False, $null, $failureMessage, $stackTrace)
        # } else {
        #     $Pester.AddTestResult($name, $True, $null, $null, $null )
        # }

        $Pester.AddTestResult($StepName, $Success, $watch.Elapsed, $PesterException.Exception.Message, ($PesterException.ScriptStackTrace -split "`n")[1] )
    }

    $Pester.testresult[-1] | Write-PesterResult
}

function Get-StepParameters {
    param($Step, $CommandName)
    $Null = $Step.Name -match $CommandName

    $NamedArguments = @{}
    $Parameters = @{}
    foreach($kv in $Matches.GetEnumerator()) {
        switch ($kv.Name -as [int]) {
            0       {  } # toss zero (where it matches the whole string)
            $null   { $NamedArguments.($kv.Name) = $ExecutionContext.InvokeCommand.ExpandString($kv.Value)       }
            default { $Parameters.([int]$kv.Name) = $ExecutionContext.InvokeCommand.ExpandString($kv.Value) }
        }
    }
    $Parameters = @($Parameters.GetEnumerator() | Sort Name | Select -Expand Value)

    if($Step.TableArgument) {
        $NamedArguments.Table = $Step.TableArgument
    }
    if($Step.DocStringArgument) {
        # trim empty matches if we're attaching DocStringArgument
        $Parameters = @( $Parameters | Where { $_.Length } ) + $Step.DocStringArgument
    }

    return @($NamedArguments, $Parameters)
}
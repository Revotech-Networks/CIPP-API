BeforeAll {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $ActivityPath = Join-Path $RepoRoot 'Modules/CIPPActivityTriggers/Public/Entrypoints/Activity Triggers'

    function Get-CippTable { param($TableName) }
    function Get-AzDataTableEntity { param($Context, $Filter) }
    function Update-AzDataTableEntity { param($Context, $Entity, [switch]$Force) }
    function Add-CIPPAzDataTableEntity { param($Context, $Entity, [switch]$Force) }
    function Get-DeltaQueryUrl { param($TenantFilter, $PartitionKey) }
    function New-GraphDeltaQuery { param($DeltaUrl, $TenantFilter, $PartitionKey) }
    function Test-DeltaQueryConditions { param($Query, $Trigger, $TenantFilter, $LastTrigger) }
    function Get-CippException { param($Exception) }
    function Write-LogMessage { param($API, $Tenant, $TenantId, $Message, $Sev, $LogData, $Headers) }
    function Set-CippScheduledTaskContext { param($TaskId) }
    function Set-CippUserAgentContext { param($Headers, $Source, $TaskId) }
    function Get-Tenants { param($TenantFilter) }
    function Get-CIPPSchedulerBlockedCommands { }
    function Send-CIPPScheduledTaskAlert { param($Results, $TaskInfo, $TenantFilter, $TaskType, $Attachments) }
    function Clear-CIPPImmutableID { param($UserID, $TenantFilter) }
    function Get-CIPPAlertTest { param($TenantFilter) }
    function Invoke-CIPPOffboardingJob { param($TenantFilter, $TaskInfo) }

    . (Join-Path $ActivityPath 'Push-ExecScheduledCommand.ps1')
    . (Join-Path $ActivityPath 'Push-ScheduledTaskPostExecution.ps1')

    function New-SchedulerTestItem {
        param([string]$Recurrence = '0', [switch]$PerResource, [switch]$MultiTenant)
        $Task = [PSCustomObject]@{
            PartitionKey  = 'ScheduledTask'
            RowKey        = 'task-test'
            Name          = 'Offline scheduler test'
            Tenant        = $(if ($MultiTenant) { 'AllTenants' } else { 'contoso.example' })
            Recurrence    = $Recurrence
            ScheduledTime = [string]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 3600)
            PostExecution = 'email'
            Trigger       = $null
        }
        if ($PerResource) {
            $Task.Trigger = @{ Type = 'DeltaQuery'; ExecutePerResource = $true; ExecutionMode = 'always' } |
                ConvertTo-Json -Compress -Depth 10
        }
        [PSCustomObject]@{
            Command    = 'Clear-CIPPImmutableID'
            Parameters = @{ TenantFilter = 'contoso.example'; UserID = '%id%' }
            TaskInfo   = $Task
        }
    }
}

Describe 'Push-ExecScheduledCommand outcomes' {
    BeforeEach {
        $script:TaskWrites = [System.Collections.Generic.List[object]]::new()
        $script:ResultWrites = [System.Collections.Generic.List[object]]::new()
        Mock Get-CippTable { @{ Context = $TableName } }
        Mock Get-AzDataTableEntity { [PSCustomObject]@{ TaskState = 'Pending' } }
        Mock Update-AzDataTableEntity { $script:TaskWrites.Add($Entity) }
        Mock Add-CIPPAzDataTableEntity { $script:ResultWrites.Add($Entity) }
        Mock Write-LogMessage { }
        Mock Set-CippScheduledTaskContext { }
        Mock Set-CippUserAgentContext { }
        Mock Send-CIPPScheduledTaskAlert { }
        Mock Get-CIPPSchedulerBlockedCommands { @() }
        Mock Get-Tenants { [PSCustomObject]@{ customerId = 'tenant-test' } }
        Mock Get-CippException { @{ NormalizedError = $Exception.Exception.Message } }
        Mock Get-DeltaQueryUrl { 'https://offline.example/delta' }
        Mock New-GraphDeltaQuery { @{ value = @() } }
        Mock Test-DeltaQueryConditions {
            @{ ConditionsMet = $true; MatchedData = @(@{ id = 'bad' }, @{ id = 'good' }) }
        }
        Mock Clear-CIPPImmutableID { 'cleared' }
        Mock Get-CIPPAlertTest { 'synthetic alert' }
        Mock Invoke-CIPPOffboardingJob { 'orchestration dispatched' }
        Mock Get-Command -ParameterFilter {
            $Name -in @('Clear-CIPPImmutableID', 'Get-CIPPAlertTest', 'Invoke-CIPPOffboardingJob')
        } -MockWith {
            [PSCustomObject]@{
                Name = $Name; Module = 'CIPPCore'; Parameters = @{ TenantFilter = 1; UserID = 1 }
            }
        }
    }

    It 'persists a throwing ordinary task with recurrence <Recurrence> as <ExpectedState>' -ForEach @(
        @{ Recurrence = '0'; ExpectedState = 'Failed'; Seconds = 0 }
        @{ Recurrence = ''; ExpectedState = 'Failed'; Seconds = 0 }
        @{ Recurrence = '15m'; ExpectedState = 'Failed - Planned'; Seconds = 900 }
        @{ Recurrence = '1'; ExpectedState = 'Failed - Planned'; Seconds = 86400 }
    ) {
        Mock Clear-CIPPImmutableID { throw 'synthetic command failure' }
        $Item = New-SchedulerTestItem -Recurrence $Recurrence

        $Result = Push-ExecScheduledCommand -Item $Item

        $Final = $script:TaskWrites[-1]
        $Final.TaskState | Should -Be $ExpectedState
        $Final.Results | Should -BeLike '*synthetic command failure*'
        $Result | Should -Be 'Task Failed.'
        if ($Seconds) {
            [int64]$Final.ScheduledTime | Should -Be ([int64]$Item.TaskInfo.ScheduledTime + $Seconds)
        }
        Should -Invoke Write-LogMessage -Times 0 -Exactly -ParameterFilter { $Message -like 'Successfully executed task:*' }
        Should -Invoke Send-CIPPScheduledTaskAlert -Times 1 -Exactly -ParameterFilter {
            ($Results | ConvertTo-Json -Compress -Depth 10) -like '*synthetic command failure*'
        }
    }

    It 'preserves resource successes and errors with <ResultKind> output and failure <FailurePosition>' -ForEach @(
        @{ ResultKind = 'string'; FailurePosition = 'first'; ResourceIds = @('bad', 'good') }
        @{ ResultKind = 'string'; FailurePosition = 'last'; ResourceIds = @('good', 'bad') }
        @{ ResultKind = 'object'; FailurePosition = 'first'; ResourceIds = @('bad', 'good') }
        @{ ResultKind = 'object'; FailurePosition = 'last'; ResourceIds = @('good', 'bad') }
    ) {
        $script:ResourceIds = $ResourceIds
        $script:ResultKind = $ResultKind
        Mock Test-DeltaQueryConditions {
            @{ ConditionsMet = $true; MatchedData = @($script:ResourceIds | ForEach-Object { @{ id = $_ } }) }
        }
        Mock Clear-CIPPImmutableID {
            if ($UserID -eq 'bad') { throw 'synthetic resource failure' }
            if ($script:ResultKind -eq 'object') { [PSCustomObject]@{ UserId = $UserID; Outcome = 'cleared good' } } else { 'cleared good' }
        }

        $Result = Push-ExecScheduledCommand -Item (New-SchedulerTestItem -Recurrence '15m' -PerResource)

        $Final = $script:TaskWrites[-1]
        $Final.TaskState | Should -Be 'Failed - Planned'
        $Final.Results | Should -BeLike '*synthetic resource failure*'
        $Final.Results | Should -BeLike '*cleared good*'
        @($Final.Results | ConvertFrom-Json).Count | Should -Be 2
        $Result | Should -Be 'Task Failed.'
        Should -Invoke Clear-CIPPImmutableID -Times 2 -Exactly
        Should -Invoke Write-LogMessage -Times 0 -Exactly -ParameterFilter { $Message -like 'Successfully executed task:*' }
    }

    It 'returns failure for aggregation without updating the multi-tenant parent' {
        Mock Clear-CIPPImmutableID { throw 'synthetic tenant failure' }
        $Item = New-SchedulerTestItem -MultiTenant

        $Result = Push-ExecScheduledCommand -Item $Item

        $script:TaskWrites.Count | Should -Be 0
        $script:ResultWrites.Count | Should -Be 1
        $script:ResultWrites[0].Results | Should -BeLike '*synthetic tenant failure*'
        $script:ParentTask = $Item.TaskInfo
        Mock Get-AzDataTableEntity { $script:ParentTask }
        $Aggregate = Push-ScheduledTaskPostExecution -Item @{
            Parameters = @{ TaskRowKey = 'task-test' }
            Results = @($Result)
        }
        $Aggregate.SuccessCount | Should -Be 0
        $Aggregate.FailureCount | Should -Be 1
        $Aggregate.TaskState | Should -Be 'Failed'
    }

    It 'does not overwrite a result-storage failure with success' {
        Mock Add-CIPPAzDataTableEntity { throw 'synthetic result-storage failure' }

        $Result = Push-ExecScheduledCommand -Item (New-SchedulerTestItem -MultiTenant)

        $Result | Should -Be 'Task Failed.'
        $script:TaskWrites.Count | Should -Be 0
        Should -Invoke Write-LogMessage -Times 1 -Exactly -ParameterFilter {
            $Sev -eq 'Error' -and $Message -like '*synthetic result-storage failure*'
        }
        Should -Invoke Write-LogMessage -Times 0 -Exactly -ParameterFilter { $Message -like 'Successfully executed task:*' }
    }

    It 'keeps a fired once trigger terminal after <FailureStage> fails (<ModeShape>)' -ForEach @(
        @{ FailureStage = 'storage'; ModeShape = 'string'; ExecutionMode = 'once' }
        @{ FailureStage = 'storage'; ModeShape = 'value object'; ExecutionMode = @{ value = 'once' } }
        @{ FailureStage = 'serialization'; ModeShape = 'string'; ExecutionMode = 'once' }
        @{ FailureStage = 'serialization'; ModeShape = 'value object'; ExecutionMode = @{ value = 'once' } }
    ) {
        Mock Clear-CIPPImmutableID { 'x' * 70000 }
        $script:PostCommandError = "synthetic $FailureStage failure"
        if ($FailureStage -eq 'storage') {
            Mock Add-CIPPAzDataTableEntity { throw $script:PostCommandError }
        } else {
            Mock ConvertTo-Json -ParameterFilter { $Depth -eq 20 } -MockWith { throw $script:PostCommandError }
        }
        $Item = New-SchedulerTestItem -Recurrence '15m' -PerResource
        $Item.TaskInfo.Trigger = @{ Type = 'DeltaQuery'; ExecutePerResource = $true; ExecutionMode = $ExecutionMode } |
            ConvertTo-Json -Compress -Depth 10

        $Result = Push-ExecScheduledCommand -Item $Item

        Should -Invoke Clear-CIPPImmutableID -Times 2 -Exactly
        $script:TaskWrites[-1].TaskState | Should -Be 'Failed'
        $script:TaskWrites[-1].Results | Should -Be $script:PostCommandError
        $Result | Should -Be 'Task Failed.'
        Should -Invoke Write-LogMessage -Times 0 -Exactly -ParameterFilter { $Message -like 'Successfully executed task:*' }
    }

    It 'preserves ordinary recurrence <Recurrence> after <FailureStage> fails' -ForEach @(
        @{ Recurrence = '15m'; Seconds = 900; FailureStage = 'storage' }
        @{ Recurrence = '1'; Seconds = 86400; FailureStage = 'serialization' }
    ) {
        Mock Clear-CIPPImmutableID { 'x' * 70000 }
        $script:PostCommandError = "synthetic $FailureStage failure"
        if ($FailureStage -eq 'storage') {
            Mock Add-CIPPAzDataTableEntity { throw $script:PostCommandError }
        } else {
            Mock ConvertTo-Json -ParameterFilter { $Depth -eq 20 } -MockWith { throw $script:PostCommandError }
        }
        $Item = New-SchedulerTestItem -Recurrence $Recurrence

        $Result = Push-ExecScheduledCommand -Item $Item

        Should -Invoke Clear-CIPPImmutableID -Times 1 -Exactly
        $script:TaskWrites[-1].TaskState | Should -Be 'Failed - Planned'
        [int64]$script:TaskWrites[-1].ScheduledTime | Should -Be ([int64]$Item.TaskInfo.ScheduledTime + $Seconds)
        $script:TaskWrites[-1].Results | Should -Be $script:PostCommandError
        $Result | Should -Be 'Task Failed.'
    }

    It 'keeps a once trigger scheduled when delta lookup fails before execution (<ModeShape>)' -ForEach @(
        @{ ModeShape = 'string'; ExecutionMode = 'once' }
        @{ ModeShape = 'value object'; ExecutionMode = @{ value = 'once' } }
    ) {
        Mock Get-DeltaQueryUrl { throw 'synthetic delta lookup failure' }
        $Item = New-SchedulerTestItem -Recurrence '15m' -PerResource
        $Item.TaskInfo.Trigger = @{ Type = 'DeltaQuery'; ExecutePerResource = $true; ExecutionMode = $ExecutionMode } |
            ConvertTo-Json -Compress -Depth 10

        Push-ExecScheduledCommand -Item $Item | Should -BeNullOrEmpty

        Should -Invoke Clear-CIPPImmutableID -Times 0 -Exactly
        $script:TaskWrites[-1].TaskState | Should -Be 'Failed - Planned'
        [int64]$script:TaskWrites[-1].ScheduledTime | Should -Be ([int64]$Item.TaskInfo.ScheduledTime + 900)
        $script:TaskWrites[-1].Results | Should -Be 'synthetic delta lookup failure'
    }

    It 'preserves ordinary success with recurrence <Recurrence>' -ForEach @(
        @{ Recurrence = '0'; ExpectedState = 'Completed' }
        @{ Recurrence = '15m'; ExpectedState = 'Planned' }
    ) {
        $Result = Push-ExecScheduledCommand -Item (New-SchedulerTestItem -Recurrence $Recurrence)

        $script:TaskWrites[-1].TaskState | Should -Be $ExpectedState
        $script:TaskWrites[-1].Results | Should -BeLike '*cleared*'
        $Result | Should -Be 'Task Completed Successfully.'
        Should -Invoke Write-LogMessage -Times 1 -Exactly -ParameterFilter { $Message -like 'Successfully executed task:*' }
    }

    It 'preserves successful per-resource execution' {
        $Result = Push-ExecScheduledCommand -Item (New-SchedulerTestItem -Recurrence '15m' -PerResource)

        $script:TaskWrites[-1].TaskState | Should -Be 'Planned'
        $Result | Should -Be 'Task Completed Successfully.'
        Should -Invoke Clear-CIPPImmutableID -Times 2 -Exactly
    }

    It 'keeps fired once triggers terminal when the command fails' {
        Mock Clear-CIPPImmutableID { throw 'synthetic resource failure' }
        $Item = New-SchedulerTestItem -Recurrence '15m' -PerResource
        $Item.TaskInfo.Trigger = '{"Type":"DeltaQuery","ExecutePerResource":true,"ExecutionMode":{"value":"once"}}'

        $Result = Push-ExecScheduledCommand -Item $Item

        $script:TaskWrites[-1].TaskState | Should -Be 'Failed'
        $script:TaskWrites[-1].ContainsKey('ScheduledTime') | Should -BeFalse
        $Result | Should -Be 'Task Failed.'
    }

    It 'preserves skipped <Reason> tasks' -ForEach @(
        @{ Reason = 'completed' }
        @{ Reason = 'recently executed' }
    ) {
        $Item = New-SchedulerTestItem
        if ($Reason -eq 'completed') {
            Mock Get-AzDataTableEntity { [PSCustomObject]@{ TaskState = 'Completed' } }
        } else {
            $Item.TaskInfo | Add-Member ExecutedTime ([string][DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
        }

        Push-ExecScheduledCommand -Item $Item | Should -BeNullOrEmpty

        $script:TaskWrites.Count | Should -Be 0
        Should -Invoke Clear-CIPPImmutableID -Times 0 -Exactly
    }

    It 'preserves alert notification behavior' {
        $Item = New-SchedulerTestItem
        $Item.Command = 'Get-CIPPAlertTest'

        $Result = Push-ExecScheduledCommand -Item $Item

        $script:TaskWrites[-1].TaskState | Should -Be 'Completed'
        $Result | Should -Be 'Task Completed Successfully.'
        Should -Invoke Send-CIPPScheduledTaskAlert -Times 1 -Exactly -ParameterFilter {
            $TaskType -eq 'Alert' -and $Results -contains 'synthetic alert'
        }
        Should -Invoke Write-LogMessage -Times 0 -Exactly -ParameterFilter { $Message -like 'Successfully executed task:*' }
    }

    It 'preserves delegated orchestration and passes task context' {
        $Item = New-SchedulerTestItem
        $Item.Command = 'Invoke-CIPPOffboardingJob'

        $Result = Push-ExecScheduledCommand -Item $Item

        $script:TaskWrites[-1].TaskState | Should -Be 'Processing'
        $Result | Should -Be 'Task Completed Successfully.'
        Should -Invoke Invoke-CIPPOffboardingJob -Times 1 -Exactly -ParameterFilter { $TaskInfo.RowKey -eq 'task-test' }
        Should -Invoke Send-CIPPScheduledTaskAlert -Times 0 -Exactly
    }

    It 'records an orchestration dispatch failure instead of Processing' {
        Mock Invoke-CIPPOffboardingJob { throw 'synthetic dispatch failure' }
        $Item = New-SchedulerTestItem
        $Item.Command = 'Invoke-CIPPOffboardingJob'

        $Result = Push-ExecScheduledCommand -Item $Item

        $script:TaskWrites[-1].TaskState | Should -Be 'Failed'
        $script:TaskWrites[-1].Results | Should -BeLike '*synthetic dispatch failure*'
        $Result | Should -Be 'Task Failed.'
        Should -Invoke Send-CIPPScheduledTaskAlert -Times 0 -Exactly
        Should -Invoke Write-LogMessage -Times 0 -Exactly -ParameterFilter { $Message -like 'Successfully executed task:*' }
    }
}

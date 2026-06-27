#Requires -Version 7.0
. $PSScriptRoot\common.ps1

Complete-Fixture {
    $workspace = New-FixtureWorkspace -Name 'already-committed-idempotent'
    try {
        Initialize-HappyPathSource -Workspace $workspace | Out-Null
        Invoke-ScanAndProposal -Workspace $workspace
        Approve-FixtureRun -Workspace $workspace | Out-Null
        $firstApply = Invoke-SkillScript -ScriptName 'apply-approved-plan.ps1' -Workspace $workspace
        Assert-ExitCode -Result $firstApply -Expected 0 -Step 'first apply'
        $secondApply = Invoke-SkillScript -ScriptName 'apply-approved-plan.ps1' -Workspace $workspace
        Assert-ExitCode -Result $secondApply -Expected 0 -Step 'second apply'
        $states = @(Get-ApplyRows -Workspace $workspace | ForEach-Object { [string]$_.state })
        if ($states -notcontains 'skipped_existing_committed') { throw 'second apply did not record skipped_existing_committed' }
    } finally {
        Remove-FixtureWorkspace -Workspace $workspace
    }
}

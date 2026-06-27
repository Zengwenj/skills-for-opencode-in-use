#Requires -Version 7.0
. $PSScriptRoot\common.ps1

Complete-Fixture {
    $workspace = New-FixtureWorkspace -Name 'approval-default-pending'
    try {
        Initialize-HappyPathSource -Workspace $workspace | Out-Null
        Invoke-ScanAndProposal -Workspace $workspace
        $apply = Invoke-SkillScript -ScriptName 'apply-approved-plan.ps1' -Workspace $workspace
        if ($apply.ExitCode -eq 0) { throw 'pending approval unexpectedly allowed apply' }
        Assert-FileExists -Path (Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'approval.md') -Label 'pending approval template'
        if (@(Get-ChildItem -LiteralPath ([string]$workspace.Archive) -File -Recurse).Count -ne 0) { throw 'archive was written despite pending approval' }
    } finally {
        Remove-FixtureWorkspace -Workspace $workspace
    }
}

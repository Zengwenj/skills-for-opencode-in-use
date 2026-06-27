#Requires -Version 7.0
. $PSScriptRoot\common.ps1

Complete-Fixture {
    $workspace = New-FixtureWorkspace -Name 'source-changed'
    try {
        $source = Initialize-HappyPathSource -Workspace $workspace
        Invoke-ScanAndProposal -Workspace $workspace
        Approve-FixtureRun -Workspace $workspace | Out-Null
        Write-FixtureFile -Path $source -Content 'changed after proposal freeze'
        $apply = Invoke-SkillScript -ScriptName 'apply-approved-plan.ps1' -Workspace $workspace
        if ($apply.ExitCode -eq 0) { throw 'apply unexpectedly accepted changed source hash' }
        Assert-FileContains -Path (Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'failures.csv') -Pattern 'source_hash_changed' -Label 'failures.csv'
        if (@(Get-ChildItem -LiteralPath ([string]$workspace.Archive) -File -Recurse).Count -ne 0) { throw 'archive was written despite changed source' }
    } finally {
        Remove-FixtureWorkspace -Workspace $workspace
    }
}

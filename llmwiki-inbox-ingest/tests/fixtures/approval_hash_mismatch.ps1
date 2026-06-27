#Requires -Version 7.0
. $PSScriptRoot\common.ps1

Complete-Fixture {
    $workspace = New-FixtureWorkspace -Name 'approval-hash-mismatch'
    try {
        Initialize-HappyPathSource -Workspace $workspace | Out-Null
        Invoke-ScanAndProposal -Workspace $workspace
        $approvalPath = Approve-FixtureRun -Workspace $workspace
        (Get-Content -LiteralPath $approvalPath -Raw -Encoding UTF8).Replace('classification_plan_sha256:', 'classification_plan_sha256: "0000000000000000000000000000000000000000000000000000000000000000" #') | Set-Content -LiteralPath $approvalPath -Encoding utf8NoBOM
        $apply = Invoke-SkillScript -ScriptName 'apply-approved-plan.ps1' -Workspace $workspace
        if ($apply.ExitCode -eq 0) { throw 'tampered approval hash unexpectedly allowed apply' }
        if (@(Get-ChildItem -LiteralPath ([string]$workspace.Archive) -File -Recurse).Count -ne 0) { throw 'archive was written despite approval hash mismatch' }
    } finally {
        Remove-FixtureWorkspace -Workspace $workspace
    }
}

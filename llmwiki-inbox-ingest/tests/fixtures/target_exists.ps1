#Requires -Version 7.0
. $PSScriptRoot\common.ps1

Complete-Fixture {
    $workspace = New-FixtureWorkspace -Name 'target-exists'
    try {
        Initialize-HappyPathSource -Workspace $workspace | Out-Null
        Invoke-ScanAndProposal -Workspace $workspace
        $plan = Get-Content -LiteralPath (Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'classification-plan.jsonl') -Encoding UTF8 | Select-Object -First 1 | ConvertFrom-Json
        Write-FixtureFile -Path ([string]$plan.target_archive_path) -Content 'pre-existing archive bytes'
        Approve-FixtureRun -Workspace $workspace | Out-Null
        $apply = Invoke-SkillScript -ScriptName 'apply-approved-plan.ps1' -Workspace $workspace
        if ($apply.ExitCode -eq 0) { throw 'apply unexpectedly overwrote or accepted existing target' }
        Assert-FileContains -Path (Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'failures.csv') -Pattern 'target_exists' -Label 'failures.csv'
    } finally {
        Remove-FixtureWorkspace -Workspace $workspace
    }
}

#Requires -Version 7.0
. $PSScriptRoot\common.ps1

Complete-Fixture {
    $workspace = New-FixtureWorkspace -Name 'missing-config'
    try {
        Remove-Item -LiteralPath ([string]$workspace.ConfigPath) -Force
        Initialize-HappyPathSource -Workspace $workspace | Out-Null
        $scan = Invoke-SkillScript -ScriptName 'scan-inbox.ps1' -Workspace $workspace
        if ($scan.ExitCode -eq 0) { throw 'scan unexpectedly succeeded without config' }
        foreach ($artifact in @('inventory.jsonl', 'classification-plan.jsonl', 'proposal-manifest.json')) {
            $artifactPath = Join-Path -Path ([string]$workspace.RunDir) -ChildPath $artifact
            if (Test-Path -LiteralPath $artifactPath) { throw "unexpected artifact created without config: $artifact" }
        }
    } finally {
        Remove-FixtureWorkspace -Workspace $workspace
    }
}

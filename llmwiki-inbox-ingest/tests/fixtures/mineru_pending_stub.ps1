#Requires -Version 7.0
. $PSScriptRoot\common.ps1

Complete-Fixture {
    $workspace = New-FixtureWorkspace -Name 'mineru-pending-stub'
    try {
        Initialize-PreparedMineruRun -Workspace $workspace
        $item = Get-SingleMineruBatchItem -Workspace $workspace
        $sourceId = [string]$item.source_id

        Write-FixtureMineruOutput -Workspace $workspace -SourceId $sourceId -Markdown "# $sourceId`n`nMinerU processing pending - file not yet parsed."
        Write-FixtureLifecycleState -Workspace $workspace -SourceId $sourceId -Status 'pending_timeout' -NextAction 'resubmit pending stub with lifecycle runner'

        $ingest = Invoke-SkillScript -ScriptName 'ingest-mineru-output.ps1' -Workspace $workspace
        Assert-ExitCode -Result $ingest -Expected 0 -Step 'ingest pending_stub'

        $parsePath = Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'parse-manifest.csv'
        $rawPath = Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'raw-output-manifest.csv'
        Assert-FileContains -Path $parsePath -Pattern 'pending_stub' -Label 'parse-manifest.csv'
        Assert-FileContains -Path $rawPath -Pattern 'pending_stub' -Label 'raw-output-manifest.csv'
        if ((Get-Content -LiteralPath $parsePath -Raw -Encoding UTF8).Contains('parsed')) {
            throw 'pending_stub was marked as parsed success'
        }
        if (@(Get-ChildItem -LiteralPath ([string]$workspace.Raw) -File -Recurse).Count -ne 0) {
            throw 'pending_stub should not be written to raw'
        }

        $validate = Invoke-SkillScript -ScriptName 'validate-run.ps1' -Workspace $workspace
        Assert-ExitCode -Result $validate -Expected 0 -Step 'validate pending_stub run'
    } finally {
        Remove-FixtureWorkspace -Workspace $workspace
    }
}

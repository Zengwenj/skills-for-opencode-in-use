#Requires -Version 7.0
. $PSScriptRoot\common.ps1

Complete-Fixture {
    $workspace = New-FixtureWorkspace -Name 'mineru-lifecycle-pending-resume'
    try {
        Initialize-PreparedMineruRun -Workspace $workspace
        $item = Get-SingleMineruBatchItem -Workspace $workspace
        $sourceId = [string]$item.source_id

        Write-FixtureLifecycleState -Workspace $workspace -SourceId $sourceId -Status 'pending_timeout' -NextAction 'rerun lifecycle runner with a longer polling budget'
        $firstIngest = Invoke-SkillScript -ScriptName 'ingest-mineru-output.ps1' -Workspace $workspace
        Assert-ExitCode -Result $firstIngest -Expected 0 -Step 'first ingest pending_timeout'

        $failuresPath = Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'failures.csv'
        Assert-FileContains -Path $failuresPath -Pattern 'pending' -Label 'pending failures.csv'
        $failureText = Get-Content -LiteralPath $failuresPath -Raw -Encoding UTF8
        if ($failureText.Contains('mineru_output_missing')) { throw 'pending_timeout was reported as mineru_output_missing' }
        Assert-FileContains -Path (Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'parse-manifest.csv') -Pattern 'pending' -Label 'pending parse-manifest.csv'

        $firstValidate = Invoke-SkillScript -ScriptName 'validate-run.ps1' -Workspace $workspace
        Assert-ExitCode -Result $firstValidate -Expected 0 -Step 'validate pending resumable run'

        $body = ('This resumed MinerU output is long enough to pass the quality gate. ' * 20)
        Write-FixtureMineruOutput -Workspace $workspace -SourceId $sourceId -Markdown ("# Resumed MinerU output`n`n$body")
        Write-FixtureLifecycleState -Workspace $workspace -SourceId $sourceId -Status 'done'

        $secondIngest = Invoke-SkillScript -ScriptName 'ingest-mineru-output.ps1' -Workspace $workspace
        Assert-ExitCode -Result $secondIngest -Expected 0 -Step 'second ingest after resume'

        $rawFiles = @(Get-ChildItem -LiteralPath ([string]$workspace.Raw) -File -Recurse)
        if ($rawFiles.Count -ne 1) { throw "expected one raw file after resume, found $($rawFiles.Count)" }
        $secondFailures = Get-Content -LiteralPath $failuresPath -Raw -Encoding UTF8
        if ($secondFailures.Contains('pending')) { throw 'stale pending failure row remained after successful resume' }

        $secondValidate = Invoke-SkillScript -ScriptName 'validate-run.ps1' -Workspace $workspace
        Assert-ExitCode -Result $secondValidate -Expected 0 -Step 'validate resumed run'
    } finally {
        Remove-FixtureWorkspace -Workspace $workspace
    }
}

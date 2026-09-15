#Requires -Version 7.0
. $PSScriptRoot/common.ps1

# 补救闭环：近空输出先判 quality_failed → 补内容后重跑写入 → validate 必须能收口。
# 回归护栏：manifest 合并追加保留旧失败行，判定须按 source_id 的最后一行（否则补救流程永远卡死）。
Complete-Fixture {
    $workspace = New-FixtureWorkspace -Name 'mineru-quality-failed-then-remediated'
    try {
        Initialize-PreparedMineruRun -Workspace $workspace
        $item = Get-SingleMineruBatchItem -Workspace $workspace
        $sourceId = [string]$item.source_id

        Write-FixtureMineruOutput -Workspace $workspace -SourceId $sourceId -Markdown "# 附件11`n`n附件11`n"
        Write-FixtureLifecycleState -Workspace $workspace -SourceId $sourceId -Status 'mapped'

        $firstIngest = Invoke-SkillScript -ScriptName 'ingest-mineru-output.ps1' -Workspace $workspace
        Assert-ExitCode -Result $firstIngest -Expected 1 -Step 'first ingest (near-empty -> quality_failed)'

        $rawManifestPath = Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'raw-output-manifest.csv'
        Assert-FileContains -Path $rawManifestPath -Pattern 'quality_failed' -Label 'raw-output-manifest.csv (first run)'

        $firstValidate = Invoke-SkillScript -ScriptName 'validate-run.ps1' -Workspace $workspace
        Assert-ExitCode -Result $firstValidate -Expected 1 -Step 'validate refuses before remediation'

        # 补救：重写为有标题、内容充分的输出后重跑
        $body = ('Remediated MinerU fixture content with a heading, long enough to pass the near-empty floor. ' * 12)
        Write-FixtureMineruOutput -Workspace $workspace -SourceId $sourceId -Markdown "# Remediated $sourceId`n`n$body"

        $secondIngest = Invoke-SkillScript -ScriptName 'ingest-mineru-output.ps1' -Workspace $workspace
        Assert-ExitCode -Result $secondIngest -Expected 0 -Step 'second ingest after remediation'

        $rows = @(Import-Csv -LiteralPath $rawManifestPath)
        if ($rows.Count -lt 2) {
            throw "expected merged manifest to keep the superseded failure row and append the written row; found $($rows.Count)"
        }
        if ([string]$rows[0].status -ne 'quality_failed') {
            throw "superseded failure row was not preserved (first row status: $($rows[0].status))"
        }
        if ([string]$rows[$rows.Count - 1].status -ne 'written') {
            throw "remediated row was not appended as written (last row status: $($rows[$rows.Count - 1].status))"
        }

        $secondValidate = Invoke-SkillScript -ScriptName 'validate-run.ps1' -Workspace $workspace
        Assert-ExitCode -Result $secondValidate -Expected 0 -Step 'validate after remediation (latest row wins)'
    } finally {
        Remove-FixtureWorkspace -Workspace $workspace
    }
}

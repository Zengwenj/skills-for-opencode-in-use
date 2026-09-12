#Requires -Version 7.0
. $PSScriptRoot/common.ps1

# 契约 §4 用例 4：重跑后旧 parse/raw manifest 行保留 + 新行追加（不丢历史）。
Complete-Fixture {
    $workspace = New-FixtureWorkspace -Name 'raw-manifest-merge-append'
    try {
        Initialize-PreparedMineruRun -Workspace $workspace
        $item = Get-SingleMineruBatchItem -Workspace $workspace
        $sourceId = [string]$item.source_id

        $body = ('Synthetic MinerU fixture body for manifest merge verification. ' * 20)
        Write-FixtureMineruOutput -Workspace $workspace -SourceId $sourceId -Markdown "# Merge output $sourceId`n`n$body"
        Write-FixtureLifecycleState -Workspace $workspace -SourceId $sourceId -Status 'done'

        $firstIngest = Invoke-SkillScript -ScriptName 'ingest-mineru-output.ps1' -Workspace $workspace
        Assert-ExitCode -Result $firstIngest -Expected 0 -Step 'first ingest'

        $parseManifestPath = Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'parse-manifest.csv'
        $rawManifestPath = Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'raw-output-manifest.csv'
        $firstParseRows = @(Import-Csv -LiteralPath $parseManifestPath)
        $firstRawRows = @(Import-Csv -LiteralPath $rawManifestPath)
        if ($firstParseRows.Count -ne 1) { throw "expected 1 parse row after first run, found $($firstParseRows.Count)" }
        if ($firstRawRows.Count -ne 1) { throw "expected 1 raw row after first run, found $($firstRawRows.Count)" }

        # 不改变任何输入的直接重跑
        $secondIngest = Invoke-SkillScript -ScriptName 'ingest-mineru-output.ps1' -Workspace $workspace
        Assert-ExitCode -Result $secondIngest -Expected 0 -Step 'second ingest (idempotent skip)'

        $secondParseRows = @(Import-Csv -LiteralPath $parseManifestPath)
        $secondRawRows = @(Import-Csv -LiteralPath $rawManifestPath)
        if ($secondParseRows.Count -ne 2) { throw "expected 2 parse rows after rerun (merge+append), found $($secondParseRows.Count)" }
        if ($secondRawRows.Count -ne 2) { throw "expected 2 raw rows after rerun (merge+append), found $($secondRawRows.Count)" }

        # 旧行必须原样保留在前，新行追加在后
        if ([string]$secondRawRows[0].status -ne 'written') { throw "old raw manifest row was not preserved (first row status: $($secondRawRows[0].status))" }
        if ([string]$secondRawRows[1].status -ne 'skipped') { throw "new raw manifest row was not appended (second row status: $($secondRawRows[1].status))" }
        if ([string]$secondParseRows[0].status -ne 'parsed') { throw "old parse manifest row was not preserved" }

        # 幂等跳过不应在 journal 追加任何新事件
        $journalPath = Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'raw-journal.jsonl'
        $journalEvents = @(Get-Content -LiteralPath $journalPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
        if ($journalEvents.Count -ne 2) { throw "expected journal to stay at 2 events after idempotent rerun, found $($journalEvents.Count)" }

        $validate = Invoke-SkillScript -ScriptName 'validate-run.ps1' -Workspace $workspace
        Assert-ExitCode -Result $validate -Expected 0 -Step 'validate merged manifest run'
    } finally {
        Remove-FixtureWorkspace -Workspace $workspace
    }
}

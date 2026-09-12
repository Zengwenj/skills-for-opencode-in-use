#Requires -Version 7.0
. $PSScriptRoot/common.ps1

# 契约 §4 用例 3：同 source_id 但 MinerU 输出内容变化（内容哈希不同）。
# 断言：停止并记失败（raw_content_divergent），不覆盖、不改名写入、不产生 __N 副本。
Complete-Fixture {
    $workspace = New-FixtureWorkspace -Name 'raw-source-divergent-stops'
    try {
        Initialize-PreparedMineruRun -Workspace $workspace
        $item = Get-SingleMineruBatchItem -Workspace $workspace
        $sourceId = [string]$item.source_id

        $bodyV1 = ('Synthetic MinerU fixture body version one for divergence detection. ' * 20)
        Write-FixtureMineruOutput -Workspace $workspace -SourceId $sourceId -Markdown "# Divergence output v1 $sourceId`n`n$bodyV1"
        Write-FixtureLifecycleState -Workspace $workspace -SourceId $sourceId -Status 'done'

        $firstIngest = Invoke-SkillScript -ScriptName 'ingest-mineru-output.ps1' -Workspace $workspace
        Assert-ExitCode -Result $firstIngest -Expected 0 -Step 'first ingest writes raw'

        $rawMdFiles = @(Get-ChildItem -LiteralPath ([string]$workspace.Raw) -File -Recurse -Filter '*.md')
        if ($rawMdFiles.Count -ne 1) { throw "expected 1 raw markdown file, found $($rawMdFiles.Count)" }
        $hashBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $rawMdFiles[0].FullName).Hash.ToLowerInvariant()

        # 同 source_id 的 MinerU 输出被重新生成为不同内容（仍通过质量门）
        $bodyV2 = ('REGENERATED synthetic MinerU fixture body with different bytes entirely. ' * 20)
        Write-FixtureMineruOutput -Workspace $workspace -SourceId $sourceId -Markdown "# Divergence output v2 $sourceId`n`n$bodyV2"

        $secondIngest = Invoke-SkillScript -ScriptName 'ingest-mineru-output.ps1' -Workspace $workspace
        Assert-ExitCode -Result $secondIngest -Expected 1 -Step 'second ingest must stop with failures'

        $failuresPath = Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'failures.csv'
        Assert-FileContains -Path $failuresPath -Pattern 'raw_content_divergent' -Label 'failures.csv'

        $rawMdAfter = @(Get-ChildItem -LiteralPath ([string]$workspace.Raw) -File -Recurse -Filter '*.md')
        if ($rawMdAfter.Count -ne 1) { throw "divergent rerun created extra raw files: $($rawMdAfter.Count)" }
        if (@($rawMdAfter | Where-Object { $_.Name -match '__\d+\.md$' }).Count -gt 0) { throw 'divergent rerus produced __N suffixed file' }
        $hashAfter = (Get-FileHash -Algorithm SHA256 -LiteralPath $rawMdAfter[0].FullName).Hash.ToLowerInvariant()
        if (-not $hashAfter.Equals($hashBefore, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'divergent rerun overwrote the existing raw file'
        }

        $journalPath = Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'raw-journal.jsonl'
        $journalEvents = @(Get-Content -LiteralPath $journalPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
        $plannedForSid = @($journalEvents | Where-Object { [string]$_.source_id -eq $sourceId -and [string]$_.state -eq 'planned' })
        if ($plannedForSid.Count -ne 1) { throw "divergent rerus appended extra planned events: $($plannedForSid.Count)" }

        $rawManifestPath = Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'raw-output-manifest.csv'
        $mergedRows = @(Import-Csv -LiteralPath $rawManifestPath)
        $divergentRows = @($mergedRows | Where-Object { [string]$_.source_id -eq $sourceId -and [string]$_.status -eq 'failed' })
        if ($divergentRows.Count -ne 1) { throw "expected 1 failed raw row for divergent source, found $($divergentRows.Count)" }
    } finally {
        Remove-FixtureWorkspace -Workspace $workspace
    }
}

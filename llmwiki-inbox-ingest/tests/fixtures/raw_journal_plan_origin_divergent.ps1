#Requires -Version 7.0
. $PSScriptRoot/common.ps1

# oracle O8 用例：planned 恢复分支的来源世系核验。
# 场景：崩溃于"已落盘未记 written"（journal 只有 planned、盘上 raw 存在且哈希与 journal 一致），
#       但此后 run 被指向不同档案世系（archive 文件换内容 + apply/batch 的 sha 同步更新）。
# 断言：不补记 written、不覆盖、不产生副本，失败码 raw_plan_origin_divergent。
Complete-Fixture {
    $workspace = New-FixtureWorkspace -Name 'raw-journal-plan-origin-divergent'
    try {
        Initialize-PreparedMineruRun -Workspace $workspace
        $item = Get-SingleMineruBatchItem -Workspace $workspace
        $sourceId = [string]$item.source_id

        $body = ('Synthetic MinerU fixture body for plan origin divergence verification. ' * 20)
        Write-FixtureMineruOutput -Workspace $workspace -SourceId $sourceId -Markdown "# Origin divergence output $sourceId`n`n$body"
        Write-FixtureLifecycleState -Workspace $workspace -SourceId $sourceId -Status 'done'

        $firstIngest = Invoke-SkillScript -ScriptName 'ingest-mineru-output.ps1' -Workspace $workspace
        Assert-ExitCode -Result $firstIngest -Expected 0 -Step 'first ingest writes raw'

        $rawMdFiles = @(Get-ChildItem -LiteralPath ([string]$workspace.Raw) -File -Recurse -Filter '*.md')
        if ($rawMdFiles.Count -ne 1) { throw "expected 1 raw markdown file, found $($rawMdFiles.Count)" }
        $hashBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $rawMdFiles[0].FullName).Hash.ToLowerInvariant()

        # 回滚 journal 至 planned（模拟崩溃于"已落盘未记 written"）
        $journalPath = Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'raw-journal.jsonl'
        $journalLines = @(Get-Content -LiteralPath $journalPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $plannedLines = @($journalLines | Where-Object { ([string]$_ | ConvertFrom-Json).state -eq 'planned' })
        if ($plannedLines.Count -ne 1) { throw "expected exactly 1 planned journal line, found $($plannedLines.Count)" }
        Write-FixtureFile -Path $journalPath -Content (($plannedLines -join "`n") + "`n")

        # 变更档案世系：换 archive 文件字节 + 同步 apply-manifest 与 mineru-batch 的 archive_sha256
        $archivePath = [string]$item.archive_path
        Add-Content -LiteralPath $archivePath -Value 'lineage-change-probe' -Encoding UTF8
        $newSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $archivePath).Hash.ToLowerInvariant()

        $applyPath = Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'apply-manifest.jsonl'
        $applyRows = @(Get-Content -LiteralPath $applyPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
        foreach ($row in $applyRows) { if ([string]$row.source_id -eq $sourceId) { $row.archive_sha256 = $newSha } }
        Write-FixtureFile -Path $applyPath -Content ((@($applyRows | ForEach-Object { $_ | ConvertTo-Json -Compress })) -join "`n") 

        $batchPath = Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'mineru-batch.json'
        $batchObj = Get-Content -LiteralPath $batchPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($batchItem in @($batchObj.items)) { if ([string]$batchItem.source_id -eq $sourceId) { $batchItem.archive_sha256 = $newSha } }
        $batchJson = $batchObj | ConvertTo-Json -Depth 10
        Write-FixtureFile -Path $batchPath -Content $batchJson

        $secondIngest = Invoke-SkillScript -ScriptName 'ingest-mineru-output.ps1' -Workspace $workspace
        Assert-ExitCode -Result $secondIngest -Expected 1 -Step 'second ingest must stop with origin divergence'

        $failuresPath = Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'failures.csv'
        Assert-FileContains -Path $failuresPath -Pattern 'raw_plan_origin_divergent' -Label 'failures.csv'

        $rawMdAfter = @(Get-ChildItem -LiteralPath ([string]$workspace.Raw) -File -Recurse -Filter '*.md')
        if ($rawMdAfter.Count -ne 1) { throw "divergent rerun created extra raw files: $($rawMdAfter.Count)" }
        $hashAfter = (Get-FileHash -Algorithm SHA256 -LiteralPath $rawMdAfter[0].FullName).Hash.ToLowerInvariant()
        if (-not $hashAfter.Equals($hashBefore, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'divergent rerun overwrote the existing raw file'
        }

        # 不得补记 written：journal 对该 source 仍只有 planned
        $events = @(Get-Content -LiteralPath $journalPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
        $writtenForSid = @($events | Where-Object { [string]$_.source_id -eq $sourceId -and [string]$_.state -eq 'written' })
        if ($writtenForSid.Count -ne 0) { throw "origin-divergent recovery appended written event: $($writtenForSid.Count)" }
    } finally {
        Remove-FixtureWorkspace -Workspace $workspace
    }
}

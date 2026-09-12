#Requires -Version 7.0
. $PSScriptRoot/common.ps1

# 契约 §4 用例 2：崩溃于“已落盘未记 written”（journal 只有 planned、目标文件已存在）。
# 断言：恢复时按 target 实际哈希反向核验后补记 written，不重写文件、不产生副本。
Complete-Fixture {
    $workspace = New-FixtureWorkspace -Name 'raw-journal-crash-recovery'
    try {
        Initialize-PreparedMineruRun -Workspace $workspace
        $item = Get-SingleMineruBatchItem -Workspace $workspace
        $sourceId = [string]$item.source_id

        $body = ('Synthetic MinerU fixture body for crash recovery verification. ' * 20)
        Write-FixtureMineruOutput -Workspace $workspace -SourceId $sourceId -Markdown "# Crash recovery output $sourceId`n`n$body"
        Write-FixtureLifecycleState -Workspace $workspace -SourceId $sourceId -Status 'done'

        $firstIngest = Invoke-SkillScript -ScriptName 'ingest-mineru-output.ps1' -Workspace $workspace
        Assert-ExitCode -Result $firstIngest -Expected 0 -Step 'first ingest writes raw'

        $rawMdFiles = @(Get-ChildItem -LiteralPath ([string]$workspace.Raw) -File -Recurse -Filter '*.md')
        if ($rawMdFiles.Count -ne 1) { throw "expected 1 raw markdown file, found $($rawMdFiles.Count)" }
        $rawFile = $rawMdFiles[0]
        $hashBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $rawFile.FullName).Hash.ToLowerInvariant()
        $mtimeBefore = $rawFile.LastWriteTimeUtc

        # 模拟崩溃点：文件已原子落盘，但 journal 的 written 事件尚未记录（回滚掉 written 行）
        $journalPath = Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'raw-journal.jsonl'
        Assert-FileExists -Path $journalPath -Label 'raw-journal.jsonl'
        $journalLines = @(Get-Content -LiteralPath $journalPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $plannedLines = @($journalLines | Where-Object { ([string]$_ | ConvertFrom-Json).state -eq 'planned' })
        if ($plannedLines.Count -ne 1) { throw "expected exactly 1 planned journal line before rewind, found $($plannedLines.Count)" }
        Write-FixtureFile -Path $journalPath -Content (($plannedLines -join "`n") + "`n")

        $secondIngest = Invoke-SkillScript -ScriptName 'ingest-mineru-output.ps1' -Workspace $workspace
        Assert-ExitCode -Result $secondIngest -Expected 0 -Step 'second ingest recovers written'

        $rawMdAfter = @(Get-ChildItem -LiteralPath ([string]$workspace.Raw) -File -Recurse -Filter '*.md')
        if ($rawMdAfter.Count -ne 1) { throw "recovery produced duplicate raw files: $($rawMdAfter.Count)" }
        $hashAfter = (Get-FileHash -Algorithm SHA256 -LiteralPath $rawMdAfter[0].FullName).Hash.ToLowerInvariant()
        if (-not $hashAfter.Equals($hashBefore, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'recovery rewrote the raw file (content hash changed)'
        }
        if (-not $rawMdAfter[0].LastWriteTimeUtc.Equals($mtimeBefore)) {
            throw 'recovery rewrote the raw file (LastWriteTime changed)'
        }

        $recoveredEvents = @(Get-Content -LiteralPath $journalPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
        if ($recoveredEvents.Count -ne 2) { throw "expected exactly 2 journal events after recovery, found $($recoveredEvents.Count)" }
        if ([string]$recoveredEvents[0].state -ne 'planned' -or [string]$recoveredEvents[1].state -ne 'written') {
            throw "journal events after recovery are not planned->written: $($recoveredEvents.state -join ',')"
        }

        $rawManifestPath = Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'raw-output-manifest.csv'
        $mergedRows = @(Import-Csv -LiteralPath $rawManifestPath)
        $recoveredRows = @($mergedRows | Where-Object { ([string]$_.message).Contains('recovered') })
        if ($recoveredRows.Count -ne 1) { throw "expected 1 recovered written row in raw manifest, found $($recoveredRows.Count)" }
        if ([string]$recoveredRows[0].raw_sha256 -ne $hashBefore) { throw 'recovered row hash does not match the on-disk file' }

        $validate = Invoke-SkillScript -ScriptName 'validate-run.ps1' -Workspace $workspace
        Assert-ExitCode -Result $validate -Expected 0 -Step 'validate crash-recovery run'
    } finally {
        Remove-FixtureWorkspace -Workspace $workspace
    }
}

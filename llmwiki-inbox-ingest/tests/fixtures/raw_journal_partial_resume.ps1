#Requires -Version 7.0
. $PSScriptRoot/common.ps1

# 契约 §4 用例 1：20 输入中 7 已 written → 续跑剩余 13。
# 断言：已 written 的 7 个幂等跳过（journal 双验），不产生任何 __N 文件，13 个正常写入。
Complete-Fixture {
    $workspace = New-FixtureWorkspace -Name 'raw-journal-partial-resume'
    try {
        for ($i = 1; $i -le 20; $i++) {
            $name = 'doc-{0:D2}.pdf' -f $i
            $source = Join-Path -Path ([string]$workspace.Inbox) -ChildPath (Join-Path -Path 'ThemeA' -ChildPath (Join-Path -Path '2026' -ChildPath $name))
            Write-FixtureFile -Path $source -Content ("synthetic fixture pdf bytes for $name " * 20)
        }
        Invoke-ScanAndProposal -Workspace $workspace
        Approve-FixtureRun -Workspace $workspace | Out-Null
        $apply = Invoke-SkillScript -ScriptName 'apply-approved-plan.ps1' -Workspace $workspace
        Assert-ExitCode -Result $apply -Expected 0 -Step 'apply 20 sources'
        $batchPrep = Invoke-SkillScript -ScriptName 'prepare-mineru-batch.ps1' -Workspace $workspace
        Assert-ExitCode -Result $batchPrep -Expected 0 -Step 'prepare mineru batch'

        $batch = Get-MineruBatch -Workspace $workspace
        $items = @($batch.items)
        if ($items.Count -ne 20) { throw "expected 20 batch items, found $($items.Count)" }
        $firstSeven = @($items | Select-Object -First 7)
        $rest = @($items | Select-Object -Skip 7)

        $statePath = Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'lifecycle-state.jsonl'
        $stateLines = foreach ($entry in $items) {
            $status = if (@($firstSeven.source_id) -contains [string]$entry.source_id) { 'done' } else { 'pending_timeout' }
            ([ordered]@{
                source_id   = [string]$entry.source_id
                batch_id    = 'fixture-batch'
                task_id     = 'fixture-task'
                status      = $status
                next_action = 'rerun lifecycle runner with a longer polling budget'
            } | ConvertTo-Json -Compress)
        }
        Write-FixtureFile -Path $statePath -Content (($stateLines -join "`n") + "`n")

        foreach ($entry in $firstSeven) {
            $sid = [string]$entry.source_id
            $body = ('Synthetic MinerU fixture body for partial resume verification. ' * 20)
            Write-FixtureMineruOutput -Workspace $workspace -SourceId $sid -Markdown "# Resumed output $sid`n`n$body"
        }

        $firstIngest = Invoke-SkillScript -ScriptName 'ingest-mineru-output.ps1' -Workspace $workspace
        Assert-ExitCode -Result $firstIngest -Expected 0 -Step 'first ingest (7 written, 13 pending)'

        $rawManifestPath = Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'raw-output-manifest.csv'
        $runOneRows = @(Import-Csv -LiteralPath $rawManifestPath)
        $runOneWritten = @($runOneRows | Where-Object { [string]$_.status -eq 'written' })
        if ($runOneWritten.Count -ne 7) { throw "expected 7 written rows after first ingest, found $($runOneWritten.Count)" }
        $hashByPath = @{}
        foreach ($row in $runOneWritten) { $hashByPath[[string]$row.raw_path] = [string]$row.raw_sha256 }

        # 剩余 13 个补齐输出并转为 done
        $stateLines = foreach ($entry in $items) {
            ([ordered]@{
                source_id = [string]$entry.source_id
                batch_id  = 'fixture-batch'
                task_id   = 'fixture-task'
                status    = 'done'
            } | ConvertTo-Json -Compress)
        }
        Write-FixtureFile -Path $statePath -Content (($stateLines -join "`n") + "`n")
        foreach ($entry in $rest) {
            $sid = [string]$entry.source_id
            $body = ('Synthetic MinerU fixture body for resumed remainder item. ' * 20)
            Write-FixtureMineruOutput -Workspace $workspace -SourceId $sid -Markdown "# Resumed output $sid`n`n$body"
        }

        $secondIngest = Invoke-SkillScript -ScriptName 'ingest-mineru-output.ps1' -Workspace $workspace
        Assert-ExitCode -Result $secondIngest -Expected 0 -Step 'second ingest (7 skip + 13 written)'

        $rawMdFiles = @(Get-ChildItem -LiteralPath ([string]$workspace.Raw) -File -Recurse -Filter '*.md')
        if ($rawMdFiles.Count -ne 20) { throw "expected 20 raw markdown files, found $($rawMdFiles.Count)" }
        $suffixCollisions = @($rawMdFiles | Where-Object { $_.Name -match '__\d+\.md$' })
        if ($suffixCollisions.Count -gt 0) { throw "idempotent rerun produced __N suffixed files: $($suffixCollisions.Name -join ', ')" }
        $tempLeftovers = @(Get-ChildItem -LiteralPath ([string]$workspace.Raw) -File -Recurse -Filter '*.tmp-*')
        if ($tempLeftovers.Count -gt 0) { throw "temp leftovers remained under raw root: $($tempLeftovers.Name -join ', ')" }

        foreach ($row in $runOneWritten) {
            $currentHash = (Get-FileHash -Algorithm SHA256 -LiteralPath ([string]$row.raw_path)).Hash.ToLowerInvariant()
            if (-not $currentHash.Equals([string]$row.raw_sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "previously written raw file was rewritten during rerun: $($row.raw_path)"
            }
        }

        $journalPath = Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'raw-journal.jsonl'
        Assert-FileExists -Path $journalPath -Label 'raw-journal.jsonl'
        $journalEvents = @(Get-Content -LiteralPath $journalPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
        $plannedEvents = @($journalEvents | Where-Object { [string]$_.state -eq 'planned' })
        $writtenEvents = @($journalEvents | Where-Object { [string]$_.state -eq 'written' })
        if ($plannedEvents.Count -ne 20) { throw "expected 20 planned journal events, found $($plannedEvents.Count)" }
        if ($writtenEvents.Count -ne 20) { throw "expected 20 written journal events, found $($writtenEvents.Count)" }
        foreach ($sid in @($items | ForEach-Object { [string]$_.source_id })) {
            $plannedForSid = @($plannedEvents | Where-Object { [string]$_.source_id -eq $sid })
            $writtenForSid = @($writtenEvents | Where-Object { [string]$_.source_id -eq $sid })
            if ($plannedForSid.Count -ne 1 -or $writtenForSid.Count -ne 1) {
                throw "source $sid has $($plannedForSid.Count) planned and $($writtenForSid.Count) written journal events (expected 1 each)"
            }
        }

        $mergedRows = @(Import-Csv -LiteralPath $rawManifestPath)
        $skippedRows = @($mergedRows | Where-Object { [string]$_.status -eq 'skipped' })
        $writtenRows = @($mergedRows | Where-Object { [string]$_.status -eq 'written' })
        if ($skippedRows.Count -ne 7) { throw "expected 7 skipped rows in merged raw manifest, found $($skippedRows.Count)" }
        if ($writtenRows.Count -ne 20) { throw "expected 20 written rows in merged raw manifest, found $($writtenRows.Count)" }

        $evidenceDir = Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'evidence'
        New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null
        Write-FixtureFile -Path (Join-Path -Path $evidenceDir -ChildPath 'fixture.md') -Content '# Fixture evidence'

        $validate = Invoke-SkillScript -ScriptName 'validate-run.ps1' -Workspace $workspace
        Assert-ExitCode -Result $validate -Expected 0 -Step 'validate merged partial-resume run'
    } finally {
        Remove-FixtureWorkspace -Workspace $workspace
    }
}

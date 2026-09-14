#Requires -Version 7.0
. $PSScriptRoot/common.ps1

# 文本源本地摄入（text_source 路由）：不经 MinerU，直接从已归档文本生成 raw markdown。
# 覆盖：首次写入 → 幂等重跑 skip → frontmatter 世系 → manifest 记录 → 全局 validate。
Complete-Fixture {
    $workspace = New-FixtureWorkspace -Name 'text-source-local-ingest'
    try {
        $source = Join-Path -Path ([string]$workspace.Inbox) -ChildPath (Join-Path -Path 'ThemeA' -ChildPath (Join-Path -Path '2026' -ChildPath 'checklist-notes.txt'))
        Write-FixtureFile -Path $source -Content @'
设备巡检要点：
1. 机柜电源必须使用 PDU 专用插座。
2. 标签需每半年检查一次。
'@

        Invoke-ScanAndProposal -Workspace $workspace

        $runDir = [string]$workspace.RunDir
        $planPath = Join-Path -Path $runDir -ChildPath 'classification-plan.jsonl'
        $planRows = @(Get-Content -LiteralPath $planPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
        if ($planRows.Count -ne 1) { throw "expected 1 plan row, found $($planRows.Count)" }
        if ([string]$planRows[0].action -ne 'archive_and_raw') { throw "expected archive_and_raw, got $($planRows[0].action)" }
        if (-not (@($planRows[0].reason_codes) -contains 'text_source')) { throw 'plan row missing text_source reason code' }
        if ([bool]$planRows[0].mineru_candidate) { throw 'text source must not be a MinerU candidate' }
        $sourceId = [string]$planRows[0].source_id

        Approve-FixtureRun -Workspace $workspace | Out-Null

        $apply = Invoke-SkillScript -ScriptName 'apply-approved-plan.ps1' -Workspace $workspace
        Assert-ExitCode -Result $apply -Expected 0 -Step 'apply-approved-plan (text source)'

        $batch = Invoke-SkillScript -ScriptName 'prepare-mineru-batch.ps1' -Workspace $workspace
        Assert-ExitCode -Result $batch -Expected 0 -Step 'prepare-mineru-batch (zero mineru candidates)'
        $batchPath = Join-Path -Path $runDir -ChildPath 'mineru-batch.json'
        $batchDoc = Get-Content -LiteralPath $batchPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (@($batchDoc.items).Count -ne 0) { throw "text source must not enter the MinerU batch, found $(@($batchDoc.items).Count) item(s)" }

        $ingest = Invoke-SkillScript -ScriptName 'ingest-mineru-output.ps1' -Workspace $workspace
        Assert-ExitCode -Result $ingest -Expected 0 -Step 'ingest-mineru-output writes raw from local text'

        $rawFiles = @(Get-ChildItem -LiteralPath ([string]$workspace.Raw) -File -Recurse -Filter '*.md')
        if ($rawFiles.Count -ne 1) { throw "expected 1 raw markdown, found $($rawFiles.Count)" }
        $rawText = Get-Content -LiteralPath $rawFiles[0].FullName -Raw -Encoding UTF8
        if ($rawText -notmatch 'source_type: "txt"') { throw 'raw frontmatter source_type must be txt' }
        if ($rawText -notmatch 'status: "raw-parsed"') { throw 'raw frontmatter status must be raw-parsed' }
        if ($rawText -notmatch '(?m)^# checklist-notes') { throw 'expected synthesized H1 title for plain text source' }
        if ($rawText -notmatch '机柜电源必须使用 PDU 专用插座') { throw 'raw body must contain the source text' }
        $rawHashBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $rawFiles[0].FullName).Hash.ToLowerInvariant()
        $archiveHash = ([string](Get-ApplyRows -Workspace $workspace | Where-Object { [string]$_.source_id -eq $sourceId -and [string]$_.state -eq 'committed' } | Select-Object -First 1).archive_sha256).ToLowerInvariant()
        if ($rawText -notmatch [regex]::Escape($archiveHash)) { throw 'raw frontmatter source_sha256 must equal committed archive hash' }

        $rawManifestPath = Join-Path -Path $runDir -ChildPath 'raw-output-manifest.csv'
        $rows = @(Import-Csv -LiteralPath $rawManifestPath | Where-Object { [string]$_.source_id -eq $sourceId })
        if ($rows.Count -ne 1 -or [string]$rows[0].status -ne 'written') { throw "expected written raw manifest row, got $($rows.Count) row(s)" }
        if (-not ([string]$rows[0].message).Contains('local text')) { throw 'raw manifest message must record local text provenance' }

        $parseManifestPath = Join-Path -Path $runDir -ChildPath 'parse-manifest.csv'
        Assert-FileContains -Path $parseManifestPath -Pattern 'text_source' -Label 'parse-manifest.csv'

        # 幂等：重跑必须 skip，不重写、不产生副本
        $rerun = Invoke-SkillScript -ScriptName 'ingest-mineru-output.ps1' -Workspace $workspace
        Assert-ExitCode -Result $rerun -Expected 0 -Step 'ingest rerun (idempotent)'
        $rawAfter = @(Get-ChildItem -LiteralPath ([string]$workspace.Raw) -File -Recurse -Filter '*.md')
        if ($rawAfter.Count -ne 1) { throw "idempotent rerun created extra raw files: $($rawAfter.Count)" }
        if (-not (Get-FileHash -Algorithm SHA256 -LiteralPath $rawAfter[0].FullName).Hash.ToLowerInvariant().Equals($rawHashBefore, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'idempotent rerun rewrote the raw file'
        }
        $rerunRows = @(Import-Csv -LiteralPath $rawManifestPath | Where-Object { [string]$_.source_id -eq $sourceId })
        if ([string]$rerunRows[-1].status -ne 'skipped') { throw "expected skipped on rerun, got $($rerunRows[-1].status)" }

        $evidenceDir = Join-Path -Path $runDir -ChildPath 'evidence'
        New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null
        Write-FixtureFile -Path (Join-Path -Path $evidenceDir -ChildPath 'fixture.md') -Content '# Local text ingest evidence (no MinerU)'

        $validate = Invoke-SkillScript -ScriptName 'validate-run.ps1' -Workspace $workspace
        Assert-ExitCode -Result $validate -Expected 0 -Step 'validate text-source run'
    } finally {
        Remove-FixtureWorkspace -Workspace $workspace
    }
}

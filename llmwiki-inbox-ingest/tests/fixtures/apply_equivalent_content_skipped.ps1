#Requires -Version 7.0
. $PSScriptRoot\common.ps1

# 同文不同壳：目标已存在、字节不同、但文本层完全一致 → 视为该内容已归档，跳过复制且不产出 raw。
Complete-Fixture {
    $workspace = New-FixtureWorkspace -Name 'apply-equivalent-content-skipped'
    try {
        # 1) 正常件（pdf，走常规归档+解析路径）
        Initialize-HappyPathSource -Workspace $workspace | Out-Null
        # 2) 撞名件（docx，文本与库内既有件一致、仅非文本字节不同）
        $docxSource = Join-Path -Path ([string]$workspace.Inbox) -ChildPath (Join-Path -Path 'ThemeA' -ChildPath (Join-Path -Path '2026' -ChildPath 'form-template.docx'))
        New-FixtureDocxFile -Path $docxSource -Text 'EQUIVALENT-BODY-TEXT'

        Invoke-ScanAndProposal -Workspace $workspace
        $plan = @(Get-Content -LiteralPath (Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'classification-plan.jsonl') -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
        $docxItem = @($plan | Where-Object { $_.source_rel_path -like '*form-template.docx' })
        if ($docxItem.Count -ne 1) { throw "expected exactly 1 plan item for form-template.docx, found $($docxItem.Count)" }

        # 预置"同文不同壳"的库内既有件：同样的文本 + 额外非文本字节
        New-FixtureDocxFile -Path ([string]$docxItem[0].target_archive_path) -Text 'EQUIVALENT-BODY-TEXT' -PaddingBytes 4096
        $preexistingHash = (Get-FileHash -Algorithm SHA256 -LiteralPath ([string]$docxItem[0].target_archive_path)).Hash.ToLowerInvariant()
        if ($preexistingHash -eq [string]$docxItem[0].source_sha256) { throw 'fixture setup failed: pre-existing target should differ in bytes from the inbox source' }

        Approve-FixtureRun -Workspace $workspace | Out-Null
        $apply = Invoke-SkillScript -ScriptName 'apply-approved-plan.ps1' -Workspace $workspace
        Assert-ExitCode -Result $apply -Expected 0 -Step 'apply with text-equivalent collision'

        $applyManifestPath = Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'apply-manifest.jsonl'
        Assert-FileContains -Path $applyManifestPath -Pattern 'skipped_equivalent_content' -Label 'apply-manifest.jsonl'
        if ((Get-Content -LiteralPath $applyManifestPath -Raw -Encoding UTF8).Contains('preflight_failed')) {
            throw 'text-equivalent collision was wrongly reported as preflight_failed'
        }

        # 既有归档件必须原样保留（不被覆盖）
        $afterHash = (Get-FileHash -Algorithm SHA256 -LiteralPath ([string]$docxItem[0].target_archive_path)).Hash.ToLowerInvariant()
        if ($afterHash -ne $preexistingHash) { throw 'pre-existing archive file was modified by apply' }

        # 等价件不得进入 MinerU 批次（内容已在库内，重解析不增加知识）
        $batch = Invoke-SkillScript -ScriptName 'prepare-mineru-batch.ps1' -Workspace $workspace
        Assert-ExitCode -Result $batch -Expected 0 -Step 'prepare-mineru-batch'
        $batchPath = Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'mineru-batch.json'
        $batchJson = Get-Content -LiteralPath $batchPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $batchIds = @($batchJson.items | ForEach-Object { [string]$_.source_id })
        if ($batchIds -contains [string]$docxItem[0].source_id) {
            throw 'text-equivalent item must not be added to the MinerU batch'
        }
        if ($batchIds.Count -ne 1) { throw "expected exactly 1 MinerU batch item (the pdf), found $($batchIds.Count)" }

        # 走完 pdf 那件的解析产物与 raw 落盘（等价件不参与）
        $evidenceDir = Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'evidence'
        New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null
        Write-FixtureFile -Path (Join-Path -Path $evidenceDir -ChildPath 'fixture.md') -Content '# Fixture evidence'
        $pdfItem = Get-SingleMineruBatchItem -Workspace $workspace
        $pdfSourceId = [string]$pdfItem.source_id
        Write-FixtureMineruOutput -Workspace $workspace -SourceId $pdfSourceId -Markdown ("# Weekly report $pdfSourceId`n`n" + ('Synthetic body for the equivalent-collision fixture. ' * 12))
        Write-FixtureLifecycleState -Workspace $workspace -SourceId $pdfSourceId -Status 'done'
        $ingest = Invoke-SkillScript -ScriptName 'ingest-mineru-output.ps1' -Workspace $workspace
        Assert-ExitCode -Result $ingest -Expected 0 -Step 'ingest the non-equivalent batch item'

        $validate = Invoke-SkillScript -ScriptName 'validate-run.ps1' -Workspace $workspace
        Assert-ExitCode -Result $validate -Expected 0 -Step 'validate run with equivalent-content skip'
    } finally {
        Remove-FixtureWorkspace -Workspace $workspace
    }
}

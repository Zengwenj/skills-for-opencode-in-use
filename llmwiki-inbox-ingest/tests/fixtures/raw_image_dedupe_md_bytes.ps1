#Requires -Version 7.0
. $PSScriptRoot/common.ps1

# 契约 §4 用例 5（图片依赖）：
# - 图片按内容哈希校验 + 原子写复制到 raw 树（md 相对链接保持解析）
# - 同哈希重跑不重复复制（mtime 不变）
# - 仅复制图片时 md 字节必须不变
Complete-Fixture {
    $workspace = New-FixtureWorkspace -Name 'raw-image-dedupe-md-bytes'
    try {
        Initialize-PreparedMineruRun -Workspace $workspace
        $item = Get-SingleMineruBatchItem -Workspace $workspace
        $sourceId = [string]$item.source_id

        $outputDir = Join-Path -Path ([string]$workspace.RunDir) -ChildPath (Join-Path -Path 'mineru-output' -ChildPath $sourceId)
        $imagesDir = Join-Path -Path $outputDir -ChildPath 'images'
        New-Item -ItemType Directory -Path $imagesDir -Force | Out-Null
        $figA = Join-Path -Path $imagesDir -ChildPath 'fig-a.png'
        $figB = Join-Path -Path $imagesDir -ChildPath 'fig-b.png'
        [System.IO.File]::WriteAllBytes($figA, [byte[]](1..200 | ForEach-Object { $_ }))
        [System.IO.File]::WriteAllBytes($figB, [byte[]](1..200 | ForEach-Object { ($_ * 7) % 251 }))
        $figAHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $figA).Hash.ToLowerInvariant()
        $figBHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $figB).Hash.ToLowerInvariant()

        $body = ('Synthetic MinerU fixture body with image dependencies for dedupe verification. ' * 20)
        $markdown = "# Image output $sourceId`n`n![](images/fig-a.png)`n`n![](images/fig-b.png)`n`n$body"
        Write-FixtureMineruOutput -Workspace $workspace -SourceId $sourceId -Markdown $markdown
        Write-FixtureLifecycleState -Workspace $workspace -SourceId $sourceId -Status 'done'

        $firstIngest = Invoke-SkillScript -ScriptName 'ingest-mineru-output.ps1' -Workspace $workspace
        Assert-ExitCode -Result $firstIngest -Expected 0 -Step 'first ingest copies md and images'

        $rawMdFiles = @(Get-ChildItem -LiteralPath ([string]$workspace.Raw) -File -Recurse -Filter '*.md')
        if ($rawMdFiles.Count -ne 1) { throw "expected 1 raw markdown file, found $($rawMdFiles.Count)" }
        $rawMd = $rawMdFiles[0]
        $targetDir = Split-Path -Path $rawMd.FullName -Parent
        $rawFigA = Join-Path -Path $targetDir -ChildPath (Join-Path -Path 'images' -ChildPath 'fig-a.png')
        $rawFigB = Join-Path -Path $targetDir -ChildPath (Join-Path -Path 'images' -ChildPath 'fig-b.png')
        Assert-FileExists -Path $rawFigA -Label 'raw image fig-a.png'
        Assert-FileExists -Path $rawFigB -Label 'raw image fig-b.png'
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $rawFigA).Hash.ToLowerInvariant() -ne $figAHash) { throw 'raw fig-a.png hash differs from source image' }
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $rawFigB).Hash.ToLowerInvariant() -ne $figBHash) { throw 'raw fig-b.png hash differs from source image' }
        Assert-FileContains -Path $rawMd.FullName -Pattern 'images/fig-a.png' -Label 'raw md image link'

        $mdHashBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $rawMd.FullName).Hash.ToLowerInvariant()
        $mdMtimeBefore = $rawMd.LastWriteTimeUtc
        $figAMtimeBefore = (Get-Item -LiteralPath $rawFigA).LastWriteTimeUtc
        $figBMtimeBefore = (Get-Item -LiteralPath $rawFigB).LastWriteTimeUtc

        $secondIngest = Invoke-SkillScript -ScriptName 'ingest-mineru-output.ps1' -Workspace $workspace
        Assert-ExitCode -Result $secondIngest -Expected 0 -Step 'second ingest dedupes images'

        # md 字节不变（仅复制/去重图片不得改写 md）
        $mdHashAfter = (Get-FileHash -Algorithm SHA256 -LiteralPath $rawMd.FullName).Hash.ToLowerInvariant()
        if ($mdHashAfter -ne $mdHashBefore) { throw 'raw md bytes changed during image-only rerun' }
        if (-not (Get-Item -LiteralPath $rawMd.FullName).LastWriteTimeUtc.Equals($mdMtimeBefore)) { throw 'raw md was rewritten during image-only rerun' }

        # 同哈希图片不重复复制：仍各 1 份，mtime 未变，无 tmp 残留
        $rawImages = @(Get-ChildItem -LiteralPath ([string]$workspace.Raw) -File -Recurse -Filter '*.png')
        if ($rawImages.Count -ne 2) { throw "expected 2 raw images after rerun, found $($rawImages.Count)" }
        if (-not (Get-Item -LiteralPath $rawFigA).LastWriteTimeUtc.Equals($figAMtimeBefore)) { throw 'fig-a.png was recopied despite identical content hash' }
        if (-not (Get-Item -LiteralPath $rawFigB).LastWriteTimeUtc.Equals($figBMtimeBefore)) { throw 'fig-b.png was recopied despite identical content hash' }
        $tempLeftovers = @(Get-ChildItem -LiteralPath ([string]$workspace.Raw) -File -Recurse -Filter '*.tmp-*')
        if ($tempLeftovers.Count -gt 0) { throw "temp leftovers remained under raw root: $($tempLeftovers.Name -join ', ')" }

        $rawManifestPath = Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'raw-output-manifest.csv'
        $mergedRows = @(Import-Csv -LiteralPath $rawManifestPath)
        $skippedRows = @($mergedRows | Where-Object { [string]$_.status -eq 'skipped' })
        if ($skippedRows.Count -ne 1) { throw "expected 1 skipped raw row after rerun, found $($skippedRows.Count)" }
        if (-not ([string]$skippedRows[0].message).Contains('skipped_hash_dedupe=2')) { throw "rerun row does not report hash dedupe: $($skippedRows[0].message)" }

        $validate = Invoke-SkillScript -ScriptName 'validate-run.ps1' -Workspace $workspace
        Assert-ExitCode -Result $validate -Expected 0 -Step 'validate image run'
    } finally {
        Remove-FixtureWorkspace -Workspace $workspace
    }
}
